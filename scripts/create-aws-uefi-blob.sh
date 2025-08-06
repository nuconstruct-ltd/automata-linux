#!/bin/bash

# quit when any error occurs
set -Eeuo pipefail

os_type="$(uname)"
if [[ "$os_type" == "Linux" ]]; then
    echo "Create blob locally..."
    ./scripts/create-aws-uefi-blob-locally.sh
elif [[ "$os_type" == "Darwin" ]]; then
    echo "🔁 Using Multipass to create blob..."
    bash "./scripts/create-aws-uefi-blob-via-multipass.sh"
else
    echo "Unsupported OS: $os_type"
    exit 1
fi

set +e
