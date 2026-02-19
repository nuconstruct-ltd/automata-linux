#!/bin/bash
# Toggle network mode directly via the controller API.
# Unlike maintenance_mode.sh (which goes through the CVM agent on port 8000),
# this calls the controller's POST /maintenance endpoint directly.
# On mode switch, the controller also sends SIGUSR1/SIGUSR2 to tool-node and operator.
#
# Usage: network_mode.sh <CSP> <VM_NAME> <ACTION>
#   ACTION: enable | disable
#     enable  = switch to internet mode (SIGUSR1 sent to tool-node & operator)
#     disable = switch to tool-node mode (SIGUSR2 sent to tool-node & operator)

CSP=$1
VM_NAME=$2
ACTION=$3
ARTIFACT_DIR="${ARTIFACT_DIR:-_artifacts}"

if [[ $# -lt 3 ]]; then
    echo "❌ Error: Arguments are missing! (network_mode.sh)"
    echo "Usage: $0 <CSP> <VM_NAME> <enable|disable>"
    exit 1
fi

if [[ "$ACTION" != "enable" && "$ACTION" != "disable" ]]; then
    echo "❌ Error: ACTION must be 'enable' or 'disable', got '$ACTION'"
    exit 1
fi

IP_FILE="$ARTIFACT_DIR/${CSP}_${VM_NAME}_ip"
CONTROLLER_KEY_FILE="$ARTIFACT_DIR/${CSP}_${VM_NAME}_controller_key"

set -Eeuo pipefail

if [[ ! -f "$IP_FILE" ]]; then
    echo "❌ Error: '$IP_FILE' does not exist. (network_mode.sh)"
    exit 1
fi

# Controller API key can come from file or environment variable
if [[ -f "$CONTROLLER_KEY_FILE" ]]; then
    CONTROLLER_API_KEY=$(<"$CONTROLLER_KEY_FILE")
elif [[ -n "${CONTROLLER_API_KEY:-}" ]]; then
    : # Use from environment
else
    echo "❌ Error: No controller API key found."
    echo "   Set CONTROLLER_API_KEY env var or create: $CONTROLLER_KEY_FILE"
    exit 1
fi

VM_IP=$(<"$IP_FILE")

BODY="{\"action\":\"$ACTION\"}"

echo "ℹ️  Sending network mode '$ACTION' request to controller at $VM_IP:8080..."

response=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $CONTROLLER_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$BODY" \
    "http://$VM_IP:8080/maintenance")

body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)

if [[ "$code" -ne 200 ]]; then
    echo "❌ Error (status $code):"
    echo "$body" | jq . 2>/dev/null || echo "$body"
    exit 1
else
    echo "✅ Network mode '$ACTION' applied successfully."
    echo "$body" | jq . 2>/dev/null || echo "$body"
fi

set +e
