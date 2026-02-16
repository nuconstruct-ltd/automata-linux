#!/bin/bash
# Creates or reuses an Azure static public IP.
# Usage: create_static_ip_azure.sh <IP_NAME> <RESOURCE_GROUP> <REGION> <VM_NAME> <ARTIFACT_DIR>

IP_NAME="$1"
RESOURCE_GROUP="$2"
REGION="$3"
VM_NAME="$4"
ARTIFACT_DIR="${5:-_artifacts}"

if [[ $# -lt 5 ]]; then
    echo "❌ Error: Arguments are missing! (create_static_ip_azure.sh)"
    exit 1
fi

set -euo pipefail

# Ensure resource group exists
if ! az group show --name "$RESOURCE_GROUP" &>/dev/null; then
    echo "Creating resource group: $RESOURCE_GROUP"
    az group create --name "$RESOURCE_GROUP" --location "$REGION"
fi

# Check if the public IP already exists
EXISTING_IP=$(az network public-ip show \
    --name "$IP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query 'ipAddress' \
    --output tsv 2>/dev/null || true)

if [[ -n "$EXISTING_IP" ]]; then
    echo "♻️  Reusing existing static IP '$IP_NAME': $EXISTING_IP"
else
    echo "🔧 Creating new static IP '$IP_NAME' in $REGION..."
    az network public-ip create \
        --name "$IP_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$REGION" \
        --sku Standard \
        --allocation-method Static
    EXISTING_IP=$(az network public-ip show \
        --name "$IP_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query 'ipAddress' \
        --output tsv)
    echo "✅ Created static IP '$IP_NAME': $EXISTING_IP"
fi

# Save to artifacts (VM_NAME prefix so cleanup glob catches them)
mkdir -p "$ARTIFACT_DIR"
echo "$EXISTING_IP" > "$ARTIFACT_DIR/azure_${VM_NAME}_static_ip"
echo "$IP_NAME" > "$ARTIFACT_DIR/azure_${VM_NAME}_static_ip_name"

# Output the IP resource name for the caller (az vm create needs the name, not the address)
echo "$IP_NAME"
