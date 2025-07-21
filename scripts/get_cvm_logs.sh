#!/bin/bash

CSP=$1
VM_NAME=$2

# Ensure all arguments are provided
if [[ $# -lt 2 ]]; then
  echo "❌ Error: Arguments are missing! (update_remote_workload.sh)"
  exit 1
fi

IP_FILE="_artifacts/${CSP}_${VM_NAME}_ip"
API_TOKEN_FILE="_artifacts/${CSP}_${VM_NAME}_token"

# quit when any error occurs
set -Eeuo pipefail

if [[ ! -f "$IP_FILE" ]]; then
  echo "❌ Error: '$IP_FILE' does not exist. (update_remote_workload.sh)"
  exit 1
fi
if [[ ! -f "$API_TOKEN_FILE" ]]; then
  echo "❌ Error: '$API_TOKEN_FILE' does not exist. (update_remote_workload.sh)"
  exit 1
fi

VM_IP=$(<"$IP_FILE")  # Load IP from file
PASSWORD=$(<"$API_TOKEN_FILE")  # Load API token from file

echo "ℹ️  Retrieving VM logs..."

response=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $PASSWORD" -k "https://$VM_IP:8000/container-logs")

# Split response and status code
body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)

if [[ "$code" -ne 200 ]]; then
  echo "❌ Error (status $code):"
  echo "$body"
  exit 1
else
  # Define ANSI colors
  colors=(
    "\033[0;31m" # Red
    "\033[0;32m" # Green
    "\033[0;33m" # Yellow
    "\033[0;34m" # Blue
    "\033[0;35m" # Magenta
    "\033[0;36m" # Cyan
  )
  reset="\033[0m"

  # Use jq to extract name and split log into lines
  echo "$body" | jq -r '
    .[] | {name, lines: (.log | split("\n"))} |
    .lines[] as $line |
    select($line != "") |
    "\(.name)\u0001\($line)"
  ' | while IFS=$'\1' read -r name line; do
    # Hash the name to get a stable color index
    idx=$(( $(echo -n "$name" | cksum | cut -d ' ' -f1) % ${#colors[@]} ))
    color="${colors[$idx]}"
    echo -e "${color}${name}${reset}: $line"
  done
fi

set +e
