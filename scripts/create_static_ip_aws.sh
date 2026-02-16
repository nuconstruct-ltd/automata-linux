#!/bin/bash
# Creates or reuses an AWS Elastic IP. Uses Name tag for idempotency.
# Usage: create_static_ip_aws.sh <IP_NAME> <REGION> <VM_NAME> <ARTIFACT_DIR>

IP_NAME="$1"
REGION="$2"
VM_NAME="$3"
ARTIFACT_DIR="${4:-_artifacts}"

if [[ $# -lt 4 ]]; then
    echo "❌ Error: Arguments are missing! (create_static_ip_aws.sh)"
    exit 1
fi

set -euo pipefail
export AWS_PAGER=""

# Check if an EIP with this Name tag already exists
EXISTING_ALLOC_ID=$(aws ec2 describe-addresses \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=$IP_NAME" \
    --query 'Addresses[0].AllocationId' \
    --output text 2>/dev/null || true)

if [[ "$EXISTING_ALLOC_ID" != "None" && -n "$EXISTING_ALLOC_ID" ]]; then
    EXISTING_IP=$(aws ec2 describe-addresses \
        --region "$REGION" \
        --allocation-ids "$EXISTING_ALLOC_ID" \
        --query 'Addresses[0].PublicIp' \
        --output text)
    echo "♻️  Reusing existing Elastic IP '$IP_NAME': $EXISTING_IP (alloc: $EXISTING_ALLOC_ID)"
    EIP_ALLOC_ID="$EXISTING_ALLOC_ID"
else
    echo "🔧 Creating new Elastic IP '$IP_NAME' in region $REGION..."
    EIP_ALLOC_ID=$(aws ec2 allocate-address \
        --region "$REGION" \
        --domain vpc \
        --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$IP_NAME}]" \
        --query 'AllocationId' \
        --output text)
    EIP_ADDRESS=$(aws ec2 describe-addresses \
        --region "$REGION" \
        --allocation-ids "$EIP_ALLOC_ID" \
        --query 'Addresses[0].PublicIp' \
        --output text)
    echo "✅ Created Elastic IP '$IP_NAME': $EIP_ADDRESS (alloc: $EIP_ALLOC_ID)"
fi

# Save to artifacts (VM_NAME prefix so cleanup glob catches them)
mkdir -p "$ARTIFACT_DIR"
echo "$EIP_ALLOC_ID" > "$ARTIFACT_DIR/aws_${VM_NAME}_eip_alloc_id"
echo "$IP_NAME" > "$ARTIFACT_DIR/aws_${VM_NAME}_eip_name"

# Output the allocation ID for the caller to capture
echo "$EIP_ALLOC_ID"
