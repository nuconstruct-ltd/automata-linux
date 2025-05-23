VM_NAME=$1
REGION="$2"
RG="$3"
VM_TYPE="$4"
ADDITIONAL_PORTS="$5"
STORAGE_ACC="$6"
VHD=disk.vhd
GALLERY_NAME="snpGallery"
IMAGE_DEF="${VM_NAME}-def"
SKU_NAME="${VM_NAME}-sku"
GALLERY_IMAGE_VERSION="1.0.0"
PUBLISHER="automata"
STORAGE_CONTAINER="storage"
blob_url="https://${STORAGE_ACC}.blob.core.windows.net/$STORAGE_CONTAINER/$VHD"

# Ensure all arguments are provided
if [[ $# -lt 6 ]]; then
    echo "❌ Error: Arguments are missing!"
    exit 1
fi

set -x
set -e

# Create resource group
echo "ℹ️  Creating resource group..."
az group create --name "$RG" --location "$REGION"

echo "ℹ️  Creating storage account and uploading disk..."
# first create a storage account
az storage account create --resource-group $RG --name ${STORAGE_ACC} --location "$REGION" --sku "Standard_LRS"

# create a container in the storage account
az storage container create --name $STORAGE_CONTAINER --account-name $STORAGE_ACC --resource-group $RG

#get account key so we can upload vhd to container
ACCOUNT_KEY=$(az storage account keys list \
  --resource-group $RG \
  --account-name $STORAGE_ACC \
  --query '[0].value' -o tsv)
# upload custom image to the container as blob
az storage blob upload \
  --account-name $STORAGE_ACC \
  --account-key $ACCOUNT_KEY \
  --container-name $STORAGE_CONTAINER \
  --name $VHD \
  --file $VHD \
  --type page \
  --overwrite

# create shared image gallery
az sig create --resource-group $RG --gallery-name $GALLERY_NAME

# create a cvm definition
az sig image-definition create --resource-group $RG --location "$REGION" --gallery-name $GALLERY_NAME --gallery-image-definition $IMAGE_DEF --publisher $PUBLISHER --offer ubuntu --sku $SKU_NAME --os-type Linux --os-state specialized --hyper-v-generation V2 --features SecurityType=ConfidentialVMSupported

# get storage acc id
storageAccountId=$(az storage account show --name $STORAGE_ACC --resource-group $RG | jq -r .id)

# create sig image version
az sig image-version create --resource-group $RG --gallery-name $GALLERY_NAME --gallery-image-definition $IMAGE_DEF --gallery-image-version $GALLERY_IMAGE_VERSION --os-vhd-storage-account $storageAccountId --os-vhd-uri $blob_url

# get id of sig image version
galleryImageId=$(az sig image-version show --gallery-image-definition $IMAGE_DEF --gallery-image-version $GALLERY_IMAGE_VERSION --gallery-name $GALLERY_NAME --resource-group $RG | jq -r .id)

# Create NSG with base rules
echo "ℹ️  Creating network security group..."
az network nsg create --name "${VM_NAME}" --resource-group "${RG}" --location "${REGION}"

# Add attestation_agent ports
az network nsg rule create --nsg-name "${VM_NAME}" --resource-group "${RG}" \
    --name "attestation_agent" --priority 100 \
    --destination-port-ranges 8000 --access Allow --protocol Tcp

# Add additional port rules if specified
if [[ -n "${ADDITIONAL_PORTS}" ]]; then
    IFS=',' read -ra PORTS <<< "${ADDITIONAL_PORTS}"
    priority=200
    for port in "${PORTS[@]}"; do
        az network nsg rule create --nsg-name "${VM_NAME}" --resource-group "${RG}" \
            --name "Workload_${port}" --priority ${priority} \
            --destination-port-ranges "$port" --access Allow --protocol Tcp
        ((priority+=1))
    done
fi

az vm create \
  --resource-group $RG \
  --name $VM_NAME \
  --size ${VM_TYPE} \
  --enable-vtpm true \
  --enable-secure-boot false \
  --image $galleryImageId \
  --public-ip-sku Standard \
  --nsg "${VM_NAME}" \
  --security-type ConfidentialVM \
  --os-disk-security-encryption-type VMGuestStateOnly \
  --specialized

set +x
set +e
