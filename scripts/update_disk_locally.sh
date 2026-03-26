#!/bin/bash

DISK_FILE=$1

# quit when any error occurs
set -Eeuo pipefail

# Ensure all arguments are provided
if [[ $# -lt 1 ]]; then
    echo "❌ Error: Arguments are missing! (update_disk_locally.sh)"
    exit 1
fi

# --- CLEANUP ---------------------------------------------------------------
cleanup() {
  for mp in /tmp/data; do
    mountpoint -q "$mp" && sudo umount "$mp" || true
  done
  [[ -n "${LOOP_DEV:-}" && -e "$LOOP_DEV" ]] && sudo losetup -d "$LOOP_DEV" || true
}
trap cleanup EXIT
trap 'echo "❌  Failure on line $LINENO"; exit 1' ERR
trap 'exit 1' INT HUP TERM
# --------------------------------------------------------------------------

populate() {
    local DISK="$1"
    local WORKLOAD_FOLDER="${WORKLOAD_DIR:-}"
    local RESIZE_ONLY=false

    # Determine mode: resize-only if no workload dir specified
    if [ -z "$WORKLOAD_FOLDER" ] || [ ! -d "$WORKLOAD_FOLDER" ]; then
        RESIZE_ONLY=true
        if [ -z "${DISK_SIZE:-}" ]; then
            echo "❌ No workload directory and no --disk-size specified. Nothing to do."
            exit 1
        fi
    fi

    # Mount the disk onto a loop device
    LOOP_DEV=$(sudo losetup -fP --show "$DISK")
    lsblk $LOOP_DEV

    # Check that disk has the right partitioning
    PART_COUNT=$(lsblk -l $LOOP_DEV | grep -E "^\s*$(basename "$LOOP_DEV")p[0-9]+" | wc -l)
    if [ "$PART_COUNT" -eq 3 ]; then
        echo "⌛ Mounting disk partition..."
        mkdir -p /tmp/data
        sudo mount ${LOOP_DEV}p3 /tmp/data

        # --- Expand to target DISK_SIZE if specified ---
        if [ -n "${DISK_SIZE:-}" ]; then
            # Parse size: accept formats like 8G, 8GB, 8192M, 8192MB
            TARGET_MB=$(echo "$DISK_SIZE" | awk '{
                s = toupper($0);
                if (match(s, /^([0-9]+)\s*GB?$/, a)) print a[1] * 1024;
                else if (match(s, /^([0-9]+)\s*MB?$/, a)) print a[1];
                else print 0;
            }')
            if [ "$TARGET_MB" -eq 0 ]; then
                echo "❌ Invalid --disk-size format: $DISK_SIZE (use e.g. 8G, 8GB, 8192M)"
                exit 1
            fi
            CURRENT_MB=$(( $(stat -c%s "$DISK") / 1024 / 1024 ))
            if [ "$TARGET_MB" -gt "$CURRENT_MB" ]; then
                GROW_BY=$(( TARGET_MB - CURRENT_MB ))
                echo "📏 Expanding disk from ${CURRENT_MB}MB to ${TARGET_MB}MB (+${GROW_BY}MB)..."

                sudo umount ${LOOP_DEV}p3
                sudo losetup -d $LOOP_DEV

                truncate -s ${TARGET_MB}M "$DISK"

                LOOP_DEV=$(sudo losetup -fP --show "$DISK")

                sudo growpart "$LOOP_DEV" 3
                sudo e2fsck -f -y "${LOOP_DEV}p3" || [ $? -le 1 ]
                sudo resize2fs "${LOOP_DEV}p3"

                sudo mount "${LOOP_DEV}p3" /tmp/data
                echo "✅ Disk expanded to ${TARGET_MB}MB."
            else
                echo "📏 Disk already ${CURRENT_MB}MB >= target ${TARGET_MB}MB, no expansion needed."
            fi
        fi

        # --- Resize-only mode: skip workload operations ---
        if [ "$RESIZE_ONLY" = true ]; then
            sync
            sudo umount ${LOOP_DEV}p3
            echo "✅ Disk resize complete!"
            return
        fi

        # --- Auto-expand p3 if workload won't fit (only when --disk-size not specified) ---
        if [ -z "${DISK_SIZE:-}" ]; then
        WORKLOAD_SIZE_MB=$(du -sm "$WORKLOAD_FOLDER" | awk '{print $1}')
        FREE_MB=$(df -BM --output=avail ${LOOP_DEV}p3 | tail -1 | tr -d ' M')
        if [ -d /tmp/data/workload ]; then
            OLD_WORKLOAD_MB=$(sudo du -sm /tmp/data/workload | awk '{print $1}')
        else
            OLD_WORKLOAD_MB=0
        fi
        EFFECTIVE_AVAIL=$((FREE_MB + OLD_WORKLOAD_MB))

        if [ "$WORKLOAD_SIZE_MB" -gt "$EFFECTIVE_AVAIL" ]; then
            SHORTFALL=$((WORKLOAD_SIZE_MB - EFFECTIVE_AVAIL))
            # Add 20% margin, 1MB aligned
            EXTRA=$(( (SHORTFALL * 120 / 100) + 1 ))
            echo "⚠️  Workload (${WORKLOAD_SIZE_MB}MB) exceeds available space (${EFFECTIVE_AVAIL}MB). Expanding disk by ${EXTRA}MB..."

            sudo umount ${LOOP_DEV}p3
            sudo losetup -d $LOOP_DEV

            truncate -s +${EXTRA}M "$DISK"

            LOOP_DEV=$(sudo losetup -fP --show "$DISK")

            # Grow partition 3 to fill the expanded disk
            sudo growpart "$LOOP_DEV" 3
            # e2fsck returns 1 when it fixes errors (expected after resize) — allow it
            sudo e2fsck -f -y "${LOOP_DEV}p3" || [ $? -le 1 ]
            sudo resize2fs "${LOOP_DEV}p3"

            sudo mount "${LOOP_DEV}p3" /tmp/data
            echo "✅ Disk expanded successfully."
        fi
        fi # end DISK_SIZE guard
        # --- End auto-expand ---

        # Pre-flight check: verify workload will fit before copying
        WORKLOAD_CHECK_MB=$(du -sm "$WORKLOAD_FOLDER" | awk '{print $1}')
        FREE_CHECK_MB=$(df -BM --output=avail ${LOOP_DEV}p3 | tail -1 | tr -d ' M')
        if [ -d /tmp/data/workload ]; then
            OLD_CHECK_MB=$(sudo du -sm /tmp/data/workload | awk '{print $1}')
        else
            OLD_CHECK_MB=0
        fi
        EFFECTIVE_CHECK=$((FREE_CHECK_MB + OLD_CHECK_MB))
        if [ "$WORKLOAD_CHECK_MB" -gt "$EFFECTIVE_CHECK" ]; then
            echo "❌ Workload (${WORKLOAD_CHECK_MB}MB) exceeds available p3 space (${EFFECTIVE_CHECK}MB)."
            echo "   Note: p1+p2 use ~1GB. Use a larger --disk-size (e.g. $((WORKLOAD_CHECK_MB / 1024 + 2))G)."
            exit 1
        fi

        # Remove existing workload and copy new one (avoids nested workload/workload issue)
        echo "⌛ Copying workload to disk..."
        echo "   Source: $WORKLOAD_FOLDER"
        echo "   Target: /data/workload (on disk)"
        sudo rm -rf /tmp/data/workload
        sudo cp -r "$WORKLOAD_FOLDER" /tmp/data/workload
        sudo chown -R 1000:1000 /tmp/data/workload

        # Show what was copied
        echo "📋 Workload contents:"
        ls -la /tmp/data/workload | sed 's/^/   /'

        sync
        sudo umount ${LOOP_DEV}p3

        echo "✅ Workload copied successfully!"
    else
        echo "❌ Disk does not have the right partitioning scheme!"
    fi
}

if [ -f $DISK_FILE ]; then
    if [[ "$DISK_FILE" == *.vmdk ]]; then
        # Check if qemu-img is installed, otherwise install it.
        if ! command -v qemu-img &> /dev/null; then
            echo "qemu-img not found. Installing..."
            # Detect package manager and install
            if [ -x "$(command -v apt)" ]; then
                sudo apt update && sudo apt install -y qemu-utils
            elif [ -x "$(command -v pacman)" ]; then
                sudo pacman -Sy --noconfirm qemu
            else
                echo "Unsupported package manager. Please install qemu-img manually."
                exit 1
            fi
        fi
        qemu-img convert -p -f vmdk -O raw $DISK_FILE tmp.raw
        populate tmp.raw
        qemu-img convert -p -f raw tmp.raw -O vmdk -o subformat=streamOptimized,compat6 aws_disk.vmdk
        rm tmp.raw
    elif [[ "$DISK_FILE" == *.tar.gz ]]; then
        # unzip the disk and zip it back again later
        tar -xzvf "$DISK_FILE"
        populate disk.raw
        rm -f "$DISK_FILE"
        tar -czvf "$DISK_FILE" disk.raw
        rm disk.raw
    else
        # raw disk and VHD.
        populate $DISK_FILE
    fi
else
    echo "❌ Error: $DISK_FILE does not exist!"
fi

set +e
