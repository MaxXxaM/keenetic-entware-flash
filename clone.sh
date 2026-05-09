#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Keenetic Entware Flash — USB clone (backup / restore)
# ============================================================================

DISK=""
DD_PID=""
OS="$(uname -s)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_IMAGE="ghcr.io/maxxxam/keenetic-entware-flash:main"
LOCAL_IMAGE="keenetic-entware-flash"
TMP_FILES=()
DECOMPRESSED_IMAGE=""
EXPANDED_IMAGE=""

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
  --no-expand   Restore exact image size, do not grow ext4 partition
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
    LC_ALL=C awk "BEGIN {
        if ($bytes >= 1099511627776) printf \"%.1f TB\", $bytes / 1099511627776
        else if ($bytes >= 1073741824) printf \"%.1f GB\", $bytes / 1073741824
        else if ($bytes >= 1048576) printf \"%.1f MB\", $bytes / 1048576
        else if ($bytes >= 1024) printf \"%.1f KB\", $bytes / 1024
        else printf \"%d B\", $bytes
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
    local file
    for file in "${TMP_FILES[@]:-}"; do
        [ -n "$file" ] && [ -f "$file" ] && rm -f "$file"
    done
    return 0
}
trap cleanup EXIT

track_tmp_file() {
    TMP_FILES+=("$1")
}

get_file_size() {
    local file="$1"
    stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null
}

copy_with_progress() {
    local label="$1"
    local src="$2"
    local dst="$3"
    local total="$4"

    python3 - "$label" "$src" "$dst" "$total" <<'PY'
import os
import stat
import sys
import time

BLOCK = 4 * 1024 * 1024
label, src, dst, total_arg = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
total = int(total_arg) if total_arg.isdigit() else 0
done = 0
started = time.monotonic()
last_report = 0.0
out_stream = sys.stderr if dst == "-" else sys.stdout


def human(value):
    value = float(value)
    units = ("B", "KB", "MB", "GB", "TB")
    idx = 0
    while value >= 1024 and idx < len(units) - 1:
        value /= 1024
        idx += 1
    if idx == 0:
        return "%d B" % int(value)
    return "%.1f %s" % (value, units[idx])


def report(final=False):
    global last_report
    now = time.monotonic()
    if not final and now - last_report < 0.2:
        return
    last_report = now

    elapsed = max(now - started, 0.001)
    speed = done / elapsed
    if total > 0:
        left = max(total - done, 0)
        pct = min(done * 100 // total, 100)
        line = "    %s: %s / %s (%d%%), left %s, %s/s" % (
            label, human(done), human(total), pct, human(left), human(speed)
        )
    else:
        line = "    %s: %s, %s/s" % (label, human(done), human(speed))

    out_stream.write("\r" + line + " " * 8)
    out_stream.flush()
    if final:
        out_stream.write("\n")
        out_stream.flush()


src_f = sys.stdin.buffer if src == "-" else open(src, "rb", buffering=0)
if dst == "-":
    dst_f = sys.stdout.buffer
    dst_fd = None
else:
    dst_fd = os.open(dst, os.O_WRONLY | os.O_CREAT, 0o666)
    dst_f = os.fdopen(dst_fd, "wb", buffering=0, closefd=False)

try:
    while True:
        data = src_f.read(BLOCK)
        if not data:
            break
        dst_f.write(data)
        done += len(data)
        report()
    dst_f.flush()
    if dst_fd is not None and stat.S_ISREG(os.fstat(dst_fd).st_mode):
        os.ftruncate(dst_fd, done)
    report(final=True)
finally:
    if src != "-":
        src_f.close()
    if dst != "-":
        dst_f.close()
        os.close(dst_fd)
PY
}

copy_raw_image_sparse() {
    local src="$1"
    local dst="$2"

    python3 - "$src" "$dst" <<'PY'
import os
import sys
import time

BLOCK = 4 * 1024 * 1024
src, dst = sys.argv[1], sys.argv[2]
total = os.path.getsize(src)
zero = b"\x00" * BLOCK
written = 0
offset = 0
started = time.monotonic()
last_report = 0.0


def human(value):
    value = float(value)
    units = ("B", "KB", "MB", "GB", "TB")
    idx = 0
    while value >= 1024 and idx < len(units) - 1:
        value /= 1024
        idx += 1
    if idx == 0:
        return "%d B" % int(value)
    return "%.1f %s" % (value, units[idx])


def report(final=False):
    global last_report
    now = time.monotonic()
    if not final and now - last_report < 0.2:
        return
    last_report = now
    pct = offset * 100 // total if total else 100
    left = max(total - offset, 0)
    speed = offset / max(now - started, 0.001)
    line = "    Prepared: %s / %s (%d%%), left %s, copied %s, %s/s" % (
        human(offset), human(total), pct, human(left), human(written), human(speed)
    )
    sys.stdout.write("\r" + line + " " * 8)
    sys.stdout.flush()
    if final:
        sys.stdout.write("\n")
        sys.stdout.flush()

fd = os.open(dst, os.O_WRONLY)
try:
    with open(src, "rb") as f:
        while offset < total:
            data = f.read(BLOCK)
            if not data:
                break
            if data != zero[:len(data)]:
                os.lseek(fd, offset, os.SEEK_SET)
                os.write(fd, data)
                written += len(data)
            offset += len(data)
            report()
finally:
    os.close(fd)

report(final=True)
PY
}

restore_raw_image() {
    local src="$1"
    local dst="$2"
    local total
    total=$(get_file_size "$src")
    copy_with_progress "Written" "$src" "$dst" "$total"
}

get_docker_image() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "ERROR: Docker is required to expand ext4 images on macOS." >&2
        echo "Install Docker Desktop or run restore with --no-expand." >&2
        exit 1
    fi

    if docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1; then
        echo "$LOCAL_IMAGE"
    elif docker image inspect "$REMOTE_IMAGE" >/dev/null 2>&1; then
        echo "$REMOTE_IMAGE"
    else
        echo ">>> Pulling helper image for ext4 expansion..." >&2
        if docker pull --platform linux/amd64 "$REMOTE_IMAGE" 2>/dev/null; then
            echo "$REMOTE_IMAGE"
        else
            echo ">>> Pull failed, building helper image locally..." >&2
            docker build --platform linux/amd64 \
                --build-arg BASE_IMAGE=cr.yandex/mirror/ubuntu:22.04 \
                --build-arg APT_MIRROR=http://mirror.yandex.ru \
                -t "$LOCAL_IMAGE" "$SCRIPT_DIR" >&2
            echo "$LOCAL_IMAGE"
        fi
    fi
}

expand_ext4_image_with_docker() {
    local image_file="$1"
    local helper_image
    helper_image=$(get_docker_image)

    docker run --rm --privileged --platform linux/amd64 \
        --entrypoint /bin/bash \
        -v "$image_file":/dev/target \
        "$helper_image" -lc '
set -euo pipefail

LOOP_DEVICE=$(losetup --find --show /dev/target)
KPARTX_ACTIVE=0
cleanup() {
    if [ "$KPARTX_ACTIVE" = "1" ]; then
        kpartx -dv "$LOOP_DEVICE" 2>/dev/null || true
    fi
    losetup -d "$LOOP_DEVICE" 2>/dev/null || true
}
trap cleanup EXIT

parted -s "$LOOP_DEVICE" resizepart 2 100%

PART2="${LOOP_DEVICE}p2"
if [ ! -e "$PART2" ]; then
    kpartx -av "$LOOP_DEVICE"
    KPARTX_ACTIVE=1
    PART2="/dev/mapper/$(basename "$LOOP_DEVICE")p2"
fi
if [ ! -e "$PART2" ]; then
    echo "ERROR: ext4 partition device not found after kpartx: $PART2" >&2
    exit 1
fi

e2fsck -fy "$PART2"
resize2fs "$PART2"
parted -s "$LOOP_DEVICE" print
'
}

expand_ext4_image_locally() {
    local image_file="$1"

    for cmd in losetup parted partprobe e2fsck resize2fs kpartx; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "ERROR: $cmd is required to expand ext4 images on Linux." >&2
            echo "Install parted/e2fsprogs/util-linux or run restore with --no-expand." >&2
            exit 1
        fi
    done

    local loop_device part2
    loop_device=$(losetup --find --show "$image_file")
    part2="${loop_device}p2"
    local kpartx_active=0

    parted -s "$loop_device" resizepart 2 100%

    if [ ! -e "$part2" ]; then
        kpartx -av "$loop_device"
        kpartx_active=1
        part2="/dev/mapper/$(basename "$loop_device")p2"
    fi

    if [ ! -e "$part2" ]; then
        [ "$kpartx_active" = "1" ] && kpartx -dv "$loop_device" 2>/dev/null || true
        losetup -d "$loop_device" 2>/dev/null || true
        echo "ERROR: ext4 partition device not found after kpartx: $part2" >&2
        exit 1
    fi

    e2fsck -fy "$part2"
    resize2fs "$part2"
    parted -s "$loop_device" print
    [ "$kpartx_active" = "1" ] && kpartx -dv "$loop_device" 2>/dev/null || true
    losetup -d "$loop_device"
}

expand_ext4_image() {
    local image_file="$1"

    echo ">>> Expanding partition 2 (ext4) to fill target size..."
    if [ "$OS" = "Darwin" ]; then
        expand_ext4_image_with_docker "$image_file"
    else
        expand_ext4_image_locally "$image_file"
    fi
}

prepare_expanded_restore_image() {
    local raw_image="$1"
    local disk_size="$2"
    local expanded_image

    expanded_image=$(mktemp "/tmp/keenetic-restore-expanded-XXXXXX")
    track_tmp_file "$expanded_image"

    truncate -s "$disk_size" "$expanded_image"
    echo ">>> Creating expanded sparse image..."
    copy_raw_image_sparse "$raw_image" "$expanded_image"
    expand_ext4_image "$expanded_image"

    EXPANDED_IMAGE="$expanded_image"
}

decompress_gzip_to_temp() {
    local image="$1"
    local raw_image

    raw_image=$(mktemp "/tmp/keenetic-restore-raw-XXXXXX")
    track_tmp_file "$raw_image"

    echo ">>> Decompressing image for expansion..."
    gunzip -c "$image" > "$raw_image"
    DECOMPRESSED_IMAGE="$raw_image"
}

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
        copy_with_progress "Read" "$read_device" - "$disk_size" | gzip > "$output"
    else
        copy_with_progress "Read" "$read_device" "$output" "$disk_size"
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
    local expand=1

    # Parse arguments
    for arg in "$@"; do
        if [ "$arg" = "--no-expand" ]; then
            expand=0
        elif [ -z "$image" ] && [[ "$arg" != /dev/* ]]; then
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

    local restore_image="$image"
    local restore_compressed="$compressed"
    local restore_size="$image_size"

    if [ "$expand" -eq 1 ]; then
        if [ "$restore_compressed" -eq 1 ]; then
            decompress_gzip_to_temp "$image"
            restore_image="$DECOMPRESSED_IMAGE"
            restore_compressed=0
            restore_size=$(get_file_size "$restore_image")
        fi

        if [ "$restore_size" -gt 0 ] && [ "$disk_size" -gt "$restore_size" ]; then
            local extra_size extra_size_hr
            extra_size=$((disk_size - restore_size))
            extra_size_hr=$(format_size "$extra_size")
            echo ">>> Target is larger than image by $extra_size_hr."
            prepare_expanded_restore_image "$restore_image" "$disk_size"
            restore_image="$EXPANDED_IMAGE"
            restore_size=$(get_file_size "$restore_image")
        fi
    fi

    # Check image fits on disk
    if [ "$restore_size" -gt 0 ] && [ "$restore_size" -gt "$disk_size" ]; then
        local image_size_hr
        image_size_hr=$(format_size "$restore_size")
        echo "ERROR: Image ($image_size_hr) is larger than target disk ($disk_size_hr)."
        exit 1
    fi

    local image_size_hr
    if [ "$restore_size" -gt 0 ]; then
        image_size_hr=$(format_size "$restore_size")
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
    if [ "$expand" -eq 1 ]; then
        echo "  Expand: yes (partition 2 ext4 grows when target is larger)"
    else
        echo "  Expand: no (exact image layout)"
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

    if [ "$restore_compressed" -eq 1 ]; then
        gunzip -c "$restore_image" | copy_with_progress "Written" - "$write_device" "$restore_size"
    else
        # Restore from raw image exactly, including zero-filled blocks.
        restore_raw_image "$restore_image" "$write_device"
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

main() {
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

    local command="$1"
    shift

    case "$command" in
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
            echo "ERROR: Unknown command: $command"
            echo "Usage: sudo $0 backup|restore [options]"
            echo "Run '$0 --help' for details."
            exit 1
            ;;
    esac
}

if [ "${CLONE_SH_TESTING:-0}" != "1" ]; then
    main "$@"
fi
