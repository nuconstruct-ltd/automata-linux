VM_NAME=$1
REGION=$2
VM_TYPE=$3
BUCKET=$4
ADDITIONAL_PORTS=$5
EIP_AID=$6
DATA_DISK="$7"       # Optional EBS volume name
DISK_SIZE_GB="$8"    # Optional disk size (for new disk)
ARTIFACT_DIR="${9:-_artifacts}"  # Artifact directory (passed from cvm-cli)

DISK_FILE=aws_disk.vmdk
UPLOADED_DISK_FILE="${VM_NAME}.vmdk"
IMAGE_NAME="${VM_NAME}-image"
export AWS_PAGER=""

# Ensure all arguments are provided
if [[ $# -lt 9 ]]; then
    echo "❌ Error: Arguments are missing! (make_aws_vm.sh)"
    exit 1
fi

set -x
set -e

# Create S3 bucket if it does not exist
if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "Bucket '$BUCKET' does not exist. Creating..."
  if aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"; then
    echo "Bucket created successfully in $REGION"
  else
    echo "❌ Error: Failed to create bucket in $REGION"
    exit 1
  fi
fi

# Import disk into S3
aws s3 cp $DISK_FILE s3://$BUCKET/vms/$UPLOADED_DISK_FILE

# Create the container.json file
cat <<EOF > container.json
{
  "Description": "Minimal CVM Image",
  "Format": "vmdk",
  "UserBucket": {
    "S3Bucket": "$BUCKET",
    "S3Key":   "vms/$UPLOADED_DISK_FILE"
  }
}
EOF

# Import the vmdk disk in S3 into EC2 as a snapshot
IMPORT_JSON=$(aws ec2 import-snapshot \
    --region $REGION \
    --description "Minimal CVM Image" \
    --disk-container file://container.json)

TASK_ID=$(echo "$IMPORT_JSON" | jq -r '.ImportTaskId')
echo "✔ Import task id = $TASK_ID"

# Check State transitions: active → completed
SNAPSHOT_ID=""
while true; do
  STATUS_JSON=$(aws ec2 describe-import-snapshot-tasks       \
                    --region "$REGION"                    \
                    --import-task-ids "$TASK_ID")

  STATUS=$(echo "$STATUS_JSON"   | jq -r '.ImportSnapshotTasks[0].SnapshotTaskDetail.Status')
  PROGRESS=$(echo "$STATUS_JSON" | jq -r '.ImportSnapshotTasks[0].SnapshotTaskDetail.Progress')
  SNAPSHOT_ID=$(echo "$STATUS_JSON" | jq -r '.ImportSnapshotTasks[0].SnapshotTaskDetail.SnapshotId')

  printf '%s  %s (%s%%)\n' "$(date '+%T')" "$STATUS" "${PROGRESS:-0}"

  case "$STATUS" in
    completed)
      echo "🎉  Import finished.";
      break
      ;;
    deleted|deleting|deleted_failed)
      echo "❌  Task ended in failure.";
      echo $STATUS_JSON
      exit 1
      ;;
  esac
  sleep 60
done

rm container.json

# Check whether the UEFI blob exists
UEFI_BLOB="secure_boot/aws-uefi-blob.bin"
if [ -f "$UEFI_BLOB" ]; then
  echo "$UEFI_BLOB exists. Continuing..."
else
  echo "$UEFI_BLOB does not exist! Creating now!"
  $SCRIPT_DIR/create-aws-uefi-blob.sh
fi

# First delete any old AMI with the same name
OLD_AMIS=$(aws ec2 describe-images \
  --region "$REGION" \
  --owners self \
  --filters "Name=name,Values=$IMAGE_NAME" \
  --query 'Images[*].ImageId' \
  --output text)

if [[ -n "$OLD_AMIS" ]]; then
  for AMI in $OLD_AMIS; do
    # collect snapshots the old AMI uses
    SNAP_IDS=$(aws ec2 describe-images \
      --region "$REGION" \
      --image-ids "$AMI" \
      --query 'Images[0].BlockDeviceMappings[*].Ebs.SnapshotId' \
      --output text)
    aws ec2 deregister-image --region "$REGION" --image-id "$AMI"
    echo "✔ Deleted old AMI $AMI"
    for SID in $SNAP_IDS; do
      echo "🗑️ Deleting snapshot $SID"
      aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$SID" || true
    done
  done
fi

# Register the snapshot as AMI
IMAGE_ID=$(aws ec2 register-image \
  --name $IMAGE_NAME \
  --region $REGION \
  --root-device-name /dev/xvda \
  --block-device-mappings DeviceName=/dev/xvda,Ebs=\{SnapshotId=$SNAPSHOT_ID,DeleteOnTermination=true\} \
  --virtualization-type hvm \
  --architecture x86_64 \
  --tpm-support v2.0 \
  --ena-support \
  --boot-mode uefi \
  --uefi-data $(cat $UEFI_BLOB) | jq -r '.ImageId')

echo "✔ Image ID = $IMAGE_ID"

SECGRP_NAME="${VM_NAME}-secgrp"
EXISTING_GROUP_ID=$(aws ec2 describe-security-groups \
  --region "$REGION" \
  --filters Name=group-name,Values="$SECGRP_NAME" \
  --query "SecurityGroups[0].GroupId" \
  --output text 2>/dev/null)

if [[ "$EXISTING_GROUP_ID" != "None" && -n "$EXISTING_GROUP_ID" ]]; then
  echo "Security group $SECGRP_NAME exists (GroupId: $EXISTING_GROUP_ID), attempting to delete..."
  if aws ec2 delete-security-group \
        --region "$REGION" \
        --group-id "$EXISTING_GROUP_ID"; then
    echo "✔ Deleted existing security group."
  else
    echo "⚠️ Could not delete $SECGRP_NAME because it is in use. Will reuse it."
    SECGRP_ID="$EXISTING_GROUP_ID"
  fi
fi

# Create the security group only if we didn’t reuse it
if [[ -z "$SECGRP_ID" ]]; then
  SECGRP_ID=$(aws ec2 create-security-group \
    --region "$REGION" \
    --group-name "$SECGRP_NAME" \
    --description "Security group for SEV-SNP CVM" \
    --query "GroupId" --output text)
fi

# Add inbound rules to the security group
ALLOW_PORTS="8000"
if [ -n "$ADDITIONAL_PORTS" ]; then
  ALLOW_PORTS="$ALLOW_PORTS,$ADDITIONAL_PORTS"
fi

IFS=',' read -ra PORT_ARRAY <<< "$ALLOW_PORTS"
for P in "${PORT_ARRAY[@]}"; do
  echo "⬅️  Adding ingress rule for TCP $P"
  aws ec2 authorize-security-group-ingress \
       --region "$REGION" \
       --group-id "$SECGRP_ID" \
       --protocol tcp \
       --port "$P" \
       --cidr 0.0.0.0/0 \
       >/dev/null 2>&1 || true # skip “rule exists” errors
  echo "⬅️  Adding ingress rule for UDP $P"
  aws ec2 authorize-security-group-ingress \
       --region "$REGION" \
       --group-id "$SECGRP_ID" \
       --protocol udp \
       --port "$P" \
       --cidr 0.0.0.0/0 \
       >/dev/null 2>&1 || true # skip “rule exists” errors
done


ROOT_MAPPING="DeviceName=/dev/xvda,Ebs={SnapshotId=$SNAPSHOT_ID,DeleteOnTermination=true}"
BLOCK_MAPPINGS="--block-device-mappings $ROOT_MAPPING"

EXIST_VOL_ID=""
CREATE_NEW_DISK=false

if [[ -n "$DATA_DISK" ]]; then
  EXIST_VOL_ID=$(aws ec2 describe-volumes \
    --region "$REGION" \
    --filters Name=tag:Name,Values="$DATA_DISK" \
    --query 'Volumes[0].VolumeId' \
    --output text 2>/dev/null)

  if [[ "$EXIST_VOL_ID" == "None" || -z "$EXIST_VOL_ID" ]]; then
    SIZE="${DISK_SIZE_GB:-10}"
    DATA_MAPPING="DeviceName=/dev/sdf,Ebs={VolumeSize=$SIZE,VolumeType=gp3,DeleteOnTermination=true}"
    BLOCK_MAPPINGS="$BLOCK_MAPPINGS $DATA_MAPPING"
    CREATE_NEW_DISK=true
  fi
fi

FIRST_AZ=$(aws ec2 describe-availability-zones \
  --region "$REGION" \
  --query "AvailabilityZones[0].ZoneName" \
  --output text)

SUBNET_ID=$(aws ec2 describe-subnets \
  --region "$REGION" \
  --query "Subnets[?AvailabilityZone=='$FIRST_AZ'].[SubnetId]" \
  --output text | head -n 1)

if [[ -z "$SUBNET_ID" ]]; then
  echo "❌ No subnet found in $FIRST_AZ. Please ensure at least one subnet exists."
  exit 1
fi

# 1️⃣ Launch instance in stopped state
INSTANCE_ID=$(aws ec2 run-instances \
  --region "$REGION" \
  --subnet-id "$SUBNET_ID" \
  --image-id "$IMAGE_ID" \
  --instance-type "$VM_TYPE" \
  --security-group-ids "$SECGRP_ID" \
  --cpu-options AmdSevSnp=enabled \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$VM_NAME}]" \
  $BLOCK_MAPPINGS \
  --query 'Instances[0].InstanceId' \
  --output text)

# 2️⃣ Wait for instance to exist (but do NOT start it yet)
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_ID"
aws ec2 wait instance-stopped --region "$REGION" --instance-ids "$INSTANCE_ID"

# 3️⃣ Attach existing disk if needed
if [[ -n "$DATA_DISK" && "$CREATE_NEW_DISK" == "false" ]]; then
  echo "📦 Attaching existing disk $EXIST_VOL_ID to $INSTANCE_ID"
  aws ec2 attach-volume \
    --region "$REGION" \
    --volume-id "$EXIST_VOL_ID" \
    --instance-id "$INSTANCE_ID" \
    --device /dev/sdf
  VOL_ID="$EXIST_VOL_ID"
else
  VOL_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='/dev/sdf'].Ebs.VolumeId" \
    --output text)

  [[ -n "$DATA_DISK" ]] && aws ec2 create-tags \
    --region "$REGION" \
    --resources "$VOL_ID" \
    --tags Key=Name,Value="$DATA_DISK"
fi

# 4️⃣ Start the instance only after disk is attached
aws ec2 start-instances --region "$REGION" --instance-ids "$INSTANCE_ID"
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

if [[ -n "$EIP_AID" ]]; then
  echo "Attaching Elastic IP with allocation ID $EIP_AID to instance $INSTANCE_ID"
  aws ec2 associate-address \
    --region "$REGION" \
    --instance-id "$INSTANCE_ID" \
    --allocation-id "$EIP_AID"
fi

PUBLIC_IP=$(aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "VM Public IP: $PUBLIC_IP"

mkdir -p "$ARTIFACT_DIR"
echo "$PUBLIC_IP" > "$ARTIFACT_DIR/aws_${VM_NAME}_ip"
echo "$BUCKET" > "$ARTIFACT_DIR/aws_${VM_NAME}_bucket"
echo "$REGION" > "$ARTIFACT_DIR/aws_${VM_NAME}_region"
echo "$IMAGE_ID" > "$ARTIFACT_DIR/aws_${VM_NAME}_image"
echo "$SECGRP_ID" > "$ARTIFACT_DIR/aws_${VM_NAME}_secgrp"
echo "$INSTANCE_ID" > "$ARTIFACT_DIR/aws_${VM_NAME}_vmid"
[[ -n "$VOL_ID" ]] && echo "$VOL_ID" > "$ARTIFACT_DIR/aws_${VM_NAME}_data_volume"


set +x
set +e
