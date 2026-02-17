#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Keenetic Entware Flash — USB flash drive preparation for Keenetic Entware
# ============================================================================

DEVICE="/dev/target"
MOUNT_POINT="/mnt/usb"

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

Usage:
  docker run --rm -it --privileged \
    -v /dev/sdX:/dev/target \
    keenetic-entware-flash

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
  # Default (mipsel, 1GB swap, MBR)
  docker run --rm -it --privileged -v /dev/sdb:/dev/target keenetic-entware-flash

  # AArch64 with GPT and 512MB swap
  docker run --rm -it --privileged \
    -e ARCH=aarch64 -e SWAP_SIZE=512 -e PARTITION_TABLE=gpt \
    -v /dev/sdb:/dev/target keenatic-flash

  # Skip Entware download (format only)
  docker run --rm -it --privileged \
    -e SKIP_ENTWARE=1 \
    -v /dev/sdb:/dev/target keenatic-flash
HELP
    exit 0
}

# ============================================================================
# Safety checks
# ============================================================================
check_device() {
    if [ ! -e "$DEVICE" ]; then
        echo "ERROR: Device $DEVICE not found."
        echo ""
        echo "Mount your USB device into the container:"
        echo "  docker run --rm -it --privileged -v /dev/sdX:/dev/target keenetic-entware-flash"
        echo ""
        echo "On macOS:  diskutil list → find your disk → /dev/diskN"
        echo "On Linux:  lsblk → find your disk → /dev/sdX"
        exit 1
    fi

    if [ ! -b "$DEVICE" ]; then
        echo "ERROR: $DEVICE is not a block device."
        exit 1
    fi
}

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

    echo "WARNING: ALL DATA ON $DEVICE WILL BE DESTROYED!"
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
    sleep 2
    partprobe "$DEVICE" 2>/dev/null || true
    sleep 1

    # Determine partition device names
    local part1 part2
    if [ -e "${DEVICE}1" ]; then
        part1="${DEVICE}1"
        part2="${DEVICE}2"
    elif [ -e "${DEVICE}p1" ]; then
        part1="${DEVICE}p1"
        part2="${DEVICE}p2"
    else
        echo "ERROR: Partition devices not found after partitioning."
        echo "Tried: ${DEVICE}1, ${DEVICE}p1"
        exit 1
    fi

    echo ">>> Formatting swap ($part1)..."
    mkswap "$part1"

    echo ">>> Formatting ext4 ($part2)..."
    mkfs.ext4 -O ^metadata_csum -F "$part2"

    echo ">>> Partitioning complete."
    echo ""
    parted -s "$DEVICE" print
}

# ============================================================================
# Entware installation
# ============================================================================
install_entware() {
    if [ "$SKIP_ENTWARE" = "1" ]; then
        echo ""
        echo ">>> Skipping Entware download (SKIP_ENTWARE=1)."
        return 0
    fi

    local part2
    if [ -e "${DEVICE}2" ]; then
        part2="${DEVICE}2"
    elif [ -e "${DEVICE}p2" ]; then
        part2="${DEVICE}p2"
    else
        echo "ERROR: ext4 partition not found."
        exit 1
    fi

    local arch_path
    arch_path=$(arch_to_path "$ARCH")
    local filename="EN_${arch_path}-installer.tar.gz"

    # Use the correct URL path based on architecture
    local url_arch_dir
    case "$ARCH" in
        mipsel)  url_arch_dir="mipselsf-k3.4" ;;
        mips)    url_arch_dir="mipssf-k3.4" ;;
        aarch64) url_arch_dir="aarch64-k3.10" ;;
    esac

    local url="https://bin.entware.net/${url_arch_dir}/installer/${filename}"

    echo ""
    echo ">>> Mounting ext4 partition..."
    mkdir -p "$MOUNT_POINT"
    mount "$part2" "$MOUNT_POINT"

    echo ">>> Creating install directory..."
    mkdir -p "${MOUNT_POINT}/install"

    echo ">>> Downloading Entware installer..."
    echo "    URL: $url"

    if wget -q --show-progress -O "${MOUNT_POINT}/install/${filename}" "$url"; then
        echo ">>> Entware installer downloaded successfully."
    else
        echo "WARNING: Failed to download Entware installer."
        echo "URL: $url"
        echo ""
        echo "You can download it manually later and place it in the /install/ directory."
    fi

    echo ">>> Unmounting..."
    umount "$MOUNT_POINT"
}

# ============================================================================
# Success message
# ============================================================================
show_success() {
    echo ""
    echo "============================================"
    echo " SUCCESS! USB flash drive is ready."
    echo "============================================"
    echo ""
    echo "Next steps:"
    echo "  1. Safely eject the USB drive from your computer"
    echo "  2. Insert the USB drive into the Keenetic router"
    echo "  3. Go to router settings → System → USB Storage"
    echo "  4. The router will detect the drive and install Entware"
    echo ""
    echo "Partition layout:"
    echo "  Partition 1: swap (${SWAP_SIZE} MB)"
    echo "  Partition 2: ext4 (data + Entware)"
    echo ""
    if [ "$SKIP_ENTWARE" != "1" ]; then
        echo "Entware architecture: $ARCH ($(arch_to_path "$ARCH"))"
        echo ""
    fi
    echo "For more info: https://help.keenetic.com/hc/ru/articles/360021888880"
}

# ============================================================================
# Main
# ============================================================================
main() {
    # Handle --help
    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
        show_help
    fi

    check_device
    show_disk_info
    confirm
    partition_disk
    install_entware
    show_success
}

main "$@"
