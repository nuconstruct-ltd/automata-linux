# Network Isolation Controller

A Rust-based network controller that manages WAN (Internet) access for operator workloads running in Confidential VMs while maintaining persistent Tool Node connectivity.

## Overview

The controller acts as a network firewall using `nftables` to manage operator network access. The operator always has access to the Tool Node, while WAN access and SSH are controlled by the current mode:

- **Tool-Node Mode** (default): Access to the Tool Node, no access to the WAN, SSH blocked
- **Internet Mode**: Access to both the Tool Node and the WAN (Internet), SSH allowed

This provides a security boundary ensuring that when in the default mode, the operator cannot access the WAN or be accessed remotely via SSH, while always maintaining Tool Node connectivity.

## How It Works

The controller shares its network namespace with the operator container using Docker Compose's `network_mode: "service:controller"`. This means:

1. Both containers share the same network stack
2. nftables rules applied by the controller affect the operator's network traffic
3. The operator can reach the controller API on `localhost:8080`
4. SSH port 2200 in the operator is exposed via the controller's port mapping (2200:2200)

### Mode Switching

Mode switching is controlled via the `POST /maintenance` API endpoint. When the mode changes, the controller also notifies the tool-node via authenticated JSON-RPC calls (`maintenance_stopAPIFeed` / `maintenance_startAPIFeed`) over the authrpc port (8551) using JWT authentication.

- **Maintenance ENABLED** → Internet mode (WAN access, tool-node access, SSH allowed, API feed stopped)
- **Maintenance DISABLED** → Tool-node mode (tool-node access, no WAN, SSH blocked, API feed started)

This design ensures that SSH debugging access is only available in Internet mode, while tool-node connectivity is always maintained.

### Network Modes

**Tool-Node Mode (default on startup)**
```
                    Inbound SSH
                        │
                        ▼
                       ❌ BLOCKED

┌─────────────┐     ❌      ┌─────────────┐
│   Operator  │ ──────────► │   Internet  │
└─────────────┘             └─────────────┘
       │
       │          ✅
       └──────────────────► Tool Node (allowed)
```

**Internet Mode (maintenance enabled)**
```
                    Inbound SSH
                        │
                        ▼
                       ✅ ALLOWED

┌─────────────┐     ✅      ┌─────────────┐
│   Operator  │ ──────────► │   Internet  │
└─────────────┘             └─────────────┘
       │
       │          ✅
       └──────────────────► Tool Node (allowed)
```

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/mode` | GET | Returns current mode as string (`internet` or `tool-node`) |
| `/status` | GET | Returns current mode as JSON |
| `/maintenance` | POST | Enable/disable maintenance mode (requires `CONTROLLER_API_KEY`) |

### Example Usage

```bash
# Check current mode from inside the operator container
curl http://localhost:8080/mode

# Check status
curl http://localhost:8080/status

# Enable maintenance mode (switch to internet mode)
curl -X POST \
  -H "Authorization: Bearer $CONTROLLER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"action":"enable"}' \
  https://controller.tool.limo/maintenance

# Disable maintenance mode (switch to tool-node mode)
curl -X POST \
  -H "Authorization: Bearer $CONTROLLER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"action":"disable"}' \
  https://controller.tool.limo/maintenance
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TOOL_NODE_IP` | `172.20.0.10` | IP address of the Tool Node to allow/block |
| `NODE_NET_SUBNET` | `172.20.0.0/24` | Subnet of the internal node network |
| `PORT` | `8080` | Port the controller API listens on |
| `API_KEY_HASH_PATH` | `/data/token_hash` | Path to file containing SHA-256 hash of the CVM API token. Used to validate Bearer tokens for `POST /maintenance`. Falls back to `CONTROLLER_API_KEY` env var if file is not found. |
| `CONTROLLER_API_KEY` | *(none)* | (Fallback) Plaintext Bearer token for `POST /maintenance`. Only used if `API_KEY_HASH_PATH` file is not readable. |
| `AUTHRPC_URL` | `http://172.20.0.10:8551` | Tool-node authenticated RPC endpoint |
| `JWT_SECRET_PATH` | `/node/jwtsecret` | Path to shared JWT secret file (Engine API format, 32-byte hex) |

## CVM Agent Proxy

The controller runs a userspace TCP proxy that makes the host's CVM agent API accessible to the operator at `localhost:7999`. Since the operator shares the controller's network namespace, its loopback is isolated from the host — the proxy bridges this gap without requiring kernel NAT modules.

- Listens on `127.0.0.1:7999` (in the shared namespace)
- Forwards connections to `<default-gateway>:7999` (the host VM)
- Best-effort: if no gateway is found or the port can't be bound, the controller continues without it
- Works in both network modes (gateway IP is within `NODE_NET_SUBNET`, allowed by nftables)

## nftables Rules

The controller uses atomic nftables transactions to avoid race conditions during mode switches.

**Tool-Node Mode Rules:**
```
flush chain ip filter output
flush chain ip filter input
add rule ip filter input tcp dport 22 drop              # Block SSH
add rule ip filter output ip daddr 127.0.0.0/8 accept   # Allow localhost (for API + CVM agent proxy)
add rule ip filter output ct state established,related accept
add rule ip filter output ip daddr <TOOL_NODE_IP> accept
add rule ip filter output ip daddr <NODE_NET_SUBNET> accept
add rule ip filter output drop                          # Block everything else (WAN)
```

**Internet Mode Rules:**
```
flush chain ip filter output
flush chain ip filter input                             # Clear SSH block
add rule ip filter output ct state established,related accept
```

## Building

### Prerequisites
- Rust toolchain
- Docker (for building container image)

### Build locally
```bash
cd controller
cargo build --release
```

### Build Docker image (for AMD64 deployment)
```bash
cd controller
docker build --platform linux/amd64 -t gcr.io/<project>/controller:latest .
docker push gcr.io/<project>/controller:latest
```

## Docker Compose Integration

Add the controller to your `docker-compose.yml`:

```yaml
services:
  controller:
    image: gcr.io/<project>/controller:latest
    pull_policy: never
    container_name: controller
    cap_add:
      - NET_ADMIN          # Required for nftables
    ports:
      - "8080:8080"        # Controller API
      - "2200:2200"        # SSH to operator (via shared network)
    environment:
      - TOOL_NODE_IP=172.20.0.10
      - NODE_NET_SUBNET=172.20.0.0/24
      - PORT=8080
    networks:
      node_net:
        ipv4_address: 172.20.0.20

  operator:
    image: gcr.io/<project>/operator:latest
    pull_policy: never
    container_name: operator
    network_mode: "service:controller"  # Share controller's network
    depends_on:
      - controller
    volumes:
      - /data/workload/config:/config

  tool-node:
    image: gcr.io/<project>/tool-node:latest
    container_name: tool-node
    networks:
      node_net:
        ipv4_address: 172.20.0.10
```

## CVM Management

### Checking Logs

Use `cvm-cli` to retrieve container logs from the deployed CVM:

```bash
# Get all container logs
./cvm-cli get-logs gcp <vm-name>

# Filter for specific containers
./cvm-cli get-logs gcp <vm-name> | grep "controller"
./cvm-cli get-logs gcp <vm-name> | grep "operator"
./cvm-cli get-logs gcp <vm-name> | grep "tool-node"
```

### Switching Modes

Network mode is controlled exclusively via the controller API on port 8080.

```bash
VM_IP=$(cat _artifacts/gcp_<vm-name>_ip)

# Enable maintenance mode → switches to Internet mode (SSH allowed, tool-node + WAN access)
curl -X POST \
  -H "Authorization: Bearer $CONTROLLER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"action":"enable"}' \
  "http://${VM_IP}:8080/maintenance"

# SSH into the operator container (only works in Internet mode)
ssh -p 2200 root@${VM_IP}

# Disable maintenance mode → switches to Tool-node mode (tool-node only, no WAN, SSH blocked)
curl -X POST \
  -H "Authorization: Bearer $CONTROLLER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"action":"disable"}' \
  "http://${VM_IP}:8080/maintenance"
```

### Quick Reference

| Action | Command |
|--------|---------|
| Check current mode | `curl http://$VM_IP:8080/mode` |
| Enable maintenance (→ Internet + Tool-node) | `curl -X POST -H "Authorization: Bearer $CONTROLLER_API_KEY" -H "Content-Type: application/json" -d '{"action":"enable"}' http://$VM_IP:8080/maintenance` |
| Disable maintenance (→ Tool-node only) | `curl -X POST -H "Authorization: Bearer $CONTROLLER_API_KEY" -H "Content-Type: application/json" -d '{"action":"disable"}' http://$VM_IP:8080/maintenance` |
| SSH to operator | `ssh -p 2200 root@$VM_IP` (only in Internet mode) |
| Get logs | `atakit get-logs gcp <vm-name>` |

## Security Considerations

1. **CAP_NET_ADMIN**: The controller requires `NET_ADMIN` capability to manage nftables rules. This is isolated to the controller's network namespace.

2. **SSH Isolation**: SSH access to the operator is only available in Internet mode (maintenance enabled). When in Tool-node mode, inbound SSH is blocked at the nftables level.

3. **Authenticated API Mode Switching**: The `POST /maintenance` endpoint requires a Bearer token (`CONTROLLER_API_KEY`). If no key is configured, the endpoint rejects all requests (fail-closed). On mode switch, the controller notifies tool-node via JWT-authenticated JSON-RPC.

4. **Atomic Rules**: Mode switches use atomic nftables transactions to prevent inconsistent states during transitions.

5. **Connection Tracking**: The `ct state established,related` rule ensures that existing connections (like the controller's API responses) continue to work.

6. **Default Isolated**: The controller starts in Tool-node mode (isolated), ensuring the operator cannot access the WAN until explicitly enabled via maintenance mode.

## Troubleshooting

### Controller API not reachable in tool-node mode
Ensure the localhost exception rule is present. The operator uses `127.0.0.1:8080` to reach the controller when they share a network namespace.

### Mode doesn't switch when toggling maintenance
Check controller logs for RPC calls:
```bash
./cvm-cli get-logs gcp <vm-name> | grep "RPC\|maintenance"
```

### Operator can access WAN in Tool-node mode
This indicates a race condition or stale rules. Ensure you're using the latest controller version with atomic nftables transactions.

### Cannot SSH even with maintenance mode enabled
1. Ensure port 2200 is open in the cloud provider's firewall rules
2. Ensure the controller is in Internet mode:
   ```bash
   curl -X POST -H "Authorization: Bearer $CONTROLLER_API_KEY" \
     -H "Content-Type: application/json" -d '{"action":"enable"}' \
     http://$VM_IP:8080/maintenance
   ```

### SSH key authentication fails
Ensure `SSH_PUBLIC_KEY` is set in `.env` (or `SSH_PUBLIC_KEY_FILE` pointing to your key), then redeploy the workload.
