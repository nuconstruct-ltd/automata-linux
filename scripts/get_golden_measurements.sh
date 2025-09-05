#!/bin/bash
set -Eeuo pipefail

CSP=$1
VM_NAME=$2

if [[ $# -lt 2 ]]; then
    echo "❌ Error: Arguments are missing! (get_golden_measurements.sh)"
    echo "Usage: $0 <CSP> <VM_NAME>"
    exit 1
fi

IP_FILE="_artifacts/${CSP}_${VM_NAME}_ip"
OFFCHAIN_GOLDEN_MEASUREMENT_FILE="_artifacts/golden-measurements/offchain/${CSP}-${VM_NAME}.json"
ONCHAIN_GOLDEN_MEASUREMENT_FILE="_artifacts/golden-measurements/onchain/${CSP}-${VM_NAME}.json"

MAX_RETRIES=10
RETRY_DELAY=30

if [[ ! -f "$IP_FILE" ]]; then
  echo "❌ Error: '$IP_FILE' does not exist. (get_golden_measurements.sh)"
  exit 1
fi

VM_IP=$(<"$IP_FILE")

echo "ℹ️  Waiting for $VM_IP to be ready..."
sleep 20

OFFCHAIN_URL="https://$VM_IP:8000/offchain/golden-measurement"
ONCHAIN_URL="https://$VM_IP:8000/onchain/golden-measurement"

fetch_with_retries() {
  local url=$1
  local output_file=$2

  mkdir -p "$(dirname "$output_file")"

  echo "ℹ️  Fetching golden measurement: $url"
  for attempt in $(seq 1 $MAX_RETRIES); do
    echo "Attempt $attempt: $url"
    set +e
    HTTP_CODE=$(curl --max-time 60 -k -s -o "$output_file" -w "%{http_code}" "$url")
    CURL_STATUS=$?
    set -e

    if [[ "$CURL_STATUS" -ne 0 ]]; then
      echo "⚠️ curl failed (exit $CURL_STATUS)"
    elif [[ "$HTTP_CODE" == "200" ]]; then
      echo "✅ Saved to $output_file"
      return 0
    else
      echo "⚠️ HTTP $HTTP_CODE"
    fi

    if [[ "$attempt" -lt "$MAX_RETRIES" ]]; then
      echo "⌛ Retrying in $RETRY_DELAY seconds..."
      sleep $RETRY_DELAY
    else
      echo "❌ Error: Failed after $MAX_RETRIES attempts for $url"
      return 1
    fi
  done
}

offchain_status=0
fetch_with_retries "$OFFCHAIN_URL" "$OFFCHAIN_GOLDEN_MEASUREMENT_FILE" || offchain_status=$?

onchain_status=0
fetch_with_retries "$ONCHAIN_URL" "$ONCHAIN_GOLDEN_MEASUREMENT_FILE" || onchain_status=$?

if [[ $offchain_status -ne 0 || $onchain_status -ne 0 ]]; then
  echo "❌ One or more golden measurement fetches failed."
  exit 1
fi

echo "✅ Both offchain and onchain golden measurements retrieved successfully."
set +e