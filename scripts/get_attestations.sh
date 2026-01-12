#!/bin/bash

# GitHub repository information
REPO="automata-network/cvm-base-image"
RELEASE_TAG="${RELEASE_TAG:-}"  # Use RELEASE_TAG env var or auto-detect

# quit when any error occurs
set -Eeuo pipefail

echo "⌛ Downloading attestations from GitHub Release..."

# ---------- helpers ----------------------------------------------------------

# Find the latest release that contains attestations (not CLI-only releases)
find_latest_attestation_release() {
  local api_url="https://api.github.com/repos/${REPO}/releases?per_page=20"
  local releases_json

  echo "⌛ Finding latest release with attestations..." >&2

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    releases_json=$(curl -sL --max-time 30 -H "Authorization: Bearer ${GITHUB_TOKEN}" "$api_url")
  else
    releases_json=$(curl -sL --max-time 30 "$api_url")
  fi

  # Check if we got a valid response
  if [[ -z "$releases_json" ]] || echo "$releases_json" | jq -e 'type != "array"' >/dev/null 2>&1; then
    echo "❌ Error: Failed to fetch releases from GitHub API" >&2
    echo "   Response: $releases_json" >&2
    exit 1
  fi

  # Find the first release that contains attestations.zip
  local tag
  tag=$(echo "$releases_json" | jq -r '
    [.[] | select(.assets[]?.name == "attestations.zip")] | first | .tag_name // empty
  ' || true)

  if [[ -z "$tag" || "$tag" == "null" ]]; then
    echo "❌ Error: Could not find any release containing attestations" >&2
    echo "   Please set RELEASE_TAG environment variable to specify a release" >&2
    echo "   Available releases:" >&2
    echo "$releases_json" | jq -r '.[].tag_name' | head -5 | sed 's/^/     /' >&2
    exit 1
  fi

  echo "✅ Found attestation release: ${tag}" >&2
  echo "$tag"
}

# Download file from GitHub Release
download_from_github() {
  local filename="$1"
  local user_specified_tag="${RELEASE_TAG:-}"

  # Auto-detect release tag if not specified
  if [[ -z "$RELEASE_TAG" ]]; then
    RELEASE_TAG=$(find_latest_attestation_release)
  fi

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
      cut -d'"' -f4 || true)

    # If user specified a tag but it doesn't have the attestations, fall back to auto-detect
    if [[ -z "$ASSET_URL" && -n "$user_specified_tag" ]]; then
      echo "⚠️  Release ${RELEASE_TAG} does not contain ${filename}, searching for latest attestation release..."
      RELEASE_TAG=$(find_latest_attestation_release)
      API_URL="https://api.github.com/repos/${REPO}/releases/tags/${RELEASE_TAG}"
      RELEASE_INFO=$(curl -sL --max-time 30 -H "Authorization: Bearer ${GITHUB_TOKEN}" "$API_URL")
      ASSET_URL=$(echo "$RELEASE_INFO" | \
        grep -B 3 "\"name\": \"${filename}\"" | \
        grep '"url"' | head -1 | \
        cut -d'"' -f4 || true)
    fi

    if [[ -z "$ASSET_URL" ]]; then
      echo "❌ Error: Could not find ${filename} in GitHub release ${RELEASE_TAG}"
      echo "❌ No releases with attestations were found."
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

    # If user specified a tag but it doesn't have the attestations, fall back to auto-detect
    if [[ -z "$DOWNLOAD_URL" && -n "$user_specified_tag" ]]; then
      echo "⚠️  Release ${RELEASE_TAG} does not contain ${filename}, searching for latest attestation release..."
      RELEASE_TAG=$(find_latest_attestation_release)
      API_URL="https://api.github.com/repos/${REPO}/releases/tags/${RELEASE_TAG}"
      RELEASE_INFO=$(curl -sL --max-time 30 "$API_URL")
      DOWNLOAD_URL=$(echo "$RELEASE_INFO" | \
        grep -o "\"browser_download_url\": \"[^\"]*${filename}\"" | \
        cut -d'"' -f4 || true)
    fi

    if [[ -z "$DOWNLOAD_URL" ]]; then
      echo "❌ Error: Could not find ${filename} in GitHub release ${RELEASE_TAG}"
      echo "❌ No releases with attestations were found."
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
