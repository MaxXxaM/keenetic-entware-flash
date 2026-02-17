#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Keenetic Entware Flash — USB flash drive preparation for Keenetic Entware
# ============================================================================

TARGET="/dev/target"
MOUNT_POINT="/mnt/usb"
LOOP_DEVICE=""
CLEANUP_LOOP=0
KPARTX_DEVICE=""

# Defaults (overridable via env)
ARCH="${ARCH:-mipsel}"
SWAP_SIZE="${SWAP_SIZE:-1024}"
PARTITION_TABLE="${PARTITION_TABLE:-mbr}"
SKIP_ENTWARE="${SKIP_ENTWARE:-0}"
FORCE="${FORCE:-0}"

# ============================================================================
# Architecture mapping
# ============================================================================
# MIPSEL: Keenetic Ultra, Giga, Viva, Extra, Air, City, Omni, Lite, Start
#         KN-1010, KN-1110, KN-1210, KN-1310, KN-1410, KN-1510, KN-1610,
#         KN-1710, KN-1810, KN-1910, KN-2110, KN-2310
# MIPS:   KN-2410, KN-2510, KN-2010, KN-3610
# AARCH64: Keenetic Peak, Titan, Hopper, KN-2710, KN-2810, KN-2910, KN-3510

arch_to_path() {
    case "$1" in
        mipsel)  echo "mipselsf-k3.4" ;;
        mips)    echo "mipssf-k3.4" ;;
        aarch64) echo "aarch64-k3.10" ;;
        *)
            echo "ERROR: Unknown architecture '$1'"
            echo "Supported: mipsel, mips, aarch64"
            exit 1
            ;;
    esac
}

# ============================================================================
# Help
# ============================================================================
show_help() {
    cat <<'HELP'
Keenetic Entware Flash — USB flash drive preparation for Keenetic Entware

Usage (Linux):
  docker run --rm -it --privileged \
    -v /dev/sdX:/dev/target \
    keenetic-entware-flash

Usage (macOS):
  # 1. Create disk image from USB
  sudo dd if=/dev/rdiskN of=/tmp/usb.img bs=1m
  # 2. Process in container
  docker run --rm -it --privileged \
    -v /tmp/usb.img:/dev/target \
    keenetic-entware-flash
  # 3. Write image back to USB
  sudo dd if=/tmp/usb.img of=/dev/rdiskN bs=1m

Environment variables:
  ARCH              Entware architecture: mipsel (default), mips, aarch64
  SWAP_SIZE         Swap partition size in MB (default: 1024)
  PARTITION_TABLE   Partition table type: mbr (default) or gpt
  SKIP_ENTWARE      Skip Entware download: 0 (default) or 1
  FORCE             Skip confirmation prompt: 0 (default) or 1

Model → Architecture mapping:
  MIPSEL   Keenetic Ultra, Giga, Viva, Extra, Air, City, Omni, Lite, Start
  MIPS     KN-2410, KN-2510, KN-2010, KN-3610
  AARCH64  Keenetic Peak, Titan, Hopper

Examples:
  # Linux — direct block device
  docker run --rm -it --privileged -v /dev/sdb:/dev/target keenetic-entware-flash

  # macOS — via disk image
  docker run --rm -it --privileged -v /tmp/usb.img:/dev/target keenetic-entware-flash

  # AArch64 with GPT and 512MB swap
  docker run --rm -it --privileged \
    -e ARCH=aarch64 -e SWAP_SIZE=512 -e PARTITION_TABLE=gpt \
    -v /dev/sdb:/dev/target keenetic-entware-flash
HELP
    exit 0
}

# ============================================================================
# Cleanup on exit
# ============================================================================
cleanup() {
    umount "$MOUNT_POINT" 2>/dev/null || true
    if [ -n "$KPARTX_DEVICE" ]; then
        kpartx -dv "$KPARTX_DEVICE" 2>/dev/null || true
    fi
    if [ "$CLEANUP_LOOP" = "1" ] && [ -n "$LOOP_DEVICE" ]; then
        losetup -d "$LOOP_DEVICE" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ============================================================================
# Device setup
# ============================================================================
setup_device() {
    if [ ! -e "$TARGET" ]; then
        echo "ERROR: $TARGET not found."
        echo ""
        echo "Mount your USB device into the container:"
        echo ""
        echo "  Linux:  docker run --rm -it --privileged -v /dev/sdX:/dev/target keenetic-entware-flash"
        echo ""
        echo "  macOS:  1) sudo dd if=/dev/rdiskN of=/tmp/usb.img bs=1m"
        echo "          2) docker run --rm -it --privileged -v /tmp/usb.img:/dev/target keenetic-entware-flash"
        echo "          3) sudo dd if=/tmp/usb.img of=/dev/rdiskN bs=1m"
        exit 1
    fi

    if [ -b "$TARGET" ]; then
        # Linux: direct block device
        DEVICE="$TARGET"
        echo "Mode: direct block device"
    elif [ -f "$TARGET" ]; then
        # macOS: disk image file → attach via losetup
        echo "Mode: disk image file (macOS)"
        LOOP_DEVICE=$(losetup --find --show --partscan "$TARGET")
        CLEANUP_LOOP=1
        DEVICE="$LOOP_DEVICE"
        echo "Loop device: $LOOP_DEVICE"
    else
        echo "ERROR: $TARGET is neither a block device nor a regular file."
        echo ""
        echo "On macOS, Docker cannot pass block devices directly."
        echo "Use a disk image instead:"
        echo "  1) sudo dd if=/dev/rdiskN of=/tmp/usb.img bs=1m"
        echo "  2) docker run --rm -it --privileged -v /tmp/usb.img:/dev/target keenetic-entware-flash"
        echo "  3) sudo dd if=/tmp/usb.img of=/dev/rdiskN bs=1m"
        exit 1
    fi
}

# ============================================================================
# Display info
# ============================================================================
show_disk_info() {
    echo "============================================"
    echo " Keenetic Entware Flash — USB Preparation Tool"
    echo "============================================"
    echo ""
    echo "Device: $DEVICE"

    local size_bytes
    size_bytes=$(blockdev --getsize64 "$DEVICE" 2>/dev/null || echo "unknown")
    if [ "$size_bytes" != "unknown" ]; then
        local size_gb
        size_gb=$(awk "BEGIN {printf \"%.1f\", $size_bytes / 1073741824}")
        echo "Size:   ${size_gb} GB (${size_bytes} bytes)"
    fi

    echo ""
    echo "Current partition table:"
    parted -s "$DEVICE" print 2>/dev/null || echo "  (no partition table or unreadable)"
    echo ""
    echo "Parameters:"
    echo "  Architecture:      $ARCH ($(arch_to_path "$ARCH"))"
    echo "  Swap size:         ${SWAP_SIZE} MB"
    echo "  Partition table:   ${PARTITION_TABLE}"
    echo "  Entware download:  $([ "$SKIP_ENTWARE" = "1" ] && echo "skip" || echo "yes")"
    echo ""
}

confirm() {
    if [ "$FORCE" = "1" ]; then
        echo "[FORCE mode] Skipping confirmation."
        return 0
    fi

    echo "WARNING: ALL DATA WILL BE DESTROYED!"
    echo ""
    read -r -p "Continue? [y/N]: " answer
    case "$answer" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) echo "Aborted."; exit 0 ;;
    esac
}

# ============================================================================
# Partitioning & formatting
# ============================================================================
partition_disk() {
    echo ""
    echo ">>> Creating ${PARTITION_TABLE^^} partition table..."

    # Wipe existing partition table
    dd if=/dev/zero of="$DEVICE" bs=1M count=1 conv=notrunc 2>/dev/null

    local label_type
    if [ "$PARTITION_TABLE" = "gpt" ]; then
        label_type="gpt"
    else
        label_type="msdos"
    fi

    parted -s "$DEVICE" mklabel "$label_type"

    echo ">>> Creating swap partition (${SWAP_SIZE} MB)..."
    parted -s "$DEVICE" mkpart primary linux-swap 1MiB "${SWAP_SIZE}MiB"

    echo ">>> Creating ext4 partition (remaining space)..."
    parted -s "$DEVICE" mkpart primary ext4 "${SWAP_SIZE}MiB" 100%

    # Wait for partition devices to appear
    sleep 1
    partprobe "$DEVICE" 2>/dev/null || true
    sleep 1

    # Determine partition device names
    local part1 part2
    if [ -e "${DEVICE}p1" ]; then
        part1="${DEVICE}p1"
        part2="${DEVICE}p2"
    elif [ -e "${DEVICE}1" ]; then
        part1="${DEVICE}1"
        part2="${DEVICE}2"
    else
        # In Docker, partition nodes may not appear automatically — use kpartx
        echo ">>> Partition nodes not found, using kpartx..."
        kpartx -av "$DEVICE"
        sleep 1
        local loop_name
        loop_name=$(basename "$DEVICE")
        part1="/dev/mapper/${loop_name}p1"
        part2="/dev/mapper/${loop_name}p2"
        KPARTX_DEVICE="$DEVICE"
        if [ ! -e "$part1" ]; then
            echo "ERROR: Partition devices not found after kpartx."
            echo "Tried: $part1, $part2"
            exit 1
        fi
    fi

    echo ">>> Formatting swap ($part1)..."
    mkswap -L SWAP "$part1"

    echo ">>> Formatting ext4 ($part2)..."
    mkfs.ext4 -O ^metadata_csum -L OPKG -F "$part2"

    echo ">>> Partitioning complete."
    echo ""
    parted -s "$DEVICE" print
}

# ============================================================================
# Find ext4 partition device
# ============================================================================
find_ext4_partition() {
    local loop_name
    loop_name=$(basename "$DEVICE")
    if [ -e "${DEVICE}p2" ]; then
        echo "${DEVICE}p2"
    elif [ -e "${DEVICE}2" ]; then
        echo "${DEVICE}2"
    elif [ -e "/dev/mapper/${loop_name}p2" ]; then
        echo "/dev/mapper/${loop_name}p2"
    else
        echo ""
    fi
}

# ============================================================================
# Entware installation & scripts
# ============================================================================
install_entware() {
    local part2
    part2=$(find_ext4_partition)
    if [ -z "$part2" ]; then
        echo "ERROR: ext4 partition not found."
        exit 1
    fi

    echo ""
    echo ">>> Mounting ext4 partition..."
    mkdir -p "$MOUNT_POINT"
    mount "$part2" "$MOUNT_POINT"

    # Download Entware installer
    if [ "$SKIP_ENTWARE" = "1" ]; then
        echo ">>> Skipping Entware download (SKIP_ENTWARE=1)."
    else
        local filename="${ARCH}-installer.tar.gz"

        local url_arch_dir
        case "$ARCH" in
            mipsel)  url_arch_dir="mipselsf-k3.4" ;;
            mips)    url_arch_dir="mipssf-k3.4" ;;
            aarch64) url_arch_dir="aarch64-k3.10" ;;
        esac

        local url="https://bin.entware.net/${url_arch_dir}/installer/${filename}"
        local fallback="/opt/entware-installers/${filename}"

        echo ">>> Creating install directory..."
        mkdir -p "${MOUNT_POINT}/install"

        echo ">>> Downloading Entware installer..."
        echo "    URL: $url"

        if wget -q --show-progress -O "${MOUNT_POINT}/install/${filename}" "$url" 2>&1 && \
           [ -s "${MOUNT_POINT}/install/${filename}" ]; then
            echo ">>> Entware installer downloaded successfully."
        else
            rm -f "${MOUNT_POINT}/install/${filename}"
            if [ -s "$fallback" ]; then
                echo ">>> Download failed, using built-in fallback..."
                cp "$fallback" "${MOUNT_POINT}/install/${filename}"
                echo ">>> Entware installer copied from fallback."
            else
                echo "WARNING: Failed to download Entware installer and no fallback available."
                echo "URL: $url"
                echo ""
                echo "You can download it manually later and place it in the /install/ directory."
                echo "Or enable OPKG in router settings — the router will install Entware itself."
            fi
        fi
    fi

    # Copy SWAP init script (always, regardless of SKIP_ENTWARE)
    echo ">>> Copying SWAP init script..."
    mkdir -p "${MOUNT_POINT}/scripts"
    cp /opt/scripts/S01swap "${MOUNT_POINT}/scripts/S01swap"
    chmod +x "${MOUNT_POINT}/scripts/S01swap"
    echo ">>> SWAP script saved to /scripts/S01swap on the USB drive."

    echo ">>> Unmounting..."
    umount "$MOUNT_POINT"
}

# ============================================================================
# Success message
# ============================================================================
show_success() {
    echo ""
    echo "============================================"
    echo " SUCCESS! Image is ready."
    echo "============================================"
    echo ""
    echo "Partition layout:"
    echo "  Partition 1: SWAP (${SWAP_SIZE} MB)"
    echo "  Partition 2: OPKG ext4 (data + Entware)"
    echo ""
    if [ "$SKIP_ENTWARE" != "1" ]; then
        echo "Entware architecture: $ARCH ($(arch_to_path "$ARCH"))"
        echo ""
    fi
    echo "SWAP auto-start script: /scripts/S01swap"
    echo "  After OPKG installation, copy it to enable auto-start:"
    echo "  cp /opt/scripts/S01swap /opt/etc/init.d/S01swap"
    echo ""
}

# ============================================================================
# Main
# ============================================================================
main() {
    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
        show_help
    fi

    setup_device
    show_disk_info
    confirm
    partition_disk
    install_entware
    show_success
}

main "$@"
