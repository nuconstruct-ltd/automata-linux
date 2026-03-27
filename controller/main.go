package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// --- Types ---

type Mode string

const (
	ModeInternet Mode = "internet"  // maintenance: feed OFF, internet ON
	ModeToolNode Mode = "tool-node" // normal:      feed ON,  internet OFF
	ModeError    Mode = "error"     // intermediate/failure: everything OFF

	nftTimeout = 10 * time.Second
)

type MaintenanceRequest struct {
	Action string `json:"action"`
}

// Response is the unified JSON response for all endpoints.
// status: current mode (tool-node|internet|error|switching).
// message: human-readable detail, present on errors and no-ops.
type Response struct {
	Status  string `json:"status"`
	Message string `json:"message,omitempty"`
}

type AppState struct {
	ctx           context.Context // root application context (not per-request)
	toolNodeIP    string
	nodeNetSubnet string
	authrpcURL    string
	jwtSecret     [32]byte
	sshPort       string
	apiKeyHash    string // empty = not configured
	switchDelay   time.Duration
	httpClient    *http.Client

	// opSem is a buffered(1) channel acting as a try-lock semaphore.
	// Whoever holds it owns exclusive access to mode and the right to mutate state.
	// GET handlers acquire briefly to read; if busy — the system is mid-switch.
	// POST handler holds it for the entire operation duration.
	opSem chan struct{}
	mode  Mode
}

// --- Semaphore helpers ---

// acquireOp tries to acquire the semaphore (non-blocking).
// Returns true if acquired — caller MUST call releaseOp when done.
func (s *AppState) acquireOp() bool {
	select {
	case s.opSem <- struct{}{}:
		return true
	default:
		return false
	}
}

func (s *AppState) releaseOp() {
	<-s.opSem
}

// readMode acquires the semaphore, reads mode, releases.
// Returns "switching" if the semaphore is held by another operation.
func (s *AppState) readMode() Mode {
	if !s.acquireOp() {
		return "switching"
	}
	m := s.mode
	s.releaseOp()
	return m
}

// --- Main ---

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	toolNodeIP := envOr("TOOL_NODE_IP", "172.20.0.10")
	nodeNetSubnet := envOr("NODE_NET_SUBNET", "172.20.0.0/24")
	port := envOr("PORT", "8080")
	authrpcURL := envOr("AUTHRPC_URL", "http://172.20.0.10:8551")
	sshPort := envOr("SSH_PORT", "2200")
	jwtSecretPath := envOr("JWT_SECRET_PATH", "/node/jwtsecret")
	switchDelay := parseDuration(envOr("SWITCH_DELAY", "30s"), 30*time.Second)

	state := &AppState{
		ctx:           ctx,
		toolNodeIP:    toolNodeIP,
		nodeNetSubnet: nodeNetSubnet,
		authrpcURL:    authrpcURL,
		jwtSecret:     readJWTSecret(jwtSecretPath),
		sshPort:       sshPort,
		apiKeyHash:    readAPIKeyHash(),
		switchDelay:   switchDelay,
		httpClient: &http.Client{
			Timeout: 15 * time.Second,
			Transport: &http.Transport{
				TLSHandshakeTimeout:   5 * time.Second,
				ResponseHeaderTimeout: 10 * time.Second,
				IdleConnTimeout:       30 * time.Second,
			},
		},
		opSem: make(chan struct{}, 1),
		mode:  ModeToolNode,
	}

	slog.Info("Starting Controller",
		"tool_node_ip", toolNodeIP,
		"node_net_subnet", nodeNetSubnet,
		"authrpc_url", authrpcURL,
		"switch_delay", switchDelay,
		"api_key_configured", state.apiKeyHash != "",
	)

	if err := initNftables(ctx); err != nil {
		slog.Error("Failed to init nftables", "err", err)
		os.Exit(1)
	}
	if err := applyToolNodeMode(ctx, toolNodeIP, nodeNetSubnet, sshPort); err != nil {
		slog.Error("Failed to apply initial mode", "err", err)
		os.Exit(1)
	}

	go runCVMAgentProxy(ctx)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /mode", state.handleGetMode)
	mux.HandleFunc("GET /status", state.handleGetStatus)
	mux.HandleFunc("POST /maintenance", state.handlePostMaintenance)

	srv := &http.Server{
		Addr:    "0.0.0.0:" + port,
		Handler: mux,
	}

	go func() {
		slog.Info("Listening", "addr", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("Server failed", "err", err)
			os.Exit(1)
		}
	}()

	<-ctx.Done()
	slog.Info("Shutdown signal received, draining connections...")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		slog.Error("Server shutdown error", "err", err)
	}
	slog.Info("Server stopped")
}

// --- HTTP Handlers ---

func (s *AppState) handleGetMode(w http.ResponseWriter, _ *http.Request) {
	w.Write([]byte(s.readMode()))
}

func (s *AppState) handleGetStatus(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(Response{Status: string(s.readMode())})
}

func (s *AppState) handlePostMaintenance(w http.ResponseWriter, r *http.Request) {
	respond := func(code int, resp Response) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(code)
		json.NewEncoder(w).Encode(resp)
	}

	// --- Auth ---

	if s.apiKeyHash == "" {
		respond(http.StatusUnauthorized, Response{
			Status:  "error",
			Message: "API key not configured on server",
		})
		return
	}

	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !verifyAPIKey(token, s.apiKeyHash) {
		respond(http.StatusUnauthorized, Response{
			Status:  "error",
			Message: "Invalid or missing API key",
		})
		return
	}

	// --- Parse action ---

	r.Body = http.MaxBytesReader(w, r.Body, 1<<16) // 64 KB
	var req MaintenanceRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(http.StatusBadRequest, Response{
			Status:  "error",
			Message: "Invalid request body",
		})
		return
	}

	target, ok := actionToMode(req.Action)
	if !ok {
		respond(http.StatusBadRequest, Response{
			Status:  "error",
			Message: fmt.Sprintf("Invalid action '%s'. Use 'enable' or 'disable'.", req.Action),
		})
		return
	}

	// --- Acquire exclusive operation lock ---

	if !s.acquireOp() {
		respond(http.StatusConflict, Response{
			Status:  "error",
			Message: "Another mode switch is already in progress",
		})
		return
	}
	defer s.releaseOp()

	// --- Execute full switch sequence ---
	// Always executes ALL steps regardless of current mode.
	// We never trust our own state — external reality may differ.

	if err := s.switchMode(target); err != nil {
		respond(http.StatusInternalServerError, Response{
			Status:  string(s.mode),
			Message: fmt.Sprintf("Failed to switch mode: %v", err),
		})
		return
	}

	respond(http.StatusOK, Response{Status: string(target)})
}

// --- Mode switching ---

// switchMode executes a full mode transition.
//
// Every transition follows the same safety pattern:
//  1. RESTRICT the dangerous resource (the one that must NOT be active in target mode)
//  2. Set mode = error (safe intermediate state)
//  3. Wait switchDelay
//  4. ENABLE the target resource
//  5. Set mode = target (only on success)
//
// Only one resource is restricted and one is enabled — we don't touch the other.
// This works because the security invariant (feed + internet never both on)
// is guaranteed by the restrict step alone:
//   - enterMaintenance: stopping feed makes it safe regardless of internet state
//   - leaveMaintenance: blocking internet makes it safe regardless of feed state
//
// If step 4 fails, mode stays "error". The client retries.
// All operations are idempotent — safe to re-execute from any state.
//
// Must be called with opSem held. Uses root app context (s.ctx).
func (s *AppState) switchMode(target Mode) error {
	switch target {
	case ModeInternet:
		return s.enterMaintenance()
	case ModeToolNode:
		return s.leaveMaintenance()
	default:
		return fmt.Errorf("unknown target mode: %s", target)
	}
}

// enterMaintenance: stop feed → error → wait → open internet → internet.
//
// Step 1 (stop feed) ensures the invariant: feed and internet are never both on.
// Once the feed is off, it doesn't matter if internet was open or closed —
// we're safe to wait and then (re-)open it.
// Blocking internet before opening it would be a redundant step and an extra failure point.
func (s *AppState) enterMaintenance() error {
	// RESTRICT — stop API feed
	slog.Info("Entering maintenance: stopping API feed")
	if err := s.notifyToolNode(s.ctx, ModeInternet); err != nil {
		slog.Error("Failed to stop API feed", "err", err)
		s.mode = ModeError
		return fmt.Errorf("stop feed: %w", err)
	}

	s.mode = ModeError
	slog.Info("Intermediate state: feed stopped")

	if err := s.interruptibleDelay(); err != nil {
		return err
	}

	// ENABLE — open internet/SSH access
	slog.Info("Entering maintenance: opening internet access")
	if err := applyInternetMode(s.ctx); err != nil {
		slog.Error("Failed to open internet", "err", err)
		return fmt.Errorf("open internet: %w", err)
	}

	s.mode = ModeInternet
	slog.Info("Mode switched to internet (maintenance ON)")
	return nil
}

// leaveMaintenance: block internet → error → wait → start feed → tool-node.
//
// Step 1 (block internet) ensures the invariant: feed and internet are never both on.
// Once internet is blocked, it doesn't matter if the feed was running or stopped —
// we're safe to wait and then (re-)start it.
// Stopping the feed before starting it would be a redundant step and an extra failure point.
func (s *AppState) leaveMaintenance() error {
	// RESTRICT — block internet/SSH
	slog.Info("Leaving maintenance: blocking internet")
	if err := applyToolNodeMode(s.ctx, s.toolNodeIP, s.nodeNetSubnet, s.sshPort); err != nil {
		slog.Error("Failed to block internet", "err", err)
		s.mode = ModeError
		return fmt.Errorf("block internet: %w", err)
	}

	s.mode = ModeError
	slog.Info("Intermediate state: internet blocked")

	if err := s.interruptibleDelay(); err != nil {
		return err
	}

	// ENABLE — start API feed
	slog.Info("Leaving maintenance: starting API feed")
	if err := s.notifyToolNode(s.ctx, ModeToolNode); err != nil {
		slog.Error("Failed to start API feed", "err", err)
		return fmt.Errorf("start feed: %w", err)
	}

	s.mode = ModeToolNode
	slog.Info("Mode switched to tool-node (maintenance OFF)")
	return nil
}

// interruptibleDelay sleeps for switchDelay, respecting root context cancellation.
func (s *AppState) interruptibleDelay() error {
	slog.Info("Waiting between steps", "delay", s.switchDelay)
	select {
	case <-time.After(s.switchDelay):
		return nil
	case <-s.ctx.Done():
		slog.Warn("Context canceled during delay")
		return fmt.Errorf("canceled during delay: %w", s.ctx.Err())
	}
}

func actionToMode(action string) (Mode, bool) {
	switch action {
	case "enable":
		return ModeInternet, true
	case "disable":
		return ModeToolNode, true
	default:
		return "", false
	}
}

// --- API Key ---

func readAPIKeyHash() string {
	path := envOr("API_KEY_HASH_PATH", "/data/token_hash")
	data, err := os.ReadFile(path)
	if err == nil {
		h := strings.TrimSpace(string(data))
		if h != "" {
			slog.Info("API key hash loaded", "path", path)
			return h
		}
		slog.Warn("API key hash file is empty", "path", path)
	} else {
		slog.Warn("Cannot read API key hash, falling back to env", "path", path, "err", err)
	}
	if key := os.Getenv("CONTROLLER_API_KEY"); key != "" {
		return key
	}
	return ""
}

func verifyAPIKey(provided, storedHash string) bool {
	h := sha256.Sum256([]byte(provided))
	computed := hex.EncodeToString(h[:])
	return subtle.ConstantTimeCompare([]byte(computed), []byte(storedHash)) == 1
}

// --- JWT + JSON-RPC ---

func readJWTSecret(path string) [32]byte {
	data, err := os.ReadFile(path)
	if err != nil {
		slog.Warn("Cannot read JWT secret", "path", path, "err", err)
		return [32]byte{}
	}
	hexStr := strings.TrimPrefix(strings.TrimSpace(string(data)), "0x")
	decoded, err := hex.DecodeString(hexStr)
	if err != nil || len(decoded) != 32 {
		slog.Warn("Invalid JWT secret", "path", path)
		return [32]byte{}
	}
	var secret [32]byte
	copy(secret[:], decoded)
	slog.Info("JWT secret loaded", "path", path)
	return secret
}

func makeJWTToken(secret [32]byte) (string, error) {
	now := time.Now().Unix()
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"iat": now,
		"exp": now + 60,
	})
	return token.SignedString(secret[:])
}

// notifyToolNode calls the tool-node RPC synchronously.
// Respects ctx for cancellation; applies its own 10s timeout on top.
func (s *AppState) notifyToolNode(ctx context.Context, mode Mode) error {
	method := "maintenance_startAPIFeed"
	if mode != ModeToolNode {
		method = "maintenance_stopAPIFeed"
	}

	slog.Info("Calling tool-node RPC", "method", method)

	token, err := makeJWTToken(s.jwtSecret)
	if err != nil {
		return fmt.Errorf("jwt: %w", err)
	}

	body, _ := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"method":  method,
		"params":  []any{},
		"id":      1,
	})

	rpcCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	req, _ := http.NewRequestWithContext(rpcCtx, "POST", s.authrpcURL, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")

	resp, err := s.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("rpc %s: %w", method, err)
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 300 {
		return fmt.Errorf("rpc %s returned %d: %s", method, resp.StatusCode, respBody)
	}

	slog.Info("RPC succeeded", "method", method, "body", string(respBody))
	return nil
}

// --- nftables ---

func initNftables(ctx context.Context) error {
	slog.Info("Initializing nftables")

	// Clean slate (ignore errors — tables may not exist)
	runNft(ctx, "delete", "table", "ip", "filter")
	runNft(ctx, "delete", "table", "ip", "nat")

	if err := runNft(ctx, "add", "table", "ip", "filter"); err != nil {
		return err
	}
	if err := runNft(ctx, "add", "chain", "ip", "filter", "output",
		"{ type filter hook output priority 0 ; policy accept ; }"); err != nil {
		return err
	}
	return runNft(ctx, "add", "chain", "ip", "filter", "input",
		"{ type filter hook input priority 0 ; policy accept ; }")
}

func applyInternetMode(ctx context.Context) error {
	slog.Info("Applying Internet Only mode")
	return runNftAtomic(ctx, strings.Join([]string{
		"flush chain ip filter output",
		"flush chain ip filter input",
		"add rule ip filter output ct state established,related accept",
	}, "\n"))
}

func applyToolNodeMode(ctx context.Context, toolNodeIP, subnet, sshPort string) error {
	slog.Info("Applying Tool Node Only mode")
	return runNftAtomic(ctx, strings.Join([]string{
		"flush chain ip filter output",
		"flush chain ip filter input",
		fmt.Sprintf("add rule ip filter input tcp dport %s drop", sshPort),
		"add rule ip filter output ip daddr 127.0.0.0/8 accept",
		"add rule ip filter output ct state established,related accept",
		fmt.Sprintf("add rule ip filter output ip daddr %s accept", toolNodeIP),
		fmt.Sprintf("add rule ip filter output ip daddr %s accept", subnet),
		"add rule ip filter output drop",
	}, "\n"))
}

func runNft(ctx context.Context, args ...string) error {
	slog.Debug("Running nft", "args", strings.Join(args, " "))
	cmdCtx, cancel := context.WithTimeout(ctx, nftTimeout)
	defer cancel()
	out, err := exec.CommandContext(cmdCtx, "nft", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("nft failed: %s", strings.TrimSpace(string(out)))
	}
	return nil
}

func runNftAtomic(ctx context.Context, ruleset string) error {
	slog.Info("Running nft atomic")
	slog.Debug("nft ruleset", "ruleset", ruleset)
	cmdCtx, cancel := context.WithTimeout(ctx, nftTimeout)
	defer cancel()
	cmd := exec.CommandContext(cmdCtx, "nft", "-f", "-")
	cmd.Stdin = strings.NewReader(ruleset)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("nft atomic failed: %s", strings.TrimSpace(string(out)))
	}
	return nil
}

// --- CVM Agent Proxy ---

func runCVMAgentProxy(ctx context.Context) {
	host := os.Getenv("CVM_AGENT_HOST")
	if host == "" {
		host = getDefaultGateway()
		if host == "" {
			host = "host.docker.internal"
		}
	}

	listenAddr := net.JoinHostPort("127.0.0.1", "7999")
	targetAddr := net.JoinHostPort(host, "17999")

	lc := net.ListenConfig{}
	ln, err := lc.Listen(ctx, "tcp", listenAddr)
	if err != nil {
		slog.Warn("Failed to bind CVM agent proxy", "addr", listenAddr, "err", err)
		return
	}
	slog.Info("CVM agent proxy listening", "listen", listenAddr, "target", targetAddr)

	go func() {
		<-ctx.Done()
		ln.Close()
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				slog.Info("CVM agent proxy shutting down")
				return
			}
			slog.Error("CVM proxy accept error", "err", err)
			continue
		}
		go proxyConnection(ctx, conn, targetAddr)
	}
}

func proxyConnection(ctx context.Context, inbound net.Conn, targetAddr string) {
	defer inbound.Close()

	dialer := net.Dialer{Timeout: 5 * time.Second}
	outbound, err := dialer.DialContext(ctx, "tcp", targetAddr)
	if err != nil {
		slog.Debug("Proxy dial failed", "target", targetAddr, "err", err)
		return
	}
	defer outbound.Close()

	// Proxy both directions. When one side finishes reading (EOF or error),
	// we half-close the write side of the other to propagate the shutdown cleanly.
	// This avoids data loss and ensures both sides drain their buffers.

	done := make(chan struct{}, 2)

	// inbound → outbound
	go func() {
		if _, err := io.Copy(outbound, inbound); err != nil {
			slog.Debug("Proxy copy inbound→outbound", "err", err)
		}
		closeWrite(outbound)
		done <- struct{}{}
	}()

	// outbound → inbound
	go func() {
		if _, err := io.Copy(inbound, outbound); err != nil {
			slog.Debug("Proxy copy outbound→inbound", "err", err)
		}
		closeWrite(inbound)
		done <- struct{}{}
	}()

	// Wait for BOTH directions to finish, OR context cancellation (app shutdown).
	// On shutdown we force-close both connections so the goroutines unblock.
	select {
	case <-done:
		// One direction finished — wait for the other (half-close propagates EOF).
		<-done
	case <-ctx.Done():
		// Force close on shutdown — unblocks both io.Copy goroutines.
		inbound.Close()
		outbound.Close()
		<-done
		<-done
	}
}

// closeWrite sends a TCP FIN to the peer if the connection supports it.
// Falls back to a no-op for non-TCP connections.
func closeWrite(c net.Conn) {
	if tc, ok := c.(interface{ CloseWrite() error }); ok {
		tc.CloseWrite()
	}
}

func getDefaultGateway() string {
	out, err := exec.Command("ip", "route", "show", "default").Output()
	if err != nil {
		return ""
	}
	fields := strings.Fields(string(out))
	for i, f := range fields {
		if f == "via" && i+1 < len(fields) {
			return fields[i+1]
		}
	}
	return ""
}

// --- Helpers ---

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func parseDuration(s string, fallback time.Duration) time.Duration {
	d, err := time.ParseDuration(s)
	if err != nil {
		slog.Warn("Invalid duration, using fallback", "input", s, "fallback", fallback)
		return fallback
	}
	return d
}
