# CVM Network Controller

Network isolation controller for Confidential VM environments. Enforces mutual exclusion between internet access and tool-node data feed — at no point are both active simultaneously.

## Security Model

The controller manages two resources that must **never be open at the same time**:

| Resource | `tool-node` mode | `internet` mode |
|----------|-----------------|-----------------|
| Internet/SSH access | **blocked** | **open** |
| Tool-node data feed | **running** | **stopped** |

**Security invariant: internet and feed are never both active at the same time.**

`error` state means a transition failed partway. The invariant is preserved because the restrict step (which disables the dangerous resource) always runs before the enable step (which activates the target resource). If the restrict step itself fails, the enable step is never attempted. The client should retry.

## How It Works

The controller shares its network namespace with the operator container via Docker Compose `network_mode: "service:controller"`. Both containers share the same network stack — nftables rules applied by the controller affect the operator's traffic directly.

```
┌─ Shared Network Namespace ───────────────────────────┐
│                                                      │
│  ┌─────────────┐          ┌─────────────┐            │
│  │  Controller │◄─────────│  Operator   │            │
│  │  :8080 API  │ localhost│             │            │
│  └──────┬──────┘          └─────────────┘            │
│         │                                            │
│    nftables rules                                    │
│    (applied here, affect both)                       │
│         │                                            │
├─────────┼────────────────────────────────────────────┤
│         ▼                                            │
│   ┌───────────┐    ┌───────────┐    ┌───────────┐    │
│   │ Tool Node │    │ Internet  │    │ SSH :2200 │    │
│   │ (always)  │    │ (gated)   │    │ (gated)   │    │
│   └───────────┘    └───────────┘    └───────────┘    │
└───────────────────────────────────────────────────────┘
```

### Network Modes

**tool-node (default)** — isolated, normal operation:

```
                  Inbound SSH (:2200)
                        │
                        ▼
                       ❌ BLOCKED

┌─────────────┐     ❌      ┌─────────────┐
│   Operator  │ ──────────► │   Internet  │
└─────────────┘             └─────────────┘
       │
       │          ✅
       └──────────────────► Tool Node (always allowed)
```

**internet (maintenance)** — open, debugging/maintenance:

```
                  Inbound SSH (:2200)
                        │
                        ▼
                       ✅ ALLOWED

┌─────────────┐     ✅      ┌─────────────┐
│   Operator  │ ──────────► │   Internet  │
└─────────────┘             └─────────────┘
       │
       │          ✅
       └──────────────────► Tool Node (always allowed)
```

## Switching Flow

Every mode switch has two steps: **restrict** the dangerous resource, then **enable** the target resource. Only one resource is touched in each step.

### Entering maintenance (`→ internet`)

```
  ┌─────────────────────────────────────────────────┐
  │  RESTRICT: Stop data feed                       │
  │                                                 │
  │  status = "error"                               │
  │  (feed OFF, internet state unchanged)           │
  │                                                 │
  │  Security invariant holds: feed is OFF,         │
  │  so it doesn't matter if internet is on or off  │
  └───────────────────────┬─────────────────────────┘
                          │
                     wait 30 seconds
                          │
  ┌───────────────────────▼─────────────────────────┐
  │  ENABLE: Open internet/SSH access               │
  │                                                 │
  │  status = "internet"                            │
  └─────────────────────────────────────────────────┘
```

### Leaving maintenance (`→ tool-node`)

```
  ┌─────────────────────────────────────────────────┐
  │  RESTRICT: Block internet/SSH                   │
  │                                                 │
  │  status = "error"                               │
  │  (internet OFF, feed state unchanged)           │
  │                                                 │
  │  Security invariant holds: internet is OFF,     │
  │  so it doesn't matter if feed is on or off      │
  └───────────────────────┬─────────────────────────┘
                          │
                     wait 30 seconds
                          │
  ┌───────────────────────▼─────────────────────────┐
  │  ENABLE: Start data feed                        │
  │                                                 │
  │  status = "tool-node"                           │
  └─────────────────────────────────────────────────┘
```

**If the ENABLE step fails**, the system stays in `error` — the dangerous resource is already restricted. The client can retry safely.

**If the RESTRICT step fails**, the system enters `error` immediately. The target resource was never enabled, so the invariant cannot be violated.

**Why this is safe:**
- The restrict step alone guarantees the invariant (feed and internet never both active)
- We don't touch the "other" resource — fewer operations means fewer failure points
- All operations are idempotent — repeating them from any state is harmless

## States

```
                 POST enable              POST disable
  tool-node ◄──────────────────► internet
       ▲                              ▲
       │ POST disable                 │ POST enable
       │                              │
       └─────────── error ────────────┘
                (retry either action)
```

| Status | Meaning | What to do |
|--------|---------|------------|
| `tool-node` | Normal operation. Data feed is running, internet is blocked. | — |
| `internet` | Maintenance mode. Internet/SSH is open, data feed is stopped. | — |
| `error` | A step failed. The dangerous resource was restricted but the target was not enabled. | Retry the same or different action. |
| `switching` | A transition is in progress (returned by GET only). | Wait and check again. |

## API

### `GET /mode`

Returns current mode as plain text.

```
tool-node
internet
error
switching
```

### `GET /status`

Returns current mode as JSON.

```json
{"status":"tool-node"}
{"status":"error"}
{"status":"switching"}
```

### `POST /maintenance`

Triggers a mode switch. Always executes the full transition sequence regardless of current state.

**Request:**

```bash
# Enter maintenance (open internet, stop feed)
curl -X POST http://localhost:8080/maintenance \
  -H "Authorization: Bearer <api-key>" \
  -H "Content-Type: application/json" \
  -d '{"action":"enable"}'

# Leave maintenance (block internet, start feed)
curl -X POST http://localhost:8080/maintenance \
  -H "Authorization: Bearer <api-key>" \
  -H "Content-Type: application/json" \
  -d '{"action":"disable"}'
```

**Responses:**

Success — `status` is the mode after the operation:

```json
HTTP 200
{"status":"internet"}
```

Failure — system is in error state, safe to retry:

```json
HTTP 500
{"status":"error","message":"Failed to switch mode: start feed: rpc maintenance_startAPIFeed: connection refused"}
```

Other errors:

| Code | When | Example |
|------|------|---------|
| 401 | Bad or missing auth | `{"status":"error","message":"Invalid or missing API key"}` |
| 400 | Bad request | `{"status":"error","message":"Invalid action 'foo'. Use 'enable' or 'disable'."}` |
| 409 | Switch already running | `{"status":"error","message":"Another mode switch is already in progress"}` |

### Client Integration Guide

```
1. Send POST /maintenance with desired action
2. Check HTTP status code:
   - 200 → done, read "status" for current mode
   - 500 → failed, system is in "error" (dangerous resource restricted, target not enabled)
           wait a moment, retry the same request
   - 409 → another switch in progress, wait and retry
3. To check state without switching: GET /status
```

**Retries are always safe.** Every request executes the full sequence from scratch.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8080` | HTTP listen port |
| `SSH_PORT` | `2200` | SSH port to block in tool-node mode |
| `TOOL_NODE_IP` | `172.20.0.10` | Tool-node IP |
| `NODE_NET_SUBNET` | `172.20.0.0/24` | Node network subnet |
| `AUTHRPC_URL` | `http://172.20.0.10:8551` | Tool-node RPC endpoint |
| `JWT_SECRET_PATH` | `/node/jwtsecret` | JWT secret file (32-byte hex) |
| `API_KEY_HASH_PATH` | `/data/token_hash` | SHA-256 hash of API key |
| `CONTROLLER_API_KEY` | _(none)_ | Fallback: raw API key |
| `SWITCH_DELAY` | `30s` | Delay between restrict and enable steps |
| `CVM_AGENT_HOST` | _(auto-detect)_ | CVM agent proxy target host |

## nftables Rules

All rule changes use atomic transactions (`nft -f -`) to prevent inconsistent states.

**tool-node mode:**

```
flush chain ip filter output
flush chain ip filter input
add rule ip filter input tcp dport <SSH_PORT> drop      # Block SSH
add rule ip filter output ip daddr 127.0.0.0/8 accept   # Allow localhost (API + CVM agent proxy)
add rule ip filter output ct state established,related accept
add rule ip filter output ip daddr <TOOL_NODE_IP> accept
add rule ip filter output ip daddr <NODE_NET_SUBNET> accept
add rule ip filter output drop                          # Block everything else
```

**internet mode:**

```
flush chain ip filter output
flush chain ip filter input                             # SSH allowed (no drop rule)
add rule ip filter output ct state established,related accept
```

## CVM Agent Proxy

A TCP proxy that makes the host VM's CVM agent API accessible inside the shared network namespace.

- Listens on `127.0.0.1:7999`
- Forwards to `<default-gateway>:17999` (the host VM)
- Best-effort — bind failure does not prevent controller startup
- Works in both modes (gateway IP is within `NODE_NET_SUBNET`, always allowed by nftables)
- Uses TCP half-close for clean connection teardown

## Security Considerations

1. **Mutual exclusion.** Internet access and API feed are never active simultaneously. The switching sequence always restricts the dangerous resource before enabling the target, with a configurable delay between steps.

2. **Fail-safe on error.** If any step fails, the system enters `error` state. The restrict step has already run (or was never needed), so the invariant holds. No automatic recovery — the operator must explicitly retry.

3. **Default isolated.** The controller starts in `tool-node` mode. The operator cannot access the internet or be reached via SSH until explicitly enabled.

4. **Fail-closed auth.** If no API key is configured (`API_KEY_HASH_PATH` missing and `CONTROLLER_API_KEY` not set), the `POST /maintenance` endpoint rejects all requests.

5. **Constant-time token comparison.** API key verification uses `crypto/subtle.ConstantTimeCompare` to prevent timing attacks.

6. **Atomic firewall rules.** Mode switches use atomic nftables transactions — rules are applied as a single unit, preventing partial/inconsistent states.

7. **Connection tracking.** The `ct state established,related` rule ensures existing connections (like controller API responses) continue to work across mode transitions.

8. **CAP_NET_ADMIN isolation.** The controller requires `NET_ADMIN` capability for nftables, scoped to its network namespace only.

9. **JWT-authenticated RPC.** Tool-node notifications use short-lived JWT tokens (60s expiry) over the authenticated RPC port.

10. **Request body limit.** POST body is limited to 64KB to prevent memory exhaustion attacks.

## Quick Reference

| Action | Command |
|--------|---------|
| Check mode | `curl http://$HOST:8080/mode` |
| Check status (JSON) | `curl http://$HOST:8080/status` |
| Enable maintenance | `curl -X POST -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -d '{"action":"enable"}' http://$HOST:8080/maintenance` |
| Disable maintenance | `curl -X POST -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -d '{"action":"disable"}' http://$HOST:8080/maintenance` |
| SSH to operator | `ssh -p 2200 root@$HOST` _(internet mode only)_ |

## Troubleshooting

### Controller API not reachable in tool-node mode

The operator reaches the controller via `localhost:8080` (shared network namespace). The localhost exception (`127.0.0.0/8`) is always present in nftables rules — if the API is unreachable, check that the controller process is running.

### Operator can access internet in tool-node mode

Indicates stale or missing nftables rules. Restart the controller — it re-initializes rules on startup.

### Cannot SSH even in internet mode

1. Verify the controller is in internet mode: `curl http://$HOST:8080/mode`
2. Check that port 2200 is open in your cloud provider's firewall
3. Verify SSH keys are configured in the operator container

### Status shows "error" after a failed switch

The system is in a safe state (the dangerous resource was restricted). Retry the same or a different action — all operations are idempotent.

## Graceful Shutdown

On `SIGINT`/`SIGTERM`: HTTP server drains (15s timeout), CVM proxy closes, process exits.