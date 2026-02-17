#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Keenetic Entware Flash — USB clone (backup / restore)
# ============================================================================

DISK=""
DD_PID=""
OS="$(uname -s)"

show_help() {
    cat <<'HELP'
Keenetic Entware Flash — USB clone (backup / restore)

Usage:
  sudo ./clone.sh backup  [/dev/diskN] [output.img]   # USB → file
  sudo ./clone.sh restore <image.img>  [/dev/diskN]    # file → USB

Backup:
  sudo ./clone.sh backup                          # interactive USB selection
  sudo ./clone.sh backup /dev/disk4               # direct device
  sudo ./clone.sh backup /dev/disk4 ~/backup.img  # custom output path
  sudo ./clone.sh backup --compress               # gzip-compressed output
  sudo ./clone.sh backup /dev/disk4 --compress     # device + compress

Restore:
  sudo ./clone.sh restore backup.img              # interactive USB selection
  sudo ./clone.sh restore backup.img /dev/disk4   # direct device

Options:
  --compress    Compress backup with gzip (.img.gz)
  -h, --help    Show this help
HELP
    exit 0
}

# ============================================================================
# Interactive device selection (macOS)
# ============================================================================
select_disk_macos() {
    local disks=()
    local names=()
    local sizes=()

    while IFS= read -r disk_id; do
        [ -z "$disk_id" ] && continue
        local info
        info=$(diskutil info "$disk_id" 2>/dev/null) || continue

        local name size
        name=$(echo "$info" | grep "Media Name:" | sed 's/.*Media Name: *//')
        size=$(echo "$info" | grep "Disk Size:" | sed 's/.*Disk Size: *//' | sed 's/ (.*//')

        [ -z "$name" ] && name="(unknown)"
        [ -z "$size" ] && size="(unknown)"

        disks+=("$disk_id")
        names+=("$name")
        sizes+=("$size")
    done < <(diskutil list external physical 2>/dev/null | grep "^/dev/" | awk '{print $1}' | sed 's/:$//')

    if [ ${#disks[@]} -eq 0 ]; then
        echo "ERROR: No external USB devices found."
        echo "Insert a USB flash drive and try again."
        exit 1
    fi

    echo "============================================"
    echo " Select USB device"
    echo "============================================"
    echo ""

    local i
    for i in "${!disks[@]}"; do
        printf "  %d) %s — %s (%s)\n" "$((i + 1))" "${disks[$i]}" "${names[$i]}" "${sizes[$i]}"
    done

    echo ""
    echo "  0) Cancel"
    echo ""

    local choice
    while true; do
        read -r -p "Select device [1-${#disks[@]}]: " choice
        if [ "$choice" = "0" ]; then
            echo "Aborted."
            exit 0
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#disks[@]} ]; then
            DISK="${disks[$((choice - 1))]}"
            return
        fi
        echo "Invalid choice. Try again."
    done
}

# ============================================================================
# Interactive device selection (Linux)
# ============================================================================
select_disk_linux() {
    local disks=()
    local descs=()

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local dev size model
        dev=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $4}')
        model=$(echo "$line" | awk '{for(i=7;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')

        [ -z "$model" ] && model="(unknown)"

        disks+=("/dev/$dev")
        descs+=("$size — $model")
    done < <(lsblk -dno NAME,TYPE,RM,SIZE,TRAN,SUBSYSTEMS,MODEL 2>/dev/null | awk '$2=="disk" && $3=="1"')

    if [ ${#disks[@]} -eq 0 ]; then
        echo "ERROR: No removable USB devices found."
        echo "Insert a USB flash drive and try again."
        exit 1
    fi

    echo "============================================"
    echo " Select USB device"
    echo "============================================"
    echo ""

    local i
    for i in "${!disks[@]}"; do
        printf "  %d) %s — %s\n" "$((i + 1))" "${disks[$i]}" "${descs[$i]}"
    done

    echo ""
    echo "  0) Cancel"
    echo ""

    local choice
    while true; do
        read -r -p "Select device [1-${#disks[@]}]: " choice
        if [ "$choice" = "0" ]; then
            echo "Aborted."
            exit 0
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#disks[@]} ]; then
            DISK="${disks[$((choice - 1))]}"
            return
        fi
        echo "Invalid choice. Try again."
    done
}

# ============================================================================
# Select disk (auto-detect OS)
# ============================================================================
select_disk() {
    if [ "$OS" = "Darwin" ]; then
        select_disk_macos
    elif [ "$OS" = "Linux" ]; then
        select_disk_linux
    else
        echo "ERROR: Unsupported OS for interactive selection."
        echo "Please specify device directly."
        exit 1
    fi
}

# ============================================================================
# Get disk size in bytes
# ============================================================================
get_disk_size() {
    local disk="$1"
    if [ "$OS" = "Darwin" ]; then
        diskutil info -plist "$disk" | plutil -extract TotalSize raw -
    else
        blockdev --getsize64 "$disk"
    fi
}

# ============================================================================
# Format bytes to human-readable
# ============================================================================
format_size() {
    local bytes="$1"
    awk "BEGIN {
        if ($bytes >= 1073741824) printf \"%.1f GB\", $bytes / 1073741824
        else if ($bytes >= 1048576) printf \"%.1f MB\", $bytes / 1048576
        else printf \"%.1f KB\", $bytes / 1024
    }"
}

# ============================================================================
# Cleanup
# ============================================================================
cleanup() {
    if [ -n "$DD_PID" ]; then
        kill "$DD_PID" 2>/dev/null || true
        wait "$DD_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ============================================================================
# Backup: USB → file
# ============================================================================
do_backup() {
    local compress=0
    local device=""
    local output=""

    # Parse arguments
    for arg in "$@"; do
        if [ "$arg" = "--compress" ]; then
            compress=1
        elif [ -z "$device" ] && [[ "$arg" == /dev/* ]]; then
            device="$arg"
        elif [ -z "$output" ] && [ "$arg" != "--compress" ]; then
            output="$arg"
        fi
    done

    # Select device if not specified
    if [ -z "$device" ]; then
        select_disk
        device="$DISK"
    elif [ ! -e "$device" ]; then
        echo "ERROR: Device $device not found."
        exit 1
    fi

    # Default output path
    if [ -z "$output" ]; then
        output="$HOME/keenetic-backup-$(date +%Y-%m-%d).img"
        if [ "$compress" -eq 1 ]; then
            output="${output}.gz"
        fi
    elif [ "$compress" -eq 1 ] && [[ "$output" != *.gz ]]; then
        output="${output}.gz"
    fi

    # Get disk size
    local disk_size
    disk_size=$(get_disk_size "$device")
    local disk_size_hr
    disk_size_hr=$(format_size "$disk_size")

    # Use raw disk on macOS for speed
    local read_device="$device"
    if [ "$OS" = "Darwin" ]; then
        read_device="${device/disk/rdisk}"
    fi

    echo "============================================"
    echo " Backup USB → file"
    echo "============================================"
    echo ""
    echo "  Device: $device"
    echo "  Size:   $disk_size_hr"
    echo "  Output: $output"
    if [ "$compress" -eq 1 ]; then
        echo "  Compress: yes (gzip)"
    fi
    echo ""

    # Unmount on macOS
    if [ "$OS" = "Darwin" ]; then
        echo ">>> Unmounting $device..."
        diskutil unmountDisk "$device" 2>/dev/null || true
    fi

    echo ">>> Reading from $read_device..."

    if [ "$compress" -eq 1 ]; then
        # Backup with compression
        if [ "$OS" = "Darwin" ]; then
            dd if="$read_device" bs=4m 2>/dev/null | pv -s "$disk_size" | gzip > "$output"
        else
            dd if="$read_device" bs=4M status=progress 2>&1 | gzip > "$output"
        fi
    else
        # Backup without compression
        if [ "$OS" = "Darwin" ]; then
            dd if="$read_device" of="$output" bs=4m &
            DD_PID=$!
            # Send SIGINFO every 5 seconds for progress
            while kill -0 "$DD_PID" 2>/dev/null; do
                sleep 5
                kill -INFO "$DD_PID" 2>/dev/null || true
            done
            wait "$DD_PID" || true
            DD_PID=""
        else
            dd if="$read_device" of="$output" bs=4M status=progress
        fi
    fi

    local output_size
    output_size=$(stat -f%z "$output" 2>/dev/null || stat -c%s "$output" 2>/dev/null)
    local output_size_hr
    output_size_hr=$(format_size "$output_size")

    echo ""
    echo ">>> Backup complete!"
    echo "    File: $output"
    echo "    Size: $output_size_hr"
    if [ "$compress" -eq 1 ]; then
        local ratio
        ratio=$(awk "BEGIN {printf \"%.0f\", (1 - $output_size / $disk_size) * 100}")
        echo "    Compression: ${ratio}% saved"
    fi
}

# ============================================================================
# Restore: file → USB
# ============================================================================
do_restore() {
    local image=""
    local device=""

    # Parse arguments
    for arg in "$@"; do
        if [ -z "$image" ] && [[ "$arg" != /dev/* ]]; then
            image="$arg"
        elif [ -z "$device" ] && [[ "$arg" == /dev/* ]]; then
            device="$arg"
        fi
    done

    # Validate image file
    if [ -z "$image" ]; then
        echo "ERROR: Image file is required."
        echo "Usage: sudo $0 restore <image.img> [/dev/diskN]"
        exit 1
    fi

    if [ ! -f "$image" ]; then
        echo "ERROR: Image file not found: $image"
        exit 1
    fi

    # Detect if compressed
    local compressed=0
    if [[ "$image" == *.gz ]]; then
        compressed=1
    fi

    # Get image size (uncompressed)
    local image_size
    if [ "$compressed" -eq 1 ]; then
        # For gzip, get uncompressed size (last 4 bytes, works for files < 4GB)
        # For larger files, we skip size check
        image_size=$(gzip -l "$image" 2>/dev/null | tail -1 | awk '{print $2}')
        if [ "$image_size" -eq 0 ] || [ "$image_size" -lt 0 ] 2>/dev/null; then
            image_size=0  # Cannot determine, skip size check
        fi
    else
        image_size=$(stat -f%z "$image" 2>/dev/null || stat -c%s "$image" 2>/dev/null)
    fi

    # Select device if not specified
    if [ -z "$device" ]; then
        select_disk
        device="$DISK"
    elif [ ! -e "$device" ]; then
        echo "ERROR: Device $device not found."
        exit 1
    fi

    # Get disk size
    local disk_size
    disk_size=$(get_disk_size "$device")
    local disk_size_hr
    disk_size_hr=$(format_size "$disk_size")

    # Check image fits on disk
    if [ "$image_size" -gt 0 ] && [ "$image_size" -gt "$disk_size" ]; then
        local image_size_hr
        image_size_hr=$(format_size "$image_size")
        echo "ERROR: Image ($image_size_hr) is larger than target disk ($disk_size_hr)."
        exit 1
    fi

    local image_size_hr
    if [ "$image_size" -gt 0 ]; then
        image_size_hr=$(format_size "$image_size")
    else
        image_size_hr="(unknown — compressed)"
    fi

    # Use raw disk on macOS for speed
    local write_device="$device"
    if [ "$OS" = "Darwin" ]; then
        write_device="${device/disk/rdisk}"
    fi

    echo "============================================"
    echo " Restore file → USB"
    echo "============================================"
    echo ""
    echo "  Image:  $image"
    echo "  Size:   $image_size_hr"
    if [ "$compressed" -eq 1 ]; then
        echo "  Format: gzip compressed"
    fi
    echo "  Target: $device ($disk_size_hr)"
    echo ""
    echo "  WARNING: ALL data on $device will be ERASED!"
    echo ""

    read -r -p "Continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi

    # Unmount on macOS
    if [ "$OS" = "Darwin" ]; then
        echo ""
        echo ">>> Unmounting $device..."
        diskutil unmountDisk "$device" 2>/dev/null || true
    fi

    echo ">>> Writing to $write_device..."

    if [ "$compressed" -eq 1 ]; then
        # Restore from compressed image — stream through gunzip
        if [ "$OS" = "Darwin" ]; then
            gunzip -c "$image" | dd of="$write_device" bs=4m
        else
            gunzip -c "$image" | dd of="$write_device" bs=4M status=progress
        fi
    else
        # Restore from raw image — smart write (skip empty blocks)
        echo "    (skipping empty blocks for speed)"
        python3 -c "
import os, sys
BLOCK = 4 * 1024 * 1024
src, dst = sys.argv[1], sys.argv[2]
total = os.path.getsize(src)
zero = b'\x00' * BLOCK
written = 0
offset = 0
fd = os.open(dst, os.O_WRONLY)
with open(src, 'rb') as f:
    while offset < total:
        data = f.read(BLOCK)
        if not data:
            break
        if data != zero[:len(data)]:
            os.lseek(fd, offset, os.SEEK_SET)
            os.write(fd, data)
            written += len(data)
        offset += len(data)
        pct = offset * 100 // total
        sys.stdout.write('\r    %d%% scanned — %d MB written' % (pct, written // 1048576))
        sys.stdout.flush()
os.close(fd)
print('\n    Done: %d MB written out of %d MB total (%.0f%% was empty)' % (
    written // 1048576, total // 1048576, (total - written) * 100.0 / total))
" "$image" "$write_device"
    fi

    # Eject
    echo ""
    if [ "$OS" = "Darwin" ]; then
        echo ">>> Ejecting $device..."
        diskutil eject "$device" 2>/dev/null || true
    else
        echo ">>> Syncing..."
        sync
    fi

    echo ""
    echo ">>> Restore complete!"
}

# ============================================================================
# Main
# ============================================================================
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    show_help
fi

if [ -z "${1:-}" ]; then
    show_help
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script requires root privileges."
    echo "Usage: sudo $0 backup|restore [options]"
    exit 1
fi

COMMAND="$1"
shift

case "$COMMAND" in
    backup)
        do_backup "$@"
        ;;
    restore)
        do_restore "$@"
        ;;
    -h|--help)
        show_help
        ;;
    *)
        echo "ERROR: Unknown command: $COMMAND"
        echo "Usage: sudo $0 backup|restore [options]"
        echo "Run '$0 --help' for details."
        exit 1
        ;;
esac
