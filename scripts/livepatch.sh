#!/bin/bash

CSP=$1
VM_NAME=$2
LIVEPATCH_PATH=$3

# Ensure all arguments are provided
if [[ $# -lt 3 ]]; then
  echo "❌ Error: Arguments are missing! (livepatch.sh)"
  exit 1
fi

# quit when any error occurs
set -Eeuo pipefail

# 1. Sign the livepatch
LIVEPATCH_PRIV_KEY="secure_boot/livepatch.key"
LIVEPATCH_PUB_KEY="secure_boot/livepatch.crt"
if [[ ! -f "$LIVEPATCH_PRIV_KEY" || ! -f "$LIVEPATCH_PUB_KEY" ]]; then
  echo "❌ Error: Livepatch keys not found! (livepatch.sh)"
  echo "❌ This VM does not support livepatching. Please run `./cvm-cli generate-livepatch-keys` and re-deploy the CVM."
  exit 1
fi

./deps/sign-file sha256 "$LIVEPATCH_PRIV_KEY" "$LIVEPATCH_PUB_KEY" "$LIVEPATCH_PATH"

IP_FILE="_artifacts/${CSP}_${VM_NAME}_ip"
API_TOKEN_FILE="_artifacts/${CSP}_${VM_NAME}_token"


if [[ ! -f "$IP_FILE" ]]; then
  echo "❌ Error: '$IP_FILE' does not exist. (livepatch.sh)"
  exit 1
fi
if [[ ! -f "$API_TOKEN_FILE" ]]; then
  echo "❌ Error: '$API_TOKEN_FILE' does not exist. (livepatch.sh)"
  exit 1
fi

VM_IP=$(<"$IP_FILE")  # Load IP from file
PASSWORD=$(<"$API_TOKEN_FILE")  # Load API token from file

echo "ℹ️  Deploying kernel livepatch..."

response=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $PASSWORD" -X POST -F "file=@$LIVEPATCH_PATH" -k "https://$VM_IP:8000/livepatch")

# Split response and status code
body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)

if [[ "$code" -ne 200 ]]; then
  echo "❌ Error (status $code):"
  echo "$body"
  exit 1
else
    echo "✅ Livepatch successfully deployed to $VM_NAME ($CSP)."
    echo "ℹ️  Regenerating Golden Measurements now..."
    ./scripts/get_golden_measurements.sh "$CSP" "$VM_NAME"
fi

set +e
