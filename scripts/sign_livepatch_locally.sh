#!/bin/bash

LIVEPATCH_PATH=$1

# Ensure all arguments are provided
if [[ $# -lt 1 ]]; then
  echo "❌ Error: Arguments are missing! (sign_livepatch_locally.sh)"
  exit 1
fi

# quit when any error occurs
set -Eeuo pipefail

# 1. Sign the livepatch
LIVEPATCH_PRIV_KEY="secure_boot/livepatch.key"
LIVEPATCH_PUB_KEY="secure_boot/livepatch.crt"
if [[ ! -f "$LIVEPATCH_PRIV_KEY" || ! -f "$LIVEPATCH_PUB_KEY" ]]; then
  echo "❌ Error: Livepatch keys not found! (sign-livepatch.sh)"
  echo "❌ Please run `./cvm-cli generate-livepatch-keys` and re-deploy any existing CVM so that livepatch keys will be loaded with secure boot."
  exit 1
fi

SIGN_FILE_PATH="/lib/modules/$(uname -r)/build/scripts/sign-file"

"$SIGN_FILE_PATH" sha256 "$LIVEPATCH_PRIV_KEY" "$LIVEPATCH_PUB_KEY" "$LIVEPATCH_PATH"


set +e