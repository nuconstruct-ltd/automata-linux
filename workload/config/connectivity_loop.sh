#!/bin/sh

# Tool node port - 8545 for production (tool-node RPC), override with env var for testing
TOOL_NODE_PORT="${TOOL_NODE_PORT:-8545}"
CONTROLLER_API="http://127.0.0.1:8080"

check_connectivity() {
    echo "--- [$(date)] Connectivity Check ---"
    
    # Check current mode from controller
    MODE=$(curl -s --connect-timeout 2 ${CONTROLLER_API}/mode 2>/dev/null || echo "unavailable")
    echo "Controller Mode: $MODE"
    
    # Check Internet (WAN)
    if curl -s --connect-timeout 2 https://google.com > /dev/null 2>&1; then
        echo "✅ Internet (WAN): UP"
    else
        echo "❌ Internet (WAN): DOWN"
    fi

    # Check Tool Node
    if curl -s --connect-timeout 2 http://172.20.0.10:${TOOL_NODE_PORT} > /dev/null 2>&1; then
        echo "✅ Tool Node: UP"
    else
        echo "❌ Tool Node: DOWN"
    fi
    
    echo ""
}

echo "=== OPERATOR CONNECTIVITY MONITOR ==="
echo "Default mode: tool-node (isolated)"
echo "Mode switching controlled via CVM maintenance mode (SIGUSR2)"
echo ""

# Continuous monitoring loop
while true; do
    check_connectivity
    sleep 5
done
