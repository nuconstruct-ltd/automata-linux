#!/bin/bash

CSP=$1
VM_NAME=$2
LIVEPATCH_PATH=$3
ARTIFACT_DIR="${ARTIFACT_DIR:-_artifacts}"  # Use env var or default

# Ensure all arguments are provided
if [[ $# -lt 3 ]]; then
  echo "❌ Error: Arguments are missing! (livepatch.sh)"
  exit 1
fi

# quit when any error occurs
set -Eeuo pipefail

IP_FILE="$ARTIFACT_DIR/${CSP}_${VM_NAME}_ip"
API_TOKEN_FILE="$ARTIFACT_DIR/${CSP}_${VM_NAME}_token"


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
    $SCRIPT_DIR/get_golden_measurements.sh "$CSP" "$VM_NAME"
fi

set +e
