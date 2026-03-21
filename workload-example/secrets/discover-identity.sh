#!/bin/sh
# CVM identity discovery.
# - Containers on host network: query cloud metadata at 169.254.169.254
# - Containers on bridge network: read /data/data-disk/identity.env (written by a host-network container)

VM_NAME="$(hostname)"
CSP="unknown"
PUBLIC_IP="unknown"
REGION="unknown"

# Try toolkit-generated identity file (mounted from secrets/)
if [ -f /etc/identity.env ]; then
  . /etc/identity.env
# Or shared identity file on data disk (written by a host-network container)
elif [ -f /data/data-disk/identity.env ]; then
  . /data/data-disk/identity.env
fi

# If identity not resolved, try cloud metadata (only works on host network)
if [ "$CSP" = "unknown" ]; then
  # GCP
  gcp_name=$(curl -sf -m 2 -H "Metadata-Flavor: Google" \
    "http://169.254.169.254/computeMetadata/v1/instance/name" 2>/dev/null)
  if [ -n "$gcp_name" ]; then
    CSP="gcp"
    VM_NAME="$gcp_name"
    PUBLIC_IP=$(curl -sf -m 2 -H "Metadata-Flavor: Google" \
      "http://169.254.169.254/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" 2>/dev/null || echo "unknown")
    REGION=$(curl -sf -m 2 -H "Metadata-Flavor: Google" \
      "http://169.254.169.254/computeMetadata/v1/instance/zone" 2>/dev/null | sed 's|.*/||' || echo "unknown")
  fi

  # AWS IMDSv2
  if [ "$CSP" = "unknown" ]; then
    aws_token=$(curl -sf -m 2 -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
      "http://169.254.169.254/latest/api/token" 2>/dev/null)
    if [ -n "$aws_token" ]; then
      CSP="aws"
      VM_NAME=$(curl -sf -m 2 -H "X-aws-ec2-metadata-token: $aws_token" \
        "http://169.254.169.254/latest/meta-data/tags/instance/Name" 2>/dev/null || echo "$VM_NAME")
      PUBLIC_IP=$(curl -sf -m 2 -H "X-aws-ec2-metadata-token: $aws_token" \
        "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null || echo "unknown")
      REGION=$(curl -sf -m 2 -H "X-aws-ec2-metadata-token: $aws_token" \
        "http://169.254.169.254/latest/meta-data/placement/availability-zone" 2>/dev/null || echo "unknown")
    fi
  fi

  # Azure IMDS
  if [ "$CSP" = "unknown" ]; then
    azure_name=$(curl -sf -m 2 -H "Metadata: true" \
      "http://169.254.169.254/metadata/instance/compute/name?api-version=2021-02-01&format=text" 2>/dev/null)
    if [ -n "$azure_name" ]; then
      CSP="azure"
      VM_NAME="$azure_name"
      PUBLIC_IP=$(curl -sf -m 2 -H "Metadata: true" \
        "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text" 2>/dev/null || echo "unknown")
      REGION=$(curl -sf -m 2 -H "Metadata: true" \
        "http://169.254.169.254/metadata/instance/compute/location?api-version=2021-02-01&format=text" 2>/dev/null || echo "unknown")
    fi
  fi

  # If we discovered identity, write it for other containers
  if [ "$CSP" != "unknown" ]; then
    cat > /data/data-disk/identity.env 2>/dev/null <<EOF
VM_NAME=$VM_NAME
CSP=$CSP
PUBLIC_IP=$PUBLIC_IP
REGION=$REGION
EOF
  fi
fi

export VM_NAME CSP PUBLIC_IP REGION
echo "INFO: CVM identity: vm_name=$VM_NAME csp=$CSP ip=$PUBLIC_IP region=$REGION" >&2
