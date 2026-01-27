#!/bin/bash
VM_NAME=$1
ARTIFACT_DIR="${2:-_artifacts}"  # Artifact directory (passed from atakit)

# quit when any error occurs
set -Eeuo pipefail

# Ensure all arguments are provided
if [[ $# -lt 2 ]]; then
    echo "❌ Error: Arguments are missing! (cleanup_aws_vm.sh)"
    exit 1
fi

# Check if artifact files exist
BUCKET_FILE="$ARTIFACT_DIR/aws_${VM_NAME}_bucket"
IMAGE_FILE="$ARTIFACT_DIR/aws_${VM_NAME}_image"
REGION_FILE="$ARTIFACT_DIR/aws_${VM_NAME}_region"
SECGRP_FILE="$ARTIFACT_DIR/aws_${VM_NAME}_secgrp"
VMID_FILE="$ARTIFACT_DIR/aws_${VM_NAME}_vmid"

missing_files=()
[[ ! -f "$BUCKET_FILE" ]] && missing_files+=("$BUCKET_FILE")
[[ ! -f "$IMAGE_FILE" ]] && missing_files+=("$IMAGE_FILE")
[[ ! -f "$REGION_FILE" ]] && missing_files+=("$REGION_FILE")
[[ ! -f "$SECGRP_FILE" ]] && missing_files+=("$SECGRP_FILE")
[[ ! -f "$VMID_FILE" ]] && missing_files+=("$VMID_FILE")

if [[ ${#missing_files[@]} -gt 0 ]]; then
    echo "❌ Error: Missing artifact files for VM '$VM_NAME':"
    for f in "${missing_files[@]}"; do
        echo "   - $f"
    done
    echo ""
    echo "These files are created during deployment. Make sure the VM was deployed with this name."
    exit 1
fi

export AWS_PAGER=""
BUCKET=$(<"$BUCKET_FILE")
AMI_ID=$(<"$IMAGE_FILE")
REGION=$(<"$REGION_FILE")
SECGRP_ID=$(<"$SECGRP_FILE")
INSTANCE_ID=$(<"$VMID_FILE")

# First delete the EC2 instance
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$REGION"
echo "✅ EC2 instance '$INSTANCE_ID' terminated."

# Delete the security group
aws ec2 delete-security-group --group-id "$SECGRP_ID" --region "$REGION"
echo "✅ Security group deleted."

# Get Snapshots associated with the AMI
SNAPSHOTS=$(aws ec2 describe-images --image-ids "$AMI_ID" --region "$REGION" \
  --query 'Images[0].BlockDeviceMappings[*].Ebs.SnapshotId' \
  --output text)
# Delete the AMI
aws ec2 deregister-image --image-id "$AMI_ID" --region "$REGION"
echo "✅ AMI '$AMI_ID' deregistered."
# Delete the snapshots
for SNAP_ID in $SNAPSHOTS; do
  echo "Deleting snapshot $SNAP_ID"
  aws ec2 delete-snapshot --snapshot-id "$SNAP_ID" --region "$REGION"
done

# Delete S3 bucket
aws s3 rb s3://$BUCKET --force

# Remove the artifacts related to this AWS VM
echo "ℹ️  Removing artifacts for AWS VM '$VM_NAME'..."
rm -f "$ARTIFACT_DIR/aws_${VM_NAME}_"*

echo "✅ Cleanup completed for AWS VM '$VM_NAME'."

set +e