VM_NAME="$1"
REGION="$2"
RESOURCE_GROUP="$3"
VM_TYPE="$4"
ADDITIONAL_PORTS="$5"
DISK=disk.vhd

# Ensure all arguments are provided
if [[ $# -lt 5 ]]; then
    echo "❌ Error: Arguments are missing!"
    exit 1
fi

set -x
set -e

# Create resource group
echo "ℹ️  Creating resource group..."
az group create --name "$RESOURCE_GROUP" --location "$REGION"

# Create and upload disk
echo "ℹ️  Creating and uploading disk..."
disk_size=$(wc -c < "${DISK}")
az disk create -n "${VM_NAME}" -g "${RESOURCE_GROUP}" -l "${REGION}" \
    --os-type Linux \
    --upload-type Upload \
    --upload-size-bytes "$disk_size" \
    --sku standard_lrs \
    --security-type ConfidentialVM_NonPersistedTPM \
    --hyper-v-generation V2

sleep 5
# Upload VHD
sas_json=$(az disk grant-access -n "${VM_NAME}" -g "${RESOURCE_GROUP}" --access-level Write --duration-in-seconds 86400)
sas_uri=$(echo "$sas_json" | jq -r '.accessSAS')
azcopy copy "${DISK}" "$sas_uri" --blob-type PageBlob --from-to LocalBlob
az disk revoke-access -n "${VM_NAME}" -g "${RESOURCE_GROUP}"

# Create NSG with base rules
echo "ℹ️  Creating network security group..."
az network nsg create --name "${VM_NAME}" --resource-group "${RESOURCE_GROUP}" --location "${REGION}"

# Add attestation_agent ports
az network nsg rule create --nsg-name "${VM_NAME}" --resource-group "${RESOURCE_GROUP}" \
    --name "attestation_agent" --priority 100 \
    --destination-port-ranges 8000 --access Allow --protocol Tcp

# Add additional port rules if specified
if [[ -n "${ADDITIONAL_PORTS}" ]]; then
    IFS=',' read -ra PORTS <<< "${ADDITIONAL_PORTS}"
    priority=200
    for port in "${PORTS[@]}"; do
        az network nsg rule create --nsg-name "${VM_NAME}" --resource-group "${RESOURCE_GROUP}" \
            --name "Workload_${port}" --priority ${priority} \
            --destination-port-ranges "$port" --access Allow --protocol Tcp
        ((priority+=1))
    done
fi

# Create VM
echo "ℹ️  Creating VM..."
az vm create --name ${VM_NAME} \
    --resource-group ${RESOURCE_GROUP} \
    --location "${REGION}" \
    --size ${VM_TYPE} \
    --attach-os-disk "${VM_NAME}" \
    --os-type Linux \
    --nsg "${VM_NAME}" \
    --nic-delete-option Delete \
    --public-ip-sku Standard \
    --security-type ConfidentialVM \
    --enable-vtpm true \
    --enable-secure-boot false \
    --os-disk-security-encryption-type NonPersistedTPM

set +x
set +e
