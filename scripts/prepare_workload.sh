#!/bin/bash
# Prepare workload config files before baking into disk image.
# Generates authorized_keys and Caddyfile from environment variables.
# These files are written into the workload directory and baked into the VM image,
# but should NOT be committed to the repository.
#
# Required env vars (from .env or atakit flags):
#   SSH_PUBLIC_KEY_FILE  - path to SSH public key (optional, warns if missing)
#   CADDY_RPC_DOMAIN     - domain for tool-node RPC (optional)
#   CADDY_CVM_DOMAIN     - domain for CVM agent (optional)
#   CADDY_CONTROLLER_DOMAIN - domain for controller API (optional)

WORKLOAD_DIR="${WORKLOAD_DIR:-$(pwd)/workload}"
CONFIG_DIR="$WORKLOAD_DIR/config"

set -euo pipefail

echo "📋 Preparing workload config files..."

# --- authorized_keys ---
AUTH_KEYS_FILE="$CONFIG_DIR/authorized_keys"
if [[ -n "${SSH_PUBLIC_KEY_FILE:-}" ]]; then
    # Expand ~ in path
    SSH_KEY_PATH="${SSH_PUBLIC_KEY_FILE/#\~/$HOME}"
    if [[ -f "$SSH_KEY_PATH" ]]; then
        cp "$SSH_KEY_PATH" "$AUTH_KEYS_FILE"
        echo "  ✅ authorized_keys populated from $SSH_KEY_PATH"
    else
        echo "  ⚠️  SSH_PUBLIC_KEY_FILE set to '$SSH_PUBLIC_KEY_FILE' but file not found"
        echo "  ⚠️  SSH access to operator will not work without a valid public key"
    fi
elif [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
    # Allow passing the key content directly
    echo "$SSH_PUBLIC_KEY" > "$AUTH_KEYS_FILE"
    echo "  ✅ authorized_keys populated from SSH_PUBLIC_KEY env var"
else
    echo "  ⚠️  No SSH_PUBLIC_KEY_FILE or SSH_PUBLIC_KEY set"
    echo "  ⚠️  SSH access to operator will not work without a valid public key"
fi

# --- Caddyfile ---
CADDYFILE="$CONFIG_DIR/Caddyfile"
TEMPLATE="$CONFIG_DIR/Caddyfile.template"

if [[ -n "${CADDY_RPC_DOMAIN:-}" || -n "${CADDY_CVM_DOMAIN:-}" || -n "${CADDY_CONTROLLER_DOMAIN:-}" ]]; then
    if [[ ! -f "$TEMPLATE" ]]; then
        echo "  ❌ Caddyfile.template not found at $TEMPLATE"
        exit 1
    fi

    # Generate Caddyfile from template by replacing placeholders
    cp "$TEMPLATE" "$CADDYFILE"
    sed -i.bak "s|RPC_DOMAIN|${CADDY_RPC_DOMAIN:-:8545}|g" "$CADDYFILE"
    sed -i.bak "s|CVM_AGENT_DOMAIN|${CADDY_CVM_DOMAIN:-:8000}|g" "$CADDYFILE"
    sed -i.bak "s|CONTROLLER_DOMAIN|${CADDY_CONTROLLER_DOMAIN:-:8081}|g" "$CADDYFILE"
    rm -f "$CADDYFILE.bak"
    echo "  ✅ Caddyfile generated with domains:"
    echo "     RPC:        ${CADDY_RPC_DOMAIN:-:8545}"
    echo "     CVM Agent:  ${CADDY_CVM_DOMAIN:-:8000}"
    echo "     Controller: ${CADDY_CONTROLLER_DOMAIN:-:8081}"
else
    echo "  ℹ️  No CADDY_*_DOMAIN vars set — using default Caddyfile (port-based, no TLS)"
fi

echo "📋 Workload config preparation complete."
