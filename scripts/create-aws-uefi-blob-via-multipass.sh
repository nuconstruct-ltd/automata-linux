#!/bin/bash

set -euo pipefail

VM_NAME="ubuntu-vm"
AWS_UEFI_BLOB_PATH="secure_boot/aws-uefi-blob.bin"
VM_PROJECT_DIR="cvm-tmp"

# Step 1: Install multipass if missing
if ! command -v multipass &>/dev/null; then
  echo "🔧 Installing Multipass..."
  brew install --cask multipass
fi

# Step 2: Launch VM if it doesn't exist or is stopped
STATUS=$(multipass info "$VM_NAME" 2>/dev/null | grep '^State:' | awk '{print $2}' || true)

if [[ "$STATUS" == "Stopped" ]]; then
  echo "🔌 Instance '$VM_NAME' exists but is stopped. Starting it..."
  multipass start "$VM_NAME"
elif [[ -z "$STATUS" ]]; then
  echo "🚀 Launching VM '$VM_NAME'..."
  multipass launch jammy --name "$VM_NAME" --disk 10G --memory 4G --cpus 2
fi

# Step 3: Transfer to VM
echo "📤 Transferring project to VM..."
VM_PROJECT_PATH="/tmp/$VM_PROJECT_DIR"
multipass exec "$VM_NAME" -- bash -c "
  mkdir -p $VM_PROJECT_PATH
"
multipass transfer -r "scripts/" "secure_boot/" "tools/" "$VM_NAME:$VM_PROJECT_PATH"

# Step 4: Run logic inside VM
echo "🛠️ Running inside VM..."
multipass exec "$VM_NAME" -- bash -c "
  set -euo pipefail
  echo 'Installing dependencies...'
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  export UCF_FORCE_CONFOLD=1
  export DPKG_OPTIONS='--force-confold'
  echo 'Waiting for APT locks to be released...'
  while fuser /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
    sleep 1
  done
  echo 'APT is ready.'
  sudo apt update && sudo apt install -yq efitools python3 python3-pip
  sudo pip3 install --no-input pefile google_crc32c
  cd $VM_PROJECT_PATH
  chmod +x ./scripts/create-aws-uefi-blob-locally.sh
  echo '▶️ Running: ./scripts/create-aws-uefi-blob-locally.sh'
  ./scripts/create-aws-uefi-blob-locally.sh
"

# Step 5: Retrieve updated AWS UEFI blob
echo "📥 Retrieving updated AWS UEFI blob..."
multipass transfer "$VM_NAME:$VM_PROJECT_PATH/$AWS_UEFI_BLOB_PATH" "$AWS_UEFI_BLOB_PATH"


# Step 6: Cleanup
multipass stop "$VM_NAME"