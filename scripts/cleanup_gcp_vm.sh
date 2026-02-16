#!/bin/bash
VM_NAME=$1
ARTIFACT_DIR="${2:-_artifacts}"  # Artifact directory (passed from atakit)

# quit when any error occurs
set -Eeuo pipefail

# Ensure all arguments are provided
if [[ $# -lt 2 ]]; then
    echo "❌ Error: Arguments are missing! (cleanup_gcp_vm.sh)"
    exit 1
fi

# Check if artifact files exist
BUCKET_FILE="$ARTIFACT_DIR/gcp_${VM_NAME}_bucket"
ZONE_FILE="$ARTIFACT_DIR/gcp_${VM_NAME}_region"
PROJECT_FILE="$ARTIFACT_DIR/gcp_${VM_NAME}_project"

missing_files=()
[[ ! -f "$BUCKET_FILE" ]] && missing_files+=("$BUCKET_FILE")
[[ ! -f "$ZONE_FILE" ]] && missing_files+=("$ZONE_FILE")
[[ ! -f "$PROJECT_FILE" ]] && missing_files+=("$PROJECT_FILE")

if [[ ${#missing_files[@]} -gt 0 ]]; then
    echo "❌ Error: Missing artifact files for VM '$VM_NAME':"
    for f in "${missing_files[@]}"; do
        echo "   - $f"
    done
    echo ""
    echo "These files are created during deployment. Make sure the VM was deployed with this name."
    echo ""
    echo "To manually cleanup, use gcloud commands:"
    echo "  gcloud compute instances delete $VM_NAME --zone=<ZONE> --project=<PROJECT_ID> --delete-disks=all --quiet"
    echo "  gcloud compute firewall-rules delete ${VM_NAME}-ingress --project=<PROJECT_ID> --quiet"
    echo "  gcloud compute images delete ${VM_NAME}-image --project=<PROJECT_ID> --quiet"
    echo "  gsutil -m rm -r gs://<BUCKET_NAME>"
    exit 1
fi

BUCKET=$(<"$BUCKET_FILE")
ZONE=$(<"$ZONE_FILE")
PROJECT_ID=$(<"$PROJECT_FILE")

# Delete the VM
gcloud compute instances delete $VM_NAME --zone="$ZONE" --project="$PROJECT_ID" --delete-disks=all --quiet || true
# Delete the ingress
gcloud compute firewall-rules delete "${VM_NAME}-ingress" --project="$PROJECT_ID" --quiet || true
# Delete the image
gcloud compute images delete "${VM_NAME}-image" --project="$PROJECT_ID" --quiet || true
# Delete the bucket
gsutil -m rm -r gs://$BUCKET || true

# Release static IP if artifact exists
if [[ -f "$ARTIFACT_DIR/gcp_${VM_NAME}_static_ip_name" ]]; then
    STATIC_IP_NAME=$(<"$ARTIFACT_DIR/gcp_${VM_NAME}_static_ip_name")
    GCP_REGION=$(echo "$ZONE" | sed 's/-[a-z]$//')
    echo "🔧 Releasing static IP: $STATIC_IP_NAME"
    gcloud compute addresses delete "$STATIC_IP_NAME" \
        --region="$GCP_REGION" --project="$PROJECT_ID" --quiet || true
fi

# Remove the artifacts related to this GCP VM
echo "ℹ️  Removing artifacts for GCP VM '$VM_NAME'..."
rm -f "$ARTIFACT_DIR/gcp_${VM_NAME}_"*

echo "✅ Cleanup completed for GCP VM '$VM_NAME'."

set +e
