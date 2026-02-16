#!/bin/bash
# Creates or reuses a GCP static IP address.
# Usage: create_static_ip_gcp.sh <IP_NAME> <ZONE> <PROJECT_ID> <VM_NAME> <ARTIFACT_DIR>

IP_NAME="$1"
ZONE="$2"
PROJECT_ID="$3"
VM_NAME="$4"
ARTIFACT_DIR="${5:-_artifacts}"

if [[ $# -lt 5 ]]; then
    echo "❌ Error: Arguments are missing! (create_static_ip_gcp.sh)"
    exit 1
fi

set -euo pipefail

# Extract region from zone (e.g., "asia-southeast1-b" -> "asia-southeast1")
GCP_REGION=$(echo "$ZONE" | sed 's/-[a-z]$//')

# Check if the address already exists
EXISTING_IP=$(gcloud compute addresses describe "$IP_NAME" \
    --region="$GCP_REGION" \
    --project="$PROJECT_ID" \
    --format='get(address)' 2>/dev/null || true)

if [[ -n "$EXISTING_IP" ]]; then
    echo "♻️  Reusing existing static IP '$IP_NAME': $EXISTING_IP"
    IP_ADDRESS="$EXISTING_IP"
else
    echo "🔧 Creating new static IP '$IP_NAME' in region $GCP_REGION..."
    gcloud compute addresses create "$IP_NAME" \
        --region="$GCP_REGION" \
        --project="$PROJECT_ID"
    IP_ADDRESS=$(gcloud compute addresses describe "$IP_NAME" \
        --region="$GCP_REGION" \
        --project="$PROJECT_ID" \
        --format='get(address)')
    echo "✅ Created static IP '$IP_NAME': $IP_ADDRESS"
fi

# Save to artifacts (VM_NAME prefix so cleanup glob catches them)
mkdir -p "$ARTIFACT_DIR"
echo "$IP_ADDRESS" > "$ARTIFACT_DIR/gcp_${VM_NAME}_static_ip"
echo "$IP_NAME" > "$ARTIFACT_DIR/gcp_${VM_NAME}_static_ip_name"

# Output the IP address for the caller to capture
echo "$IP_ADDRESS"
