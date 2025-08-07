#!/bin/bash

set -euo pipefail

VM_NAME="ubuntu-vm"
DISK_FILE="$1"
DISK_FILENAME=$(basename "$DISK_FILE")
PROJECT_DIR=$(dirname "$DISK_FILE")
VM_PROJECT_DIR="cvm-tmp"
UPDATED_DISK="$PROJECT_DIR/$DISK_FILENAME"

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

# Step 3: Validate disk exists
if [[ ! -f "$DISK_FILE" ]]; then
  echo "❌ Disk file not found: $DISK_FILE"
  exit 1
fi

# Step 4: Checksum before update
echo "🔍 Calculating checksum before update..."
BEFORE_SUM=$(shasum -a 256 "$DISK_FILE" | awk '{print $1}')
echo "Before: $BEFORE_SUM"

# Step 5: Transfer to VM
echo "📤 Transferring project to VM..."
VM_PROJECT_PATH="/tmp/$VM_PROJECT_DIR"
multipass exec "$VM_NAME" -- bash -c "
  mkdir -p $VM_PROJECT_PATH
"
multipass transfer -r "scripts/" "workload/" "$DISK_FILE" "$VM_NAME:$VM_PROJECT_PATH"

# Step 7: Run update logic inside VM
echo "🛠️ Running update logic inside VM..."
multipass exec "$VM_NAME" -- bash -c "
  set -euo pipefail
  cd $VM_PROJECT_PATH
  chmod +x ./scripts/update_disk_locally.sh
  echo '▶️ Running: ./scripts/update_disk_locally.sh $DISK_FILENAME'
  ./scripts/update_disk_locally.sh $DISK_FILENAME
"

# Step 8: Retrieve updated disk
echo "📥 Retrieving updated disk..."
multipass transfer "$VM_NAME:$VM_PROJECT_PATH/$DISK_FILENAME" "$UPDATED_DISK"

# Step 9: Checksum after update
echo "🔍 Calculating checksum after update..."
AFTER_SUM=$(shasum -a 256 "$UPDATED_DISK" | awk '{print $1}')
echo "After:  $AFTER_SUM"

# Step 10: Compare
if [[ "$BEFORE_SUM" == "$AFTER_SUM" ]]; then
  echo "❌ No change — update failed!"
else
  echo "✅ Disk successfully updated!"
fi

# Step 11: Cleanup
# No cleanup here, we need to generate an API token later.
