#!/bin/bash

# Use SCRIPT_DIR from environment, or detect from this script's location
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# quit when any error occurs
set -Eeuo pipefail

DIR="./tools/python-uefivars"

if [ -d "$DIR" ] && [ -z "$(ls -A "$DIR")" ]; then
  git submodule update --init --recursive
fi

install_missing_tools() {
    # List of system packages to check
    local APT_PACKAGES=(efitools python3-pip python3)

    # List of Python packages to check
    local PYTHON_PACKAGES=(pefile google_crc32c)

    local MISSING_APT=()
    local MISSING_PYTHON=()

    echo "🔍 Checking system packages..."
    for pkg in "${APT_PACKAGES[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            echo "📦 Missing: $pkg"
            MISSING_APT+=("$pkg")
        fi
    done

    echo "🔍 Checking Python packages..."
    for pkg in "${PYTHON_PACKAGES[@]}"; do
        if ! pip3 show "$pkg" &>/dev/null; then
            echo "🐍 Missing Python package: $pkg"
            MISSING_PYTHON+=("$pkg")
        fi
    done

    if [ "${#MISSING_APT[@]}" -gt 0 ]; then
        echo "🛠️ Installing missing APT packages: ${MISSING_APT[*]}"
        sudo apt update && sudo apt install -yq "${MISSING_APT[@]}"
    fi

    if [ "${#MISSING_PYTHON[@]}" -gt 0 ]; then
        echo "🛠️ Installing missing Python packages: ${MISSING_PYTHON[*]}"
        sudo pip3 install --no-input "${MISSING_PYTHON[@]}"
    fi
}


os_type="$(uname)"
if [[ "$os_type" == "Linux" ]]; then
    echo "Create blob locally..."
    install_missing_tools
    $SCRIPT_DIR/create-aws-uefi-blob-locally.sh
elif [[ "$os_type" == "Darwin" ]]; then
    echo "🔁 Using Multipass to create blob..."
    bash "$SCRIPT_DIR/create-aws-uefi-blob-via-multipass.sh"
else
    echo "Unsupported OS: $os_type"
    exit 1
fi

set +e
