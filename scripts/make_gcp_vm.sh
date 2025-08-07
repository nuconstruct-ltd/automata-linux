VM_NAME=$1
ZONE=$2
PROJECT_ID=$3
VM_TYPE=$4
BUCKET=$5
ADDITIONAL_PORTS=$6
IP=$7
DATA_DISK="$8"          # Optional disk name
DISK_SIZE_GB="$9"       # Optional disk size (for new disk)



COMPRESSED_FILE="gcp_disk.tar.gz"
UPLOADED_COMPRESSED_FILE="${VM_NAME}.tar.gz"
IMAGE_NAME="${VM_NAME}-image"



# Ensure all arguments are provided
if [[ $# -lt 9 ]]; then
    echo "❌ Error: Arguments are missing! (make_gcp_vm.sh)"
    exit 1
fi

set -e
set -x

# Create bucket if it does not exist
if ! gsutil ls -b "gs://$BUCKET" >/dev/null 2>&1; then
  echo "Bucket gs://$BUCKET does not exist, creating it..."
  BUCKET_REGION=$(echo "$ZONE" | sed 's/-[a-z]$//')
  if gcloud storage buckets create "gs://$BUCKET" --location="$BUCKET_REGION"; then
    echo "Bucket '$BUCKET' created successfully."
  else
    echo "Failed to create bucket '$BUCKET'."
    exit 1
  fi
fi

# Copy the image to bucket and create image
gsutil cp $COMPRESSED_FILE gs://$BUCKET/$UPLOADED_COMPRESSED_FILE

LOCATION="asia"
if [[ "$ZONE" == *eu* ]]; then
    LOCATION="eu"
elif [[ "$ZONE" == *us* ]]; then
    LOCATION="us"
else
    LOCATION="asia"
fi

if gcloud compute images describe $IMAGE_NAME --project="$PROJECT_ID" --quiet > /dev/null 2>&1; then
    # image exists, clean it up first
    echo "Old image exists, cleaning up first..."
    gcloud compute images delete $IMAGE_NAME --project="$PROJECT_ID" --quiet
fi

# If livepatch keys exist, include them in the Signature DB.
SIGFILES=secure_boot/db.crt,secure_boot/kernel.crt
if [ -f "secure_boot/livepatch.crt" ]; then
  SIGFILES="$SIGFILES,secure_boot/livepatch.crt"
fi
gcloud compute images create $IMAGE_NAME \
  --source-uri gs://$BUCKET/$UPLOADED_COMPRESSED_FILE \
  --project="$PROJECT_ID" \
  --guest-os-features "TDX_CAPABLE,SEV_SNP_CAPABLE,GVNIC,UEFI_COMPATIBLE,VIRTIO_SCSI_MULTIQUEUE" \
  --storage-location="$LOCATION" \
  --platform-key-file=secure_boot/PK.crt \
  --key-exchange-key-file=secure_boot/KEK.crt \
  --signature-database-file="$SIGFILES"


ALLOW_PORTS="tcp:8000"
if [[ -n "$ADDITIONAL_PORTS" ]]; then
  ALLOW_PORTS="$(echo "$ADDITIONAL_PORTS" | sed 's/[^,]*/tcp:&/g'),$ALLOW_PORTS"
fi

RULE_NAME="${VM_NAME}-ingress"

echo "🔍 Checking whether firewall rule $RULE_NAME already exists..."
if gcloud compute firewall-rules describe "$RULE_NAME" \
        --project="$PROJECT_ID" --quiet >/dev/null 2>&1; then
  echo "♻️ Deleting existing rule $RULE_NAME..."
  gcloud compute firewall-rules delete "$RULE_NAME" --project="$PROJECT_ID" --quiet
fi

# create firewall rules
if [[ -n "$ALLOW_PORTS" ]]; then
  gcloud compute firewall-rules create $RULE_NAME \
    --project=$PROJECT_ID \
    --allow $ALLOW_PORTS \
    --target-tags $RULE_NAME \
    --description "Allow cvm workload traffic" \
    --direction INGRESS \
    --priority 1000 \
    --network default
fi

# Check if tdx or sev-snp vm
CC_TYPE="TDX"
if [[ $VM_TYPE == *"n2d-"* ]]; then
  CC_TYPE="SEV_SNP"
fi

ADDITIONAL_ARGS=""
if [[ -n "$IP" ]]; then
  ADDITIONAL_ARGS="--address=$IP --network-tier=STANDARD "
fi

# Check if disk exists and create or attach
if [[ -n "$DATA_DISK" ]]; then
  if gcloud compute disks describe "$DATA_DISK" --zone="$ZONE" --project="$PROJECT_ID" > /dev/null 2>&1; then
    # Disk exists, check type
    DISK_TYPE=$(gcloud compute disks describe "$DATA_DISK" --zone="$ZONE" --project="$PROJECT_ID" --format="value(type)")

    if [[ "$VM_TYPE" == c3-* && "$DISK_TYPE" == *"pd-standard"* ]]; then
      echo "⚠️ Disk $DATA_DISK is pd-standard and incompatible with $VM_TYPE. Creating SSD copy..."

      SNAP_NAME="${DATA_DISK}-snap-$(date +%s)"
      NEW_DISK="${DATA_DISK}-ssd"

      # Create snapshot
      gcloud compute disks snapshot "$DATA_DISK" \
          --snapshot-names="$SNAP_NAME" \
          --zone="$ZONE" \
          --project="$PROJECT_ID"

      # Create SSD disk from snapshot
      gcloud compute disks create "$NEW_DISK" \
          --source-snapshot="$SNAP_NAME" \
          --type=pd-balanced \
          --zone="$ZONE" \
          --project="$PROJECT_ID"

      # Delete the temporary snapshot
      echo "🧹 Deleting temporary snapshot $SNAP_NAME..."
      gcloud compute snapshots delete "$SNAP_NAME" \
          --project="$PROJECT_ID" \
          --zone="$ZONE" \
          --quiet

      # Attach the new SSD disk
      DATA_DISK="$NEW_DISK"
    else
      echo "Attaching existing disk $DATA_DISK to VM $VM_NAME"
    fi
  else
    SIZE="${DISK_SIZE_GB:-10}"
    echo "Creating and attaching new disk $DATA_DISK (${SIZE}GB)"
    gcloud compute disks create "$DATA_DISK" \
        --size="$SIZE" \
        --type=pd-balanced \
        --zone="$ZONE" \
        --project="$PROJECT_ID"
  fi

  # Final attach args (either original or converted disk)
  ADDITIONAL_ARGS="--disk=name=$DATA_DISK,auto-delete=no,boot=no"
fi
# create the vm
gcloud compute instances create $VM_NAME \
  --machine-type=$VM_TYPE \
  --zone="$ZONE" \
  --confidential-compute-type="$CC_TYPE" \
  --maintenance-policy=TERMINATE \
  --image-project=$PROJECT_ID \
  --image=$IMAGE_NAME \
  --shielded-secure-boot \
  --shielded-vtpm \
  --shielded-integrity-monitoring \
  --project=$PROJECT_ID \
  --tags $RULE_NAME \
  $ADDITIONAL_ARGS \
  --metadata serial-port-enable=1,serial-port-logging-enable=1

PUBLIC_IP=$(gcloud compute instances describe "$VM_NAME" \
  --zone="$ZONE" \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)')

echo "Public IP: $PUBLIC_IP"

# Save artifacts for later use
mkdir -p _artifacts
echo "$PUBLIC_IP" > _artifacts/gcp_${VM_NAME}_ip
echo "$BUCKET" > _artifacts/gcp_${VM_NAME}_bucket
echo "$ZONE" > _artifacts/gcp_${VM_NAME}_region
echo "$PROJECT_ID" > _artifacts/gcp_${VM_NAME}_project
if [[ -n "$DATA_DISK" ]]; then
  echo "$DATA_DISK" > _artifacts/gcp_${VM_NAME}_disk
fi

set +x
set +e
