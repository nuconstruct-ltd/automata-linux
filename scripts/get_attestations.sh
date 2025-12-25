#!/bin/bash

# GitHub repository information
REPO="automata-network/cvm-base-image"
RELEASE_TAG="${RELEASE_TAG:-latest}"  # Use RELEASE_TAG env var or default to "latest"

# quit when any error occurs
set -Eeuo pipefail

echo "⌛ Downloading attestations from GitHub Release..."

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
  echo "   API URL: ${API_URL}"

  # Fetch release info and extract asset ID and URL for the specific file
  # Use authentication if GITHUB_TOKEN is set (required for private repos)
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    RELEASE_INFO=$(curl -sL --max-time 30 -H "Authorization: Bearer ${GITHUB_TOKEN}" "$API_URL")
  else
    RELEASE_INFO=$(curl -sL --max-time 30 "$API_URL")
  fi

  # Check if we got a valid response
  if [[ -z "$RELEASE_INFO" ]]; then
    echo "❌ Error: Failed to fetch release information from GitHub"
    exit 1
  fi

  # Check for API errors
  if echo "$RELEASE_INFO" | grep -q '"message".*"Not Found"'; then
    echo "❌ Error: Release '${RELEASE_TAG}' not found in repository ${REPO}"
    echo "❌ Please check that:"
    echo "   1. The release tag '${RELEASE_TAG}' exists"
    echo "   2. You have access to the repository (set GITHUB_TOKEN for private repos)"
    echo "   3. The repository name is correct: ${REPO}"
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
      echo "❌ This release may not include attestations."
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
      echo "❌ This release may not include attestations."
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

# ---------- main logic -------------------------------------------------------

FILE="attestations.zip"

# Download attestations bundle
if [[ ! -f "$FILE" ]]; then
  download_from_github "$FILE"
else
  echo "✅ '$FILE' already exists. Remove it to re-download."
  exit 0
fi

# Extract attestations
echo "⌛ Extracting attestations..."
unzip -o "$FILE"

if [[ -d "attestations" ]] || [[ -f "aws_disk.vmdk.bundle" ]]; then
  echo "✅ Attestations extracted successfully!"
  echo ""
  echo "📋 Available attestation files:"
  ls -lh *.bundle 2>/dev/null || ls -lh attestations/*.bundle 2>/dev/null || true
  echo ""
  echo "🔐 To verify an attestation:"
  echo "   ./cvm-cli verify-attestation aws_disk.vmdk"
  echo ""
  echo "📖 For detailed documentation, see:"
  echo "   docs/ATTESTATION_VERIFICATION.md"
else
  echo "⚠️  Warning: Attestation files not found after extraction."
  exit 1
fi

set +e
