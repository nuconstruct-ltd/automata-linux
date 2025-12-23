#!/bin/bash

CSP="$1"

# GitHub repository information
REPO="automata-network/cvm-base-image"
RELEASE_TAG="${RELEASE_TAG:-latest}"  # Use RELEASE_TAG env var or default to "latest"

# quit when any error occurs
set -Eeuo pipefail

# Ensure all arguments are provided
if [[ $# -lt 1 ]]; then
  echo "❌ Error: Arguments are missing! (get_disk_image.sh)"
  exit 1
fi

echo "⌛ Checking whether disk image exists..."

# ---------- helpers ----------------------------------------------------------

# Download file from GitHub Release
download_from_github() {
  local filename="$1"

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
      cut -d'"' -f4)

    if [[ -z "$ASSET_URL" ]]; then
      echo "❌ Error: Could not find ${filename} in GitHub release ${RELEASE_TAG}"
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
      cut -d'"' -f4)

    if [[ -z "$DOWNLOAD_URL" ]]; then
      echo "❌ Error: Could not find ${filename} in GitHub release ${RELEASE_TAG}"
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
}

# ---------- per-CSP logic ----------------------------------------------------

if [ "$CSP" = "aws" ]; then
  FILE="aws_disk.vmdk"

  if [[ ! -f "$FILE" ]]; then
    download_from_github "$FILE"
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
  else
    echo "✅ '$FILE' already exists."
  fi

else
  echo "❌ Error: Unsupported CSP '$CSP'. Supported CSPs are: aws, azure, gcp."
  exit 1
fi

set +e
