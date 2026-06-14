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

    # Step 1b: verify the card actually stores data across its claimed size.
    # Counterfeit / dead flash reports a huge size but silently drops writes
    # beyond its real (tiny) capacity, so swap (near the start) works while the
    # ext4 data partition never persists. Catch it here instead of after a flash
    # that looks successful but leaves the router with no data partition.
    if [ "${SKIP_CAPACITY_CHECK:-0}" != "1" ]; then
        echo ">>> Verifying real capacity (writes test sectors across the disk)..."
        diskutil unmountDisk force "$DISK" >/dev/null 2>&1 || true
        if ! python3 -c "
import os, sys, struct, time
rdev, total = sys.argv[1], int(sys.argv[2])
SECT = 512
# exponential points from 1 MiB up (pin-points a tiny fake's real boundary)
# plus ~12 points spread linearly to the last sector
exp = [(1 << 20) << i for i in range(40)]
pts = exp + [total * i // 12 for i in range(1, 12)] + [total - SECT]
pts = sorted(set(p - (p % SECT) for p in pts if 0 < p < total))
def stamp(off):
    tag = b'KEENCAP' + struct.pack('<Q', off) + b'\xa5'
    return (tag * (SECT // len(tag) + 1))[:SECT]
fd = os.open(rdev, os.O_WRONLY)
for off in pts:
    os.lseek(fd, off, os.SEEK_SET); os.write(fd, stamp(off))
os.fsync(fd); os.close(fd)
time.sleep(1)
fd = os.open(rdev, os.O_RDONLY)
bad = [off for off in pts if os.pread(fd, SECT, off) != stamp(off)]
# scrub the test sectors we just wrote
os.close(fd)
fd = os.open(rdev, os.O_WRONLY)
for off in pts:
    if off not in bad:
        os.lseek(fd, off, os.SEEK_SET); os.write(fd, b'\x00' * SECT)
os.fsync(fd); os.close(fd)
if bad:
    first = min(bad)
    sys.stderr.write(
        '\n    FAKE/DEFECTIVE CARD: writes past %.2f GB are silently dropped.\n'
        '    The card reports %.1f GB but cannot store that much, so the data\n'
        '    partition will never appear on the router. Replace the card.\n'
        '    (override with SKIP_CAPACITY_CHECK=1 if you really know better)\n'
        % (first / 1e9, total / 1e9))
    sys.exit(1)
print('    OK: capacity verified across the full %.1f GB.' % (total / 1e9))
" "$RAW_DISK" "$DISK_SIZE"; then
            echo ">>> Aborting — bad USB device."
            exit 1
        fi
    fi

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
    diskutil unmountDisk force "$DISK" 2>/dev/null || true

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
import os, sys, time, errno, subprocess
BLOCK = 4 * 1024 * 1024
BAR_W = 30
full = os.environ.get('FULL_WRITE') == '1'
src, dst, diskdev = sys.argv[1], sys.argv[2], sys.argv[3]
total = os.path.getsize(src)
zero = b'\x00' * BLOCK

def human(n):
    n = float(n)
    for u in ('B', 'KB', 'MB', 'GB', 'TB'):
        if n < 1024 or u == 'TB':
            return ('%d %s' % (n, u)) if u == 'B' else ('%.1f %s' % (n, u))
        n /= 1024

def fmt_t(s):
    s = int(s)
    if s < 60: return '%ds' % s
    if s < 3600: return '%dm%02ds' % (s // 60, s % 60)
    return '%dh%02dm' % (s // 3600, (s % 3600) // 60)

start = time.monotonic()
last = [0.0]
written = 0
data_total = total

def draw(note='', final=False):
    now = time.monotonic()
    if not final and not note and now - last[0] < 0.12:
        return
    last[0] = now
    pct = written * 100 // data_total if data_total else 100
    fill = pct * BAR_W // 100
    bar = '█' * fill + '░' * (BAR_W - fill)
    el = now - start
    spd = written / el if el > 0 else 0
    eta = (data_total - written) / spd if spd > 0 else 0
    msg = '\r  [%s] %3d%%  %s / %s  %s/s  %s  ETA %s' % (
        bar, pct, human(written), human(data_total), human(spd), fmt_t(el), fmt_t(eta))
    if note:
        msg += '  (%s)' % note
    sys.stdout.write(msg + '   ')
    sys.stdout.flush()
    if final:
        sys.stdout.write('\n')

# macOS DiskArbitration may auto-mount the disk again the moment we write a
# valid partition table, grabbing the device and causing 'Resource busy'
# (EBUSY). Force-unmount and retry, showing it on the bar instead of hanging.
def force_unmount():
    subprocess.run(['diskutil', 'unmountDisk', 'force', diskdev],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def retry_busy(fn, what):
    for attempt in range(120):
        try:
            return fn()
        except OSError as e:
            if e.errno == errno.EBUSY:
                draw(note='device busy, freeing... %d' % (attempt + 1))
                force_unmount()
                time.sleep(0.5)
                continue
            raise
    sys.stdout.write('\n')
    sys.exit('ERROR: %s stayed busy while %s. Close Finder/Disk Utility, quit '
             'other disk software, replug the USB, then run again.' % (dst, what))

infd = os.open(src, os.O_RDONLY)

# The temp image is sparse: only the partition table, swap header, ext4
# metadata and Entware are actually allocated (a few MB) — the rest is holes.
# Find those allocated extents up front with SEEK_DATA/SEEK_HOLE (instant, no
# I/O) and write only them. Holes are guaranteed zero; the ext4 uninit_bg
# feature makes the stale data they leave on a used USB harmless. This writes
# megabytes, not the whole 64 GB, and never reads the holes.
if full:
    extents = [(0, total)]
else:
    extents = []
    scan = 0
    while scan < total:
        try:
            ds = os.lseek(infd, scan, os.SEEK_DATA)
        except OSError as e:
            if e.errno == errno.ENXIO:
                break          # no more data — rest of the image is holes
            raise
        if ds >= total:
            break
        try:
            de = min(os.lseek(infd, ds, os.SEEK_HOLE), total)
        except OSError:
            de = total
        if de > ds:
            extents.append((ds, de))
        scan = de if de > scan else scan + BLOCK
data_total = sum(e - s for s, e in extents) or 1

outfd = retry_busy(lambda: os.open(dst, os.O_WRONLY), 'opening device')
draw()
for ds, de in extents:
    pos = ds
    while pos < de:
        n = min(BLOCK, de - pos)
        chunk = os.pread(infd, n, pos)
        if not chunk:
            break
        p = pos
        retry_busy(lambda: (os.lseek(outfd, p, os.SEEK_SET), os.write(outfd, chunk)),
                   'writing at %d MB' % (p // 1048576))
        written += len(chunk)
        pos += len(chunk)
        draw()
os.fsync(outfd)
os.close(outfd)
os.close(infd)
draw(final=True)
print('    Done: wrote %s of real data; skipped %s of empty space (%s disk).' % (
    human(data_total), human(total - data_total), human(total)))
" "$TMP_IMG" "$RAW_DISK" "$DISK"

    echo ">>> Ejecting $DISK..."
    diskutil eject "$DISK" 2>/dev/null || true

    echo ""
    echo "Done! USB drive is ready. Insert it into your Keenetic router."
else
    echo "ERROR: Unsupported OS: $OS"
    exit 1
fi
