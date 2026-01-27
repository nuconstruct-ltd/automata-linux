#!/bin/bash
VM_NAME=$1
ARTIFACT_DIR="${2:-_artifacts}"  # Artifact directory (passed from atakit)

# quit when any error occurs
set -Eeuo pipefail

# Ensure all arguments are provided
if [[ $# -lt 2 ]]; then
    echo "❌ Error: Arguments are missing! (cleanup_azure_vm.sh)"
    exit 1
fi

# Check if artifact file exists
RG_FILE="$ARTIFACT_DIR/azure_${VM_NAME}_resource_group"

if [[ ! -f "$RG_FILE" ]]; then
    echo "❌ Error: Missing artifact file for VM '$VM_NAME':"
    echo "   - $RG_FILE"
    echo ""
    echo "This file is created during deployment. Make sure the VM was deployed with this name."
    exit 1
fi

RG=$(<"$RG_FILE")  # Load RG from file

# Delete everything in the resource group
echo "ℹ️  Deleting resource group '$RG'..."
az group delete --name "$RG" --yes

# Remove the artifacts related to this Azure VM
echo "ℹ️  Removing artifacts for Azure VM '$VM_NAME'..."
rm -f "$ARTIFACT_DIR/azure_${VM_NAME}_"*

echo "✅ Cleanup completed for Azure VM '$VM_NAME'."

set +e