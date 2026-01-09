#!/bin/bash

# Use SCRIPT_DIR from environment, or detect from this script's location
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

LIVEPATCH_PATH=$1

# quit when any error occurs
set -Eeuo pipefail

# Ensure all arguments are provided
if [[ $# -lt 1 ]]; then
  echo "❌ Error: Arguments are missing! (sign_livepatch.sh)"
  exit 1
fi

os_type="$(uname)"
if [[ "$os_type" == "Linux" ]]; then
    echo "Signing livepatch locally..."
    $SCRIPT_DIR/sign_livepatch_locally.sh $LIVEPATCH_PATH
elif [[ "$os_type" == "Darwin" ]]; then
    echo "🔁 Using Multipass to sign livepatch..."
    bash "$SCRIPT_DIR/sign_livepatch_via_multipass.sh" "$LIVEPATCH_PATH"
else
    echo "Unsupported OS: $os_type"
    exit 1
fi

set +e
