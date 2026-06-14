#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Keenetic Entware Flash — one-command launcher
# ============================================================================

REMOTE_IMAGE="ghcr.io/maxxxam/keenetic-entware-flash:main"
LOCAL_IMAGE="keenetic-entware-flash"
IMAGE=""
TMP_IMG=""

show_help() {
    cat <<'HELP'
Keenetic Entware Flash — one-command USB preparation

Usage:
  sudo ./run.sh                       # interactive device selection
  sudo ./run.sh /dev/diskN            # macOS (direct)
  sudo ./run.sh /dev/sdX              # Linux (direct)

All extra env variables are forwarded to the container:
  sudo ARCH=aarch64 SWAP_SIZE=512 ./run.sh

Options:
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

cleanup() {
    if [ -n "$TMP_IMG" ] && [ -f "$TMP_IMG" ]; then
        echo ">>> Cleaning up temporary image..."
        rm -f "$TMP_IMG"
    fi
}
trap cleanup EXIT

# ============================================================================
# Args
# ============================================================================
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    show_help
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script requires root privileges."
    echo "Usage: sudo $0 [/dev/diskN]"
    exit 1
fi

DISK="${1:-}"

if [ -z "$DISK" ]; then
    # Interactive device selection
    OS_DETECT="$(uname -s)"
    if [ "$OS_DETECT" = "Darwin" ]; then
        select_disk_macos
    elif [ "$OS_DETECT" = "Linux" ]; then
        select_disk_linux
    else
        echo "ERROR: Unsupported OS for interactive selection."
        echo "Please specify device: sudo $0 /dev/sdX"
        exit 1
    fi
elif [ ! -e "$DISK" ]; then
    echo "ERROR: Device $DISK not found."
    echo "Run without arguments for interactive selection: sudo $0"
    exit 1
fi

# ============================================================================
# Get Docker image: pull pre-built or build locally
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# A locally built dev image always wins. Otherwise we always try to pull the
# latest remote image rather than reusing a cached one: the fast "skip empty
# blocks" write-back below is only safe with an image whose entrypoint formats
# ext4 with uninit_bg, so a stale cached image must not be silently reused.
if docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1; then
    IMAGE="$LOCAL_IMAGE"
else
    echo ">>> Pulling latest pre-built image..."
    if docker pull --platform linux/amd64 "$REMOTE_IMAGE" 2>/dev/null; then
        IMAGE="$REMOTE_IMAGE"
    elif docker image inspect "$REMOTE_IMAGE" >/dev/null 2>&1; then
        echo ">>> Pull failed — using cached image (set FULL_WRITE=1 if unsure it has uninit_bg)..."
        IMAGE="$REMOTE_IMAGE"
    else
        echo ">>> Pull failed, building locally..."
        docker build --platform linux/amd64 \
            --build-arg BASE_IMAGE=cr.yandex/mirror/ubuntu:22.04 \
            --build-arg APT_MIRROR=http://mirror.yandex.ru \
            -t "$LOCAL_IMAGE" "$SCRIPT_DIR"
        IMAGE="$LOCAL_IMAGE"
    fi
    echo ""
fi

# Forward env variables to container
DOCKER_ENV=""
[ -n "${ARCH:-}" ]            && DOCKER_ENV="$DOCKER_ENV -e ARCH=$ARCH"
[ -n "${SWAP_SIZE:-}" ]       && DOCKER_ENV="$DOCKER_ENV -e SWAP_SIZE=$SWAP_SIZE"
[ -n "${PARTITION_TABLE:-}" ] && DOCKER_ENV="$DOCKER_ENV -e PARTITION_TABLE=$PARTITION_TABLE"
[ -n "${SKIP_ENTWARE:-}" ]    && DOCKER_ENV="$DOCKER_ENV -e SKIP_ENTWARE=$SKIP_ENTWARE"
[ -n "${FORCE:-}" ]           && DOCKER_ENV="$DOCKER_ENV -e FORCE=$FORCE"

# ============================================================================
# OS detection & run
# ============================================================================
OS="$(uname -s)"

if [ "$OS" = "Linux" ]; then
    # Linux: pass block device directly
    echo ">>> Linux detected — passing block device directly"
    docker run --rm -it --privileged --platform linux/amd64 \
        $DOCKER_ENV \
        -v "$DISK":/dev/target \
        "$IMAGE"

elif [ "$OS" = "Darwin" ]; then
    # macOS: disk image workflow
    RAW_DISK="${DISK/disk/rdisk}"
    TMP_IMG="/tmp/keenetic-flash-$$.img"

    echo "============================================"
    echo " Keenetic Entware Flash — macOS"
    echo "============================================"
    echo ""
    echo "Device:     $DISK"
    echo "Raw device: $RAW_DISK"
    echo ""

    # Step 1: get disk size and create empty image
    echo ">>> Getting disk size..."
    DISK_SIZE=$(diskutil info -plist "$DISK" | plutil -extract TotalSize raw -)
    echo "    Size: $((DISK_SIZE / 1048576)) MB"

    echo ">>> Creating empty disk image..."
    truncate -s "$DISK_SIZE" "$TMP_IMG"
    chmod 666 "$TMP_IMG"

    # Step 2: run container
    echo ""
    echo ">>> Running container..."
    docker run --rm -it --privileged --platform linux/amd64 \
        -e FORCE=1 \
        $DOCKER_ENV \
        -v "$TMP_IMG":/dev/target \
        "$IMAGE"

    # Step 3: write image back to USB
    echo ""
    echo ">>> Unmounting $DISK before writing..."
    diskutil unmountDisk "$DISK" 2>/dev/null || true

    TOTAL_GB=$(awk "BEGIN {printf \"%.1f\", $DISK_SIZE / 1073741824}")

    # By default we skip all-zero blocks, which writes only ~200 MB instead of
    # the whole disk. This is safe ONLY because entrypoint.sh formats the ext4
    # partition with the uninit_bg feature: empty block groups are marked
    # uninitialized, so the kernel/e2fsck never read their inode tables and the
    # stale data left in the skipped regions of a used USB is ignored.
    #
    # Set FULL_WRITE=1 to write every block (slow, ~64 GB) — a safe fallback
    # for the rare router whose kernel does not handle uninit_bg.
    if [ "${FULL_WRITE:-0}" = "1" ]; then
        echo ">>> Writing image to $RAW_DISK (${TOTAL_GB} GB, full write)..."
    else
        echo ">>> Writing image to $RAW_DISK (${TOTAL_GB} GB, skipping empty blocks)..."
    fi

    FULL_WRITE="${FULL_WRITE:-0}" python3 -c "
import os, sys
BLOCK = 4 * 1024 * 1024
full = os.environ.get('FULL_WRITE') == '1'
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
        if full or data != zero[:len(data)]:
            os.lseek(fd, offset, os.SEEK_SET)
            os.write(fd, data)
            written += len(data)
        offset += len(data)
        pct = offset * 100 // total
        sys.stdout.write('\r    %d%% scanned — %d MB written' % (pct, written // 1048576))
        sys.stdout.flush()
os.fsync(fd)
os.close(fd)
print('\n    Done: %d MB written out of %d MB total (%.0f%% skipped as empty)' % (
    written // 1048576, total // 1048576, (total - written) * 100.0 / total))
" "$TMP_IMG" "$RAW_DISK"

    echo ">>> Ejecting $DISK..."
    diskutil eject "$DISK" 2>/dev/null || true

    echo ""
    echo "Done! USB drive is ready. Insert it into your Keenetic router."
else
    echo "ERROR: Unsupported OS: $OS"
    exit 1
fi
