#!/bin/bash

CSP="$1"

# DDMMYYYY format for the disk image date
<<<<<<< Updated upstream
DATE=05092025
=======
DATE=21112025
>>>>>>> Stashed changes

# quit when any error occurs
set -Eeuo pipefail

# Ensure all arguments are provided
if [[ $# -lt 1 ]]; then
  echo "❌ Error: Arguments are missing! (get_disk_image.sh)"
  exit 1
fi

echo "⌛ Checking whether disk image exists..."

# ---------- helpers (portable across GNU/Linux and macOS) --------------------

# Convert YYYY-MM-DD to epoch seconds (tries GNU date, then BSD/macOS date)
to_epoch() {
  local y="$1" m="$2" d="$3"
  if date -d '1970-01-01' +%s >/dev/null 2>&1; then
    date -d "${y}-${m}-${d} 00:00:00" +%s
  else
    date -j -f "%Y-%m-%d %H:%M:%S" "${y}-${m}-${d} 00:00:00" +%s
  fi
}

# Get file mtime in epoch seconds (GNU stat vs BSD/macOS stat)
mtime_epoch() {
  local f="$1"
  if stat --version >/dev/null 2>&1; then
    stat -c %Y -- "$f"
  else
    stat -f %m -- "$f"
  fi
}

# Parse DDMMYYYY from $DATE and compute epoch once
get_gen_epoch() {
  local code="$1"
  [[ "$code" =~ ^[0-9]{8}$ ]] || {
    echo "❌ DATE must be 8 digits in DDMMYYYY (got: '$code')" >&2
    exit 1
  }
  local dd="${code:0:2}"
  local mm="${code:2:2}"
  local yy="${code:4:4}"
  to_epoch "$yy" "$mm" "$dd"
}

# Delete file if it exists and is older than generation date
delete_if_outdated() {
  local file="$1" gen_epoch="$2"
  if [[ -f "$file" ]]; then
    local local_epoch
    local_epoch="$(mtime_epoch "$file")"
    if (( local_epoch < gen_epoch )); then
      echo "🧹 '$file' is older than ${DATE} (DDMMYYYY); deleting..."
      rm -f -- "$file"
    else
      echo "✅ '$file' is up to date."
    fi
  fi
}

GEN_EPOCH="$(get_gen_epoch "$DATE")"
# ---------- per-CSP logic ----------------------------------------------------

# 2. Download the disk image if does not exist or is outdated
if [ "$CSP" = "aws" ]; then
  FILE="aws_disk.vmdk"
  delete_if_outdated "$FILE" "$GEN_EPOCH"
  if [[ ! -f "$FILE" ]]; then
    echo "⌛ Downloading $FILE..."
    curl -O https://f004.backblazeb2.com/file/cvm-base-images/$DATE/$FILE
  fi
elif [ "$CSP" = "azure" ]; then
  FILE="azure_disk.vhd"
  delete_if_outdated "$FILE" "$GEN_EPOCH"
  if [[ ! -f "$FILE" ]]; then
    echo "⌛ Downloading $FILE..."
    curl -O https://f004.backblazeb2.com/file/cvm-base-images/$DATE/$FILE
  fi
elif [ "$CSP" = "gcp" ]; then
  FILE="gcp_disk.tar.gz"
  delete_if_outdated "$FILE" "$GEN_EPOCH"
  if [[ ! -f "$FILE" ]]; then
    echo "⌛ Downloading $FILE..."
    curl -O https://f004.backblazeb2.com/file/cvm-base-images/$DATE/$FILE
  fi
else
    echo "❌ Error: Unsupported CSP '$CSP'. Supported CSPs are: aws, azure, gcp."
    exit 1
fi

set +e
