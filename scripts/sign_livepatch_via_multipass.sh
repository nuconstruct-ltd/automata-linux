#!/bin/bash

set -euo pipefail

VM_NAME="ubuntu-vm"
LIVEPATCH_PATH="$1"
LIVEPATCH_FILENAME=$(basename "$LIVEPATCH_PATH")
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

# Step 3: Validate livepatch exists
if [[ ! -f "$LIVEPATCH_PATH" ]]; then
  echo "❌ Livepatch file not found: $LIVEPATCH_PATH"
  exit 1
fi

# Step 4: Transfer to VM
echo "📤 Transferring project to VM..."
VM_PROJECT_PATH="/tmp/$VM_PROJECT_DIR"
multipass exec "$VM_NAME" -- bash -c "
  mkdir -p $VM_PROJECT_PATH
"
multipass transfer -r "scripts/" "secure_boot/" "$VM_NAME:$VM_PROJECT_PATH"
multipass transfer "$LIVEPATCH_PATH" "$VM_NAME:$VM_PROJECT_PATH/$LIVEPATCH_FILENAME"

# Step 5: Run logic inside VM
echo "🛠️ Running logic inside VM..."
multipass exec "$VM_NAME" -- bash -c "
  set -euo pipefail
  cd $VM_PROJECT_PATH
  chmod +x ./scripts/sign_livepatch_locally.sh
  echo '▶️ Running: ./scripts/sign_livepatch_locally.sh $LIVEPATCH_FILENAME'
  ./scripts/sign_livepatch_locally.sh $LIVEPATCH_FILENAME
"

# Step 6: Retrieve updated livepatch
echo "📥 Retrieving updated livepatch..."
multipass transfer "$VM_NAME:$VM_PROJECT_PATH/$LIVEPATCH_FILENAME" "$LIVEPATCH_PATH"


# Step 7: Cleanup
multipass stop "$VM_NAME"