#!/bin/bash

CSP="$1"

# GitHub repository information
REPO="automata-network/cvm-base-image"
RELEASE_TAG="${RELEASE_TAG:-}"  # Use RELEASE_TAG env var or auto-detect

# Track whether we downloaded a new disk image
DOWNLOADED_IMAGE=false

# quit when any error occurs
set -Eeuo pipefail

# Ensure all arguments are provided
if [[ $# -lt 1 ]]; then
  echo "❌ Error: Arguments are missing! (get_disk_image.sh)"
  exit 1
fi

echo "⌛ Checking whether disk image exists..."

# ---------- helpers ----------------------------------------------------------

# Find the latest release that contains disk images (not CLI-only releases)
find_latest_image_release() {
  local api_url="https://api.github.com/repos/${REPO}/releases?per_page=20"
  local releases_json

  echo "⌛ Finding latest release with disk images..." >&2

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    releases_json=$(curl -sL -H "Authorization: Bearer ${GITHUB_TOKEN}" "$api_url")
  else
    releases_json=$(curl -sL "$api_url")
  fi

  # Check if we got a valid response
  if [[ -z "$releases_json" ]] || echo "$releases_json" | jq -e 'type != "array"' >/dev/null 2>&1; then
    echo "❌ Error: Failed to fetch releases from GitHub API" >&2
    echo "   Response: $releases_json" >&2
    exit 1
  fi

  # Find the first release that contains a disk image file (gcp_disk.tar.gz, aws_disk.vmdk, or azure_disk.vhd.xz)
  local tag
  tag=$(echo "$releases_json" | jq -r '
    [.[] | select(.assets[]?.name | test("gcp_disk\\.tar\\.gz|aws_disk\\.vmdk|azure_disk\\.vhd\\.xz"))] | first | .tag_name // empty
  ' || true)

  if [[ -z "$tag" || "$tag" == "null" ]]; then
    echo "❌ Error: Could not find any release containing disk images" >&2
    echo "   Please set RELEASE_TAG environment variable to specify a release" >&2
    echo "   Available releases:" >&2
    echo "$releases_json" | jq -r '.[].tag_name' | head -5 | sed 's/^/     /' >&2
    exit 1
  fi

  echo "✅ Found image release: ${tag}" >&2
  echo "$tag"
}

# Download file from GitHub Release
download_from_github() {
  local filename="$1"
  local user_specified_tag="${RELEASE_TAG:-}"

  # Auto-detect release tag if not specified
  if [[ -z "$RELEASE_TAG" ]]; then
    RELEASE_TAG=$(find_latest_image_release)
  fi

  # Determine API endpoint based on release tag
  if [[ "$RELEASE_TAG" == "latest" ]]; then
    API_URL="https://api.github.com/repos/${REPO}/releases/latest"
  else
    API_URL="https://api.github.com/repos/${REPO}/releases/tags/${RELEASE_TAG}"
  fi

  echo "⌛ Fetching release information from GitHub..."

  # Fetch release info and extract asset ID and URL for the specific file
  # Use authentication if GITHUB_TOKEN is set (required for private repos)
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    RELEASE_INFO=$(curl -sL -H "Authorization: Bearer ${GITHUB_TOKEN}" "$API_URL")
  else
    RELEASE_INFO=$(curl -sL "$API_URL")
  fi

  # Check if release fetch failed (API returns error message)
  if echo "$RELEASE_INFO" | grep -q '"message"'; then
    ERROR_MSG=$(echo "$RELEASE_INFO" | grep -o '"message": "[^"]*"' | cut -d'"' -f4)
    echo "⚠️  Warning: Failed to fetch release information from GitHub: $ERROR_MSG"
    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
      echo "   Hint: For private repos, set GITHUB_TOKEN environment variable"
    fi
    echo "   API URL: $API_URL"
    exit 1
  fi

  # For private repos, we need to use the API asset URL, not browser_download_url
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    # Extract the asset URL from the API response
    ASSET_URL=$(echo "$RELEASE_INFO" | \
      grep -B 3 "\"name\": \"${filename}\"" | \
      grep '"url"' | head -1 | \
      cut -d'"' -f4 || true)

    # If user specified a tag but it doesn't have the disk image, fall back to auto-detect
    if [[ -z "$ASSET_URL" && -n "$user_specified_tag" ]]; then
      echo "⚠️  Release ${RELEASE_TAG} does not contain ${filename}, searching for latest image release..."
      RELEASE_TAG=$(find_latest_image_release)
      API_URL="https://api.github.com/repos/${REPO}/releases/tags/${RELEASE_TAG}"
      RELEASE_INFO=$(curl -sL -H "Authorization: Bearer ${GITHUB_TOKEN}" "$API_URL")
      ASSET_URL=$(echo "$RELEASE_INFO" | \
        grep -B 3 "\"name\": \"${filename}\"" | \
        grep '"url"' | head -1 | \
        cut -d'"' -f4 || true)
    fi

    if [[ -z "$ASSET_URL" ]]; then
      echo "❌ Error: Could not find ${filename} in GitHub release ${RELEASE_TAG}"
      echo "   No releases with disk images were found."
      exit 1
    fi

    echo "⌛ Downloading ${filename} from GitHub Release ${RELEASE_TAG}..."
    echo "   Asset URL: ${ASSET_URL}"

    # Download using the API asset URL with Accept: application/octet-stream
    curl -L -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/octet-stream" \
      -o "$filename" \
      "$ASSET_URL"
  else
    # For public repos, use browser_download_url
    DOWNLOAD_URL=$(echo "$RELEASE_INFO" | \
      grep -o "\"browser_download_url\": \"[^\"]*${filename}\"" | \
      cut -d'"' -f4 || true)

    # If user specified a tag but it doesn't have the disk image, fall back to auto-detect
    if [[ -z "$DOWNLOAD_URL" && -n "$user_specified_tag" ]]; then
      echo "⚠️  Release ${RELEASE_TAG} does not contain ${filename}, searching for latest image release..."
      RELEASE_TAG=$(find_latest_image_release)
      API_URL="https://api.github.com/repos/${REPO}/releases/tags/${RELEASE_TAG}"
      RELEASE_INFO=$(curl -sL "$API_URL")
      DOWNLOAD_URL=$(echo "$RELEASE_INFO" | \
        grep -o "\"browser_download_url\": \"[^\"]*${filename}\"" | \
        cut -d'"' -f4 || true)
    fi

    if [[ -z "$DOWNLOAD_URL" ]]; then
      echo "❌ Error: Could not find ${filename} in GitHub release ${RELEASE_TAG}"
      echo "   No releases with disk images were found."
      exit 1
    fi

    echo "⌛ Downloading ${filename} from GitHub Release ${RELEASE_TAG}..."
    echo "   URL: ${DOWNLOAD_URL}"

    curl -L -o "$filename" "$DOWNLOAD_URL"
  fi

  if [[ ! -f "$filename" ]]; then
    echo "❌ Error: Download failed for ${filename}"
    exit 1
  fi

  echo "✅ Downloaded ${filename}"
  echo "   Location: $(pwd)/${filename}"
}

# Download and extract secure boot certificates from GitHub Release
download_secure_boot_certs() {
  local zip_file="secure-boot-certs.zip"
  local target_dir="secure_boot"

  echo "⌛ Downloading secure boot certificates..."

  # Download the zip file
  download_from_github "$zip_file"

  # Create target directory if it doesn't exist
  mkdir -p "$target_dir"

  # Extract certificates (overwrite existing)
  echo "⌛ Extracting secure boot certificates to ${target_dir}/..."
  unzip -o "$zip_file" -d "$target_dir"

  # Clean up zip file
  rm -f "$zip_file"

  echo "✅ Secure boot certificates extracted to ${target_dir}/"
}

# ---------- per-CSP logic ----------------------------------------------------

if [ "$CSP" = "aws" ]; then
  FILE="aws_disk.vmdk"

  if [[ ! -f "$FILE" ]]; then
    download_from_github "$FILE"
    DOWNLOADED_IMAGE=true
  else
    echo "✅ '$FILE' already exists."
  fi

elif [ "$CSP" = "azure" ]; then
  FILE="azure_disk.vhd"
  COMPRESSED_FILE="azure_disk.vhd.xz"

  if [[ ! -f "$FILE" ]]; then
    # Download compressed file
    if [[ ! -f "$COMPRESSED_FILE" ]]; then
      download_from_github "$COMPRESSED_FILE"
      DOWNLOADED_IMAGE=true
    else
      echo "✅ '$COMPRESSED_FILE' already exists."
    fi

    # Decompress (this removes the .xz file and creates .vhd)
    echo "⌛ Decompressing ${COMPRESSED_FILE}..."
    xz -d -v "$COMPRESSED_FILE"
    echo "✅ Decompressed to ${FILE}"
  else
    echo "✅ '$FILE' already exists."
  fi

elif [ "$CSP" = "gcp" ]; then
  FILE="gcp_disk.tar.gz"

  if [[ ! -f "$FILE" ]]; then
    download_from_github "$FILE"
    DOWNLOADED_IMAGE=true
  else
    echo "✅ '$FILE' already exists."
  fi

else
  echo "❌ Error: Unsupported CSP '$CSP'. Supported CSPs are: aws, azure, gcp."
  exit 1
fi

# Download and extract secure boot certificates if we downloaded a new disk image
# OR if the certificates are missing but the zip file exists locally
if [[ "$DOWNLOADED_IMAGE" == "true" ]]; then
  download_secure_boot_certs
elif [ ! -f "secure_boot/PK.crt" ] || [ ! -f "secure_boot/KEK.crt" ] || [ ! -f "secure_boot/db.crt" ] || [ ! -f "secure_boot/kernel.crt" ]; then
  if [ -f "secure-boot-certs.zip" ]; then
    echo "⌛ Secure boot certificates missing but zip file exists. Extracting..."
    mkdir -p "secure_boot"
    unzip -o "secure-boot-certs.zip" -d "secure_boot/"
    echo "✅ Secure boot certificates extracted to secure_boot/"
  else
    echo "⚠️  Warning: Secure boot certificates not found. Downloading from GitHub..."
    download_secure_boot_certs
  fi
fi

set +e
