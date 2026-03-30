#!/bin/bash
# Consolidated disk operations for toolkit disktools container.
# Usage:
#   disk-ops.sh prepare-disk <disk_file> <workload_dir> <csp> <vm_name> [disk_size]
#   disk-ops.sh update-workload <disk_file> <workload_dir> [disk_size]
#   disk-ops.sh generate-token <disk_file> <csp> <vm_name>

set -Eeuo pipefail

COMMAND="${1:-}"
shift || true

# --- CLEANUP ---------------------------------------------------------------
cleanup() {
  for mp in /tmp/data; do
    mountpoint -q "$mp" 2>/dev/null && umount "$mp" || true
  done
  if [[ "${USE_KPARTX:-false}" == "true" && -n "${LOOP_DEV:-}" ]]; then
    kpartx -dv "$LOOP_DEV" 2>/dev/null || true
  fi
  [[ -n "${LOOP_DEV:-}" && -e "${LOOP_DEV:-}" ]] && losetup -d "$LOOP_DEV" || true
}
trap cleanup EXIT
trap 'echo "ERROR: Failure on line $LINENO"; exit 1' ERR
trap 'exit 1' INT HUP TERM

# Number of pigz threads (use all available CPUs)
PIGZ_THREADS=$(nproc 2>/dev/null || echo 4)

# --- HELPERS ----------------------------------------------------------------

# Mount disk and get loop device. Handles vmdk, tar.gz, raw, and vhd formats.
# Sets LOOP_DEV and RAW_FILE variables.
setup_disk() {
    local disk_file="$1"
    RAW_FILE=""
    NEEDS_REPACK=false

    if [[ "$disk_file" == *.vmdk ]]; then
        echo "Converting VMDK to raw..."
        qemu-img convert -p -f vmdk -O raw "$disk_file" /tmp/work.raw
        RAW_FILE="/tmp/work.raw"
        NEEDS_REPACK=true
        REPACK_FORMAT="vmdk"
        REPACK_SOURCE="$disk_file"
    elif [[ "$disk_file" == *.tar.gz ]]; then
        # Check if pre-expanded raw file exists in /cache
        local raw_cache="/cache/disk.raw"
        if [[ -f "$raw_cache" ]]; then
            echo "Using cached raw disk from /cache/disk.raw"
            RAW_FILE="$raw_cache"
        else
            echo "Extracting tar.gz (using pigz)..."
            pigz -dc -p "$PIGZ_THREADS" "$disk_file" | tar -xf - -C /tmp/
            RAW_FILE="/tmp/disk.raw"
        fi
        NEEDS_REPACK=true
        REPACK_FORMAT="tar.gz"
        REPACK_SOURCE="$disk_file"
    else
        RAW_FILE="$disk_file"
    fi

    losetup -fP "$RAW_FILE"
    LOOP_DEV=$(losetup -j "$RAW_FILE" | awk -F: '{print $1}')
    echo "Loop device: $LOOP_DEV"

    # Use kpartx to create proper partition device mappings
    # This is required in Docker containers where losetup -P doesn't create partition nodes
    USE_KPARTX=false
    if [ ! -e "${LOOP_DEV}p3" ]; then
        echo "Partition devices not found, using kpartx..."
        kpartx -av "$LOOP_DEV"
        USE_KPARTX=true
        LOOP_BASE=$(basename "$LOOP_DEV")
        PART_PREFIX="/dev/mapper/${LOOP_BASE}"
    else
        PART_PREFIX="${LOOP_DEV}"
    fi

    lsblk "$LOOP_DEV" 2>/dev/null || true

    # Verify partition 3 exists
    if [ ! -e "${PART_PREFIX}p3" ]; then
        echo "ERROR: Partition 3 not found at ${PART_PREFIX}p3"
        ls -la /dev/mapper/ 2>/dev/null || true
        exit 1
    fi
}

# Repack disk if needed (vmdk or tar.gz)
teardown_disk() {
    sync
    umount /tmp/data 2>/dev/null || true
    if [[ "${USE_KPARTX:-false}" == "true" ]]; then
        kpartx -dv "$LOOP_DEV" 2>/dev/null || true
    fi
    losetup -d "$LOOP_DEV" 2>/dev/null || true
    LOOP_DEV=""

    if [[ "$NEEDS_REPACK" == "true" ]]; then
        if [[ "$REPACK_FORMAT" == "vmdk" ]]; then
            echo "Converting back to VMDK..."
            qemu-img convert -p -f raw "$RAW_FILE" -O vmdk \
                -o subformat=streamOptimized,compat6 "$REPACK_SOURCE"
        elif [[ "$REPACK_FORMAT" == "tar.gz" ]]; then
            echo "Repacking tar.gz (using pigz with $PIGZ_THREADS threads)..."
            tar -cf - -C "$(dirname "$RAW_FILE")" "$(basename "$RAW_FILE")" | \
                pigz -p "$PIGZ_THREADS" > "$REPACK_SOURCE"

            # Save raw to cache if /cache is mounted
            if [[ -d "/cache" && "$RAW_FILE" != "/cache/disk.raw" ]]; then
                echo "Caching expanded raw disk to /cache/disk.raw..."
                mv "$RAW_FILE" /cache/disk.raw
            else
                rm -f "$RAW_FILE"
            fi
        fi
    fi
}

# Expand the raw disk image and grow partition 3 to fill it.
expand_partition() {
    local target_size="${1:-}"

    if [[ -z "$target_size" ]]; then
        echo "No target size specified, skipping disk expansion"
        return 0
    fi

    # Check if already expanded
    local current_size
    current_size=$(stat -c%s "$RAW_FILE" 2>/dev/null || stat -f%z "$RAW_FILE" 2>/dev/null || echo 0)
    local target_bytes
    target_bytes=$(echo "$target_size" | sed 's/G//' | awk '{print $1 * 1073741824}')

    if [[ "$current_size" -ge "$target_bytes" ]]; then
        echo "Disk already at ${target_size} ($(( current_size / 1073741824 ))G), skipping expansion"
        return 0
    fi

    echo "Expanding disk image to ${target_size}..."

    # Detach loop device first
    if [[ "${USE_KPARTX:-false}" == "true" ]]; then
        kpartx -dv "$LOOP_DEV" 2>/dev/null || true
    fi
    losetup -d "$LOOP_DEV" 2>/dev/null || true

    # Expand the raw file
    truncate -s "$target_size" "$RAW_FILE"

    # Re-attach
    losetup -fP "$RAW_FILE"
    LOOP_DEV=$(losetup -j "$RAW_FILE" | awk -F: '{print $1}')

    # Re-create partition mappings
    USE_KPARTX=false
    if [ ! -e "${LOOP_DEV}p3" ]; then
        kpartx -av "$LOOP_DEV" 2>/dev/null
        USE_KPARTX=true
        LOOP_BASE=$(basename "$LOOP_DEV")
        PART_PREFIX="/dev/mapper/${LOOP_BASE}"
    else
        PART_PREFIX="${LOOP_DEV}"
    fi

    # Grow partition 3 to fill remaining space
    echo "Growing partition 3..."
    growpart "$LOOP_DEV" 3 || true

    # Re-read partition table
    if [[ "${USE_KPARTX}" == "true" ]]; then
        kpartx -dv "$LOOP_DEV" 2>/dev/null || true
        kpartx -av "$LOOP_DEV" 2>/dev/null
    fi

    # Resize filesystem
    echo "Resizing filesystem..."
    e2fsck -fy "${PART_PREFIX}p3" 2>/dev/null || true
    resize2fs "${PART_PREFIX}p3"

    echo "Disk expanded to ${target_size}"
    lsblk "$LOOP_DEV" 2>/dev/null || true
}

# --- COMMANDS ---------------------------------------------------------------

cmd_prepare_disk() {
    local disk_file="${1:?Usage: prepare-disk <disk_file> <workload_dir> <csp> <vm_name> [disk_size]}"
    local workload_dir="${2:?Usage: prepare-disk <disk_file> <workload_dir> <csp> <vm_name> [disk_size]}"
    local csp="${3:?Usage: prepare-disk <disk_file> <workload_dir> <csp> <vm_name> [disk_size]}"
    local vm_name="${4:?Usage: prepare-disk <disk_file> <workload_dir> <csp> <vm_name> [disk_size]}"
    local target_size="${5:-}"

    echo "Preparing disk (workload + token in single pass)..." >&2
    setup_disk "$disk_file" >&2

    # Expand partition if needed
    expand_partition "$target_size" >&2

    mkdir -p /tmp/data
    mount "${PART_PREFIX}p3" /tmp/data

    # Copy workload
    echo "Copying workload..." >&2
    rm -rf /tmp/data/workload
    cp -r "$workload_dir" /tmp/data/workload
    chown -R 1000:1000 /tmp/data/workload
    echo "Workload contents:" >&2
    ls -la /tmp/data/workload | sed 's/^/  /' >&2

    # Generate and write token
    local token
    token=$(openssl rand -hex 16)
    local token_hash
    token_hash=$(echo -n "$token" | sha256sum | cut -d ' ' -f1)
    echo -n "$token_hash" > /tmp/data/token_hash
    chown 1000:1000 /tmp/data/token_hash

    umount /tmp/data
    teardown_disk >&2

    # Output token to stdout (captured by toolkit)
    echo "$token"
    echo "Disk prepared successfully" >&2
}

cmd_update_workload() {
    local disk_file="${1:?Usage: update-workload <disk_file> <workload_dir>}"
    local workload_dir="${2:?Usage: update-workload <disk_file> <workload_dir>}"
    local target_size="${3:-}"

    echo "Updating disk with workload..."
    setup_disk "$disk_file"

    expand_partition "$target_size"

    mkdir -p /tmp/data
    mount "${PART_PREFIX}p3" /tmp/data

    echo "Copying workload..."
    rm -rf /tmp/data/workload
    cp -r "$workload_dir" /tmp/data/workload
    chown -R 1000:1000 /tmp/data/workload
    echo "Workload contents:"
    ls -la /tmp/data/workload | sed 's/^/  /'

    umount /tmp/data
    teardown_disk

    echo "Disk updated successfully"
}

cmd_generate_token() {
    local disk_file="${1:?Usage: generate-token <disk_file> <csp> <vm_name>}"
    local csp="${2:?Usage: generate-token <disk_file> <csp> <vm_name>}"
    local vm_name="${3:?Usage: generate-token <disk_file> <csp> <vm_name>}"

    echo "Generating API token..." >&2
    setup_disk "$disk_file" >&2

    mkdir -p /tmp/data
    mount "${PART_PREFIX}p3" /tmp/data

    local token
    token=$(openssl rand -hex 16)
    local token_hash
    token_hash=$(echo -n "$token" | sha256sum | cut -d ' ' -f1)
    echo -n "$token_hash" > /tmp/data/token_hash
    chown 1000:1000 /tmp/data/token_hash

    umount /tmp/data
    teardown_disk >&2

    echo "$token"
    echo "API token generated" >&2
}

# --- DISPATCH ---------------------------------------------------------------

case "$COMMAND" in
    prepare-disk)
        cmd_prepare_disk "$@"
        ;;
    update-workload)
        cmd_update_workload "$@"
        ;;
    generate-token)
        cmd_generate_token "$@"
        ;;
    *)
        echo "Usage: disk-ops.sh <command> [args...]"
        echo ""
        echo "Commands:"
        echo "  prepare-disk <disk_file> <workload_dir> <csp> <vm_name> [size]  Inject workload + generate token (single pass)"
        echo "  update-workload <disk_file> <workload_dir>  Update disk with workload files"
        echo "  generate-token <disk_file> <csp> <vm_name>  Generate API token and embed in disk"
        exit 1
        ;;
esac
