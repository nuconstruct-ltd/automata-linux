#!/bin/bash
# Toggle maintenance mode (SSH access) on a deployed CVM.
# Usage: maintenance_mode.sh <CSP> <VM_NAME> <ACTION> [DELAY_SECONDS]
#   ACTION: enable | disable
#   DELAY_SECONDS: optional, seconds before the action takes effect (default: 0)

CSP=$1
VM_NAME=$2
ACTION=$3
DELAY_SECONDS="${4:-0}"
ARTIFACT_DIR="${ARTIFACT_DIR:-_artifacts}"

if [[ $# -lt 3 ]]; then
    echo "❌ Error: Arguments are missing! (maintenance_mode.sh)"
    echo "Usage: $0 <CSP> <VM_NAME> <enable|disable> [DELAY_SECONDS]"
    exit 1
fi

if [[ "$ACTION" != "enable" && "$ACTION" != "disable" ]]; then
    echo "❌ Error: ACTION must be 'enable' or 'disable', got '$ACTION'"
    exit 1
fi

IP_FILE="$ARTIFACT_DIR/${CSP}_${VM_NAME}_ip"
API_TOKEN_FILE="$ARTIFACT_DIR/${CSP}_${VM_NAME}_token"

set -Eeuo pipefail

if [[ ! -f "$IP_FILE" ]]; then
    echo "❌ Error: '$IP_FILE' does not exist. (maintenance_mode.sh)"
    exit 1
fi
if [[ ! -f "$API_TOKEN_FILE" ]]; then
    echo "❌ Error: '$API_TOKEN_FILE' does not exist. (maintenance_mode.sh)"
    exit 1
fi

VM_IP=$(<"$IP_FILE")
PASSWORD=$(<"$API_TOKEN_FILE")

BODY="{\"action\":\"$ACTION\",\"delay_seconds\":$DELAY_SECONDS}"

echo "ℹ️  Sending maintenance mode '$ACTION' request to $VM_IP..."

response=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $PASSWORD" \
    -H "Content-Type: application/json" \
    -d "$BODY" \
    -k "https://$VM_IP:8000/maintenance-mode")

body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)

if [[ "$code" -ne 200 ]]; then
    echo "❌ Error (status $code):"
    echo "$body"
    exit 1
else
    echo "✅ Maintenance mode '$ACTION' triggered successfully."
    if [[ "$ACTION" == "enable" ]]; then
        echo "🔑 SSH available at: ssh -p 2222 root@$VM_IP"
    fi
    echo "$body" | jq . 2>/dev/null || echo "$body"
fi

set +e
