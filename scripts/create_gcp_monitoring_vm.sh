#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/create_gcp_monitoring_vm.env" ] && source "$SCRIPT_DIR/create_gcp_monitoring_vm.env"

for v in PROJECT_ID ZONE VM_NAME VM_TYPE DISK_SIZE; do
  [ -n "${!v}" ] || { echo "Missing env: $v (set in env or create_gcp_monitoring_vm.env)"; exit 1; }
done
[ -n "$1" ] || { echo "Usage: $0 <your-public-ip>"; exit 1; }
LOCAL_IP="$1"

gcloud compute disks create "${VM_NAME}-data" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --size="${DISK_SIZE}GB" \
  --type=pd-balanced

gcloud compute instances create "$VM_NAME" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --machine-type="$VM_TYPE" \
  --image-family=ubuntu-2204-lts \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=20GB \
  --disk=name="${VM_NAME}-data",mode=rw,boot=no \
  --tags="${VM_NAME}-ingress"

gcloud compute firewall-rules create "${VM_NAME}-ingress-ssh" \
  --project="$PROJECT_ID" \
  --allow=tcp:22 \
  --target-tags="${VM_NAME}-ingress"

gcloud compute firewall-rules create "${VM_NAME}-ingress-grafana" \
  --project="$PROJECT_ID" \
  --allow=tcp:3000 \
  --source-ranges="${LOCAL_IP}/32" \
  --target-tags="${VM_NAME}-ingress"
