#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# Keenetic Entware Flash — USB health check
# ============================================================================
# Diagnoses a USB flash drive: read sanity at start/middle/end, throughput,
# partition table, filesystem check (read-only), optional full read scan,
# optional destructive write test.
#
# No data is written to the device unless you explicitly choose the write
# test and confirm with YES.
# ============================================================================

DISK=""
OS="$(uname -s)"
MODE="quick"          # quick | full | write
ASSUME_YES=0

C_RED=$'\033[0;31m'
C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[0;33m'
C_CYAN=$'\033[0;36m'
C_BOLD=$'\033[1m'
C_RESET=$'\033[0m'

show_help() {
    cat <<'HELP'
Keenetic Entware Flash — USB health check

Usage:
  sudo ./check.sh [mode] [/dev/diskN] [-y]

Modes:
  list              — show all detected disks (internal + USB) and exit
  quick   (default) — info + read probes at start/middle/end + speed + fsck (RO)
  full              — quick + full read scan of whole device (slow, GB-scale)
  entware           — verify Keenetic entware layout: partitions, swap sig,
                      ext4 fsck (RO), entware markers (/opt, opkg, etc).
  write             — DESTRUCTIVE write/verify pass. WIPES ALL DATA.

Examples:
  ./check.sh list                       # no sudo needed for listing
  sudo ./check.sh                       # interactive, quick mode
  sudo ./check.sh quick /dev/disk4
  sudo ./check.sh full /dev/disk4
  sudo ./check.sh entware /dev/disk4    # verify cloned entware integrity
  sudo ./check.sh write /dev/disk4 -y   # skip confirmation (dangerous)

Options:
  -y, --yes     Skip confirmations (use with care)
  -h, --help    Show this help
HELP
    exit 0
}

# ----------------------------------------------------------------------------
# arg parse
# ----------------------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        -h|--help) show_help ;;
        -y|--yes)  ASSUME_YES=1 ;;
        list|quick|full|write|entware) MODE="$arg" ;;
        /dev/*) DISK="$arg" ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# ----------------------------------------------------------------------------
# list all disks (internal + external) — no root required
# ----------------------------------------------------------------------------
list_all_disks() {
    if [ "$OS" = "Darwin" ]; then
        printf "%-12s %-10s %-8s %-22s %s\n" "DEVICE" "SIZE" "LOC" "NAME" "PROTOCOL/RO"
        printf "%-12s %-10s %-8s %-22s %s\n" "------" "----" "---" "----" "-----------"
        local ids
        ids=$(diskutil list 2>/dev/null | grep "^/dev/disk" | awk '{print $1}')
        for d in $ids; do
            local info name size proto ro loc
            info=$(diskutil info "$d" 2>/dev/null) || continue
            name=$(echo "$info" | awk -F: '/Media Name/ {gsub(/^ +/,"",$2); print $2; exit}')
            size=$(echo "$info" | awk -F: '/Disk Size/ {gsub(/^ +/,"",$2); print $2; exit}' | awk -F'(' '{print $1}' | xargs)
            proto=$(echo "$info" | awk -F: '/Protocol/ {gsub(/^ +/,"",$2); print $2; exit}')
            loc=$(echo "$info" | awk -F: '/Device Location/ {gsub(/^ +/,"",$2); print $2; exit}')
            ro=$(echo "$info" | awk -F: '/Media Read-Only/ {gsub(/^ +/,"",$2); print $2; exit}')
            printf "%-12s %-10s %-8s %-22.22s %s%s\n" \
                "$d" "${size:-?}" "${loc:-?}" "${name:-?}" "${proto:-?}" \
                "$([ "$ro" = "Yes" ] && echo ' [RO]' || true)"
        done
        echo ""
        echo "External (USB) only:"
        diskutil list external physical 2>/dev/null | sed 's/^/  /' || true
    else
        echo "All block devices:"
        lsblk -o NAME,SIZE,TYPE,RM,RO,TRAN,MODEL,VENDOR,SERIAL 2>/dev/null \
            || lsblk 2>/dev/null
        echo ""
        echo "Removable / USB only:"
        lsblk -dno NAME,SIZE,TRAN,RM,MODEL 2>/dev/null | awk '$4=="1" || $3=="usb"' | sed 's/^/  /'
    fi
}

if [ "$MODE" = "list" ]; then
    list_all_disks
    exit 0
fi

# ----------------------------------------------------------------------------
# require root for low-level reads
# ----------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run as root (sudo)." >&2
    echo "Tip: './check.sh list' shows available disks without sudo." >&2
    exit 1
fi

# ----------------------------------------------------------------------------
# disk selection (reused style from clone.sh, simplified)
# ----------------------------------------------------------------------------
select_disk_macos() {
    local disks=() names=() sizes=()
    while IFS= read -r d; do
        [ -z "$d" ] && continue
        local info name size
        info=$(diskutil info "$d" 2>/dev/null) || continue
        name=$(echo "$info" | grep "Media Name:" | sed 's/.*Media Name: *//')
        size=$(echo "$info" | grep "Disk Size:" | sed 's/.*Disk Size: *//' | sed 's/ (.*//')
        disks+=("$d"); names+=("${name:-?}"); sizes+=("${size:-?}")
    done < <(diskutil list external physical 2>/dev/null | grep "^/dev/" | awk '{print $1}' | sed 's/:$//')

    [ ${#disks[@]} -eq 0 ] && { echo "ERROR: No external USB devices found."; exit 1; }

    echo "Select USB device:"
    local i
    for i in "${!disks[@]}"; do
        printf "  %d) %s — %s (%s)\n" "$((i+1))" "${disks[$i]}" "${names[$i]}" "${sizes[$i]}"
    done
    echo "  0) Cancel"
    local c
    while true; do
        read -r -p "Choice: " c
        [ "$c" = "0" ] && exit 0
        if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#disks[@]} ]; then
            DISK="${disks[$((c-1))]}"; return
        fi
    done
}

select_disk_linux() {
    local disks=() descs=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local dev size model
        dev=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $4}')
        model=$(echo "$line" | awk '{for(i=7;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')
        disks+=("/dev/$dev"); descs+=("${size:-?} — ${model:-?}")
    done < <(lsblk -dno NAME,TYPE,RM,SIZE,TRAN,SUBSYSTEMS,MODEL 2>/dev/null | awk '$2=="disk" && $3=="1"')

    [ ${#disks[@]} -eq 0 ] && { echo "ERROR: No removable USB devices found."; exit 1; }

    echo "Select USB device:"
    local i
    for i in "${!disks[@]}"; do
        printf "  %d) %s — %s\n" "$((i+1))" "${disks[$i]}" "${descs[$i]}"
    done
    echo "  0) Cancel"
    local c
    while true; do
        read -r -p "Choice: " c
        [ "$c" = "0" ] && exit 0
        if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#disks[@]} ]; then
            DISK="${disks[$((c-1))]}"; return
        fi
    done
}

if [ -z "$DISK" ]; then
    if [ "$OS" = "Darwin" ]; then select_disk_macos
    elif [ "$OS" = "Linux" ]; then select_disk_linux
    else echo "ERROR: Unsupported OS."; exit 1
    fi
fi

[ -b "$DISK" ] || [ -c "$DISK" ] || { echo "ERROR: $DISK not a block/char device"; exit 1; }

# ----------------------------------------------------------------------------
# raw device path on macOS (rdisk = unbuffered = fast)
# ----------------------------------------------------------------------------
RAW_DISK="$DISK"
if [ "$OS" = "Darwin" ]; then
    RAW_DISK="${DISK/disk/rdisk}"
fi

# ----------------------------------------------------------------------------
# pretty print helpers
# ----------------------------------------------------------------------------
hr()    { printf "${C_CYAN}--------------------------------------------------------${C_RESET}\n"; }
title() { hr; printf "${C_BOLD} %s${C_RESET}\n" "$1"; hr; }
ok()    { printf "${C_GREEN}[OK]${C_RESET}    %s\n" "$1"; }
warn()  { printf "${C_YELLOW}[WARN]${C_RESET}  %s\n" "$1"; }
fail()  { printf "${C_RED}[FAIL]${C_RESET}  %s\n" "$1"; }
info()  { printf "        %s\n" "$1"; }

ERRORS=0
WARNS=0
note_fail() { ERRORS=$((ERRORS+1)); fail "$1"; }
note_warn() { WARNS=$((WARNS+1));  warn "$1"; }

# ----------------------------------------------------------------------------
# resolve e2fsprogs tools — brew keeps them keg-only (not in PATH), and under
# sudo PATH is sanitized anyway. Probe PATH then known brew keg locations.
# ----------------------------------------------------------------------------
resolve_tool() {
    local name="$1" p
    p=$(command -v "$name" 2>/dev/null) && { echo "$p"; return 0; }
    for p in \
        /usr/local/opt/e2fsprogs/sbin/"$name" \
        /opt/homebrew/opt/e2fsprogs/sbin/"$name" \
        /usr/local/sbin/"$name" \
        /sbin/"$name" /usr/sbin/"$name"; do
        [ -x "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}
E2FSCK=$(resolve_tool e2fsck || true)
DEBUGFS=$(resolve_tool debugfs || true)

# ----------------------------------------------------------------------------
# device info + size in bytes
# ----------------------------------------------------------------------------
get_size_bytes() {
    if [ "$OS" = "Darwin" ]; then
        diskutil info "$DISK" 2>/dev/null \
            | awk -F'[()]' '/Disk Size:/ {print $2}' \
            | awk '{print $1}'
    else
        blockdev --getsize64 "$DISK" 2>/dev/null
    fi
}

human_size() {
    local b="$1"
    awk -v b="$b" 'BEGIN{
        s="B KB MB GB TB"; split(s,a," ");
        i=1; while (b>=1024 && i<5) { b/=1024; i++ }
        printf "%.2f %s", b, a[i]
    }'
}

title "Device: $DISK"
if [ "$OS" = "Darwin" ]; then
    diskutil info "$DISK" 2>/dev/null | grep -E "Media Name|Disk Size|Protocol|SMART Status|Media Read-Only|Removable|Device Block Size" \
        | sed 's/^ */  /'
else
    lsblk -o NAME,SIZE,TRAN,RO,MODEL,VENDOR,SERIAL "$DISK" 2>/dev/null || true
fi

SIZE_BYTES=$(get_size_bytes || true)
if [ -z "${SIZE_BYTES:-}" ] || ! [[ "$SIZE_BYTES" =~ ^[0-9]+$ ]]; then
    note_warn "Could not determine device size — some tests will be skipped."
    SIZE_BYTES=0
else
    info "Detected size: $SIZE_BYTES bytes ($(human_size "$SIZE_BYTES"))"
fi

# ----------------------------------------------------------------------------
# partition table dump
# ----------------------------------------------------------------------------
title "Partition table"
if [ "$OS" = "Darwin" ]; then
    diskutil list "$DISK" 2>&1 | sed 's/^/  /' || note_warn "diskutil list failed"
else
    if command -v fdisk >/dev/null 2>&1; then
        fdisk -l "$DISK" 2>&1 | sed 's/^/  /' || note_warn "fdisk failed"
    else
        lsblk "$DISK" 2>&1 | sed 's/^/  /' || true
    fi
fi

# ----------------------------------------------------------------------------
# read probes: start / middle / end
# ----------------------------------------------------------------------------
title "Read probes (start / middle / end)"

# unmount on macOS to allow raw access
if [ "$OS" = "Darwin" ]; then
    diskutil unmountDisk "$DISK" >/dev/null 2>&1 || true
fi

PROBE_BS=$((1024*1024))   # 1 MiB
PROBE_COUNT=4             # 4 MiB per probe

read_probe() {
    local label="$1" skip="$2"
    local out err rc
    err=$(mktemp)
    out=$(dd if="$RAW_DISK" of=/dev/null bs=$PROBE_BS count=$PROBE_COUNT iseek="$skip" 2>"$err"; echo "rc=$?")
    rc="${out##*rc=}"
    if [ "$rc" = "0" ]; then
        local bytes
        bytes=$(grep -Eo '[0-9]+ bytes' "$err" | head -1 | awk '{print $1}')
        ok "$label: read $(human_size "${bytes:-0}") at offset $((skip * PROBE_BS / 1024 / 1024)) MiB"
    else
        note_fail "$label: read FAILED at offset $((skip * PROBE_BS / 1024 / 1024)) MiB"
        sed 's/^/        /' "$err"
    fi
    rm -f "$err"
}

if [ "$SIZE_BYTES" -gt 0 ]; then
    TOTAL_MIB=$(( SIZE_BYTES / PROBE_BS ))
    read_probe "start " 0
    if [ "$TOTAL_MIB" -gt $((PROBE_COUNT * 4)) ]; then
        read_probe "middle" $(( TOTAL_MIB / 2 ))
        read_probe "end-ish" $(( TOTAL_MIB - PROBE_COUNT - 1 ))
    fi
else
    read_probe "start " 0
fi

# ----------------------------------------------------------------------------
# read speed sample
# ----------------------------------------------------------------------------
title "Read speed (sequential, 64 MiB from start)"
SPEED_OUT=$(mktemp)
SPEED_BYTES=$((64*1024*1024))
T0=$(date +%s)
if dd if="$RAW_DISK" of=/dev/null bs=1048576 count=64 2>"$SPEED_OUT"; then
    T1=$(date +%s)
    ELAPSED=$(( T1 - T0 )); [ "$ELAPSED" -lt 1 ] && ELAPSED=1
    SPEED_BPS=$(( SPEED_BYTES / ELAPSED ))
    info "Raw: $(grep -E 'bytes.*transferred|copied' "$SPEED_OUT" | head -1)"
    ok "Speed: $(human_size "$SPEED_BPS")/s  (64 MiB in ${ELAPSED}s)"
else
    note_fail "Speed read failed."
    sed 's/^/  /' "$SPEED_OUT"
fi
rm -f "$SPEED_OUT"

# ----------------------------------------------------------------------------
# filesystem check (read-only) on each partition
# ----------------------------------------------------------------------------
title "Filesystem check (read-only)"
list_parts() {
    if [ "$OS" = "Darwin" ]; then
        diskutil list "$DISK" 2>/dev/null | awk '/^ +[0-9]+:/ {print $NF}' | grep -E "^disk[0-9]+s[0-9]+$" | sed 's|^|/dev/|'
    else
        lsblk -lno NAME "$DISK" 2>/dev/null | tail -n +2 | sed 's|^|/dev/|'
    fi
}

PARTS=$(list_parts || true)
if [ -z "$PARTS" ]; then
    info "No partitions detected."
else
    for p in $PARTS; do
        # detect FS type
        local_fs=""
        if [ "$OS" = "Darwin" ]; then
            pinfo=$(diskutil info "$p" 2>/dev/null || true)
            local_fs=$(echo "$pinfo" | awk -F: '/File System Personality/ {gsub(/^ +/,"",$2); print $2; exit}')
            [ -z "$local_fs" ] && local_fs=$(echo "$pinfo" | awk -F: '/Type \(Bundle\)/ {gsub(/^ +/,"",$2); print $2; exit}')
            [ -z "$local_fs" ] && local_fs=$(echo "$pinfo" | awk -F: '/Partition Type/ {gsub(/^ +/,"",$2); print $2; exit}')
            # confirm ext via superblock magic 0xEF53 at offset 1080 when type vague
            # (read aligned block to temp first — raw device rejects bs=1)
            if [ -z "$local_fs" ] || echo "$local_fs" | grep -qi "linux\|unknown"; then
                sb=$(mktemp)
                dd if="${p/disk/rdisk}" of="$sb" bs=512 count=4 2>/dev/null \
                    || dd if="$p" of="$sb" bs=512 count=4 2>/dev/null || true
                magic=$(xxd -s 1080 -l 2 -p "$sb" 2>/dev/null || true)
                [ "${magic:-}" = "53ef" ] && local_fs="ext"
                rm -f "$sb"
            fi
        else
            local_fs=$(blkid -o value -s TYPE "$p" 2>/dev/null || true)
        fi
        info "$p — fs: ${local_fs:-unknown}"

        case "$local_fs" in
            *ext*|ext2|ext3|ext4|Linux*)
                if [ -n "$E2FSCK" ]; then
                    out=$("$E2FSCK" -fn "$p" 2>&1) && ok "$p e2fsck clean" || note_warn "$p e2fsck reported issues:"
                    echo "$out" | sed 's/^/        /'
                else
                    warn "No e2fsck found — skipping ext check (brew install e2fsprogs)"
                fi
                ;;
            msdos|vfat|*FAT32*|*FAT16*)
                if command -v fsck_msdos >/dev/null 2>&1; then
                    fsck_msdos -n "$p" 2>&1 | sed 's/^/        /' || note_warn "$p fsck_msdos issues"
                fi
                ;;
            *ExFAT*|*exfat*)
                info "  ExFAT — skipping fsck_msdos (not supported for ExFAT)"
                ;;
            *)
                info "  (no fsck for type '$local_fs')"
                ;;
        esac
    done
fi

# ----------------------------------------------------------------------------
# full read scan
# ----------------------------------------------------------------------------
if [ "$MODE" = "full" ] || [ "$MODE" = "write" ]; then
    title "Full read scan"
    if [ "$SIZE_BYTES" -eq 0 ]; then
        note_warn "Skipping (size unknown)."
    else
        EST_SEC=$(( SIZE_BYTES / 20000000 ))
        echo "  Reading whole $(human_size "$SIZE_BYTES") to /dev/null (no writes)."
        echo "  Estimated time at ~20 MB/s: ~${EST_SEC}s. Progress every 3s."
        SCAN_LOG=$(mktemp)

        if [ "$OS" = "Darwin" ]; then
            PROG_SIG="INFO"
            DD_EXTRA=""
        else
            PROG_SIG="USR1"
            DD_EXTRA="status=progress"
        fi

        START=$(date +%s)
        # shellcheck disable=SC2086
        dd if="$RAW_DISK" of=/dev/null bs=4194304 conv=noerror,sync $DD_EXTRA 2>"$SCAN_LOG" &
        DD_PID=$!

        LAST_BYTES=0
        while kill -0 "$DD_PID" 2>/dev/null; do
            sleep 3
            kill -"$PROG_SIG" "$DD_PID" 2>/dev/null || true
            sleep 0.2
            CUR_LINE=$(grep -E 'bytes.*transferred|copied' "$SCAN_LOG" | tail -1)
            CUR_BYTES=$(echo "$CUR_LINE" | grep -Eo '^[0-9]+' | head -1)
            if [ -n "${CUR_BYTES:-}" ] && [ "$CUR_BYTES" -gt 0 ]; then
                NOW=$(date +%s)
                EL=$(( NOW - START )); [ "$EL" -lt 1 ] && EL=1
                AVG=$(( CUR_BYTES / EL ))
                INST=$(( (CUR_BYTES - LAST_BYTES) / 3 ))
                PCT=$(( CUR_BYTES * 100 / SIZE_BYTES ))
                ETA=$(( (SIZE_BYTES - CUR_BYTES) / (AVG > 0 ? AVG : 1) ))
                printf "  [%3d%%] %s / %s  avg %s/s  inst %s/s  ETA %ds\n" \
                    "$PCT" "$(human_size "$CUR_BYTES")" "$(human_size "$SIZE_BYTES")" \
                    "$(human_size "$AVG")" "$(human_size "$INST")" "$ETA"
                LAST_BYTES="$CUR_BYTES"
            fi
        done

        wait "$DD_PID"
        DD_RC=$?
        END=$(date +%s)
        TOTAL=$(( END - START )); [ "$TOTAL" -lt 1 ] && TOTAL=1
        AVG_FINAL=$(( SIZE_BYTES / TOTAL ))

        if [ "$DD_RC" -eq 0 ]; then
            ok "Full read completed in ${TOTAL}s — avg $(human_size "$AVG_FINAL")/s"
            tail -3 "$SCAN_LOG" | sed 's/^/        /'
        else
            note_fail "Full read failed (rc=$DD_RC):"
            tail -20 "$SCAN_LOG" | sed 's/^/        /'
        fi
        rm -f "$SCAN_LOG"
    fi
fi

# ----------------------------------------------------------------------------
# entware verification
# ----------------------------------------------------------------------------
detect_part_kind() {
    # echo one of: ext | swap | unknown
    # macOS raw devices (/dev/rdiskN) reject unaligned bs=1 reads, so grab a
    # block-aligned 64 KiB head into a temp file, then inspect bytes offline.
    local p="$1" raw="${p/disk/rdisk}"
    local head magic sig pg
    head=$(mktemp)
    if ! dd if="$raw" of="$head" bs=512 count=128 2>/dev/null; then
        dd if="$p" of="$head" bs=512 count=128 2>/dev/null || true
    fi
    # ext superblock magic 0xEF53 at byte 1080 (little-endian -> "53ef")
    magic=$(xxd -s 1080 -l 2 -p "$head" 2>/dev/null || true)
    if [ "${magic:-}" = "53ef" ]; then rm -f "$head"; echo ext; return; fi
    # swap signature "SWAPSPACE2" at end of first page (try common page sizes)
    for pg in 4096 8192 16384 32768 65536; do
        sig=$(dd if="$head" bs=1 skip=$((pg-10)) count=10 2>/dev/null || true)
        if [ "$sig" = "SWAPSPACE2" ]; then rm -f "$head"; echo "swap:$pg"; return; fi
    done
    rm -f "$head"
    echo unknown
}

ext_label() {
    local p="$1"
    [ -n "$DEBUGFS" ] || return 1
    "$DEBUGFS" -R "show_super_stats -h" "$p" 2>/dev/null \
        | awk -F: '/Filesystem volume name/ {gsub(/^ +/,"",$2); print $2; exit}'
}

debugfs_ls() {
    local p="$1" path="$2"
    [ -n "$DEBUGFS" ] || return 2
    "$DEBUGFS" -R "ls -l $path" "$p" 2>/dev/null
}

debugfs_has() {
    local p="$1" path="$2"
    [ -n "$DEBUGFS" ] || return 2
    "$DEBUGFS" -R "stat $path" "$p" 2>/dev/null | grep -q "Inode:"
}

if [ "$MODE" = "entware" ]; then
    title "Entware layout verification"

    PARTS=$(list_parts || true)
    if [ -z "$PARTS" ]; then
        note_fail "No partitions found. Restore may have failed."
    fi

    HAS_ROOT=0
    HAS_SWAP=0
    HAS_ENTWARE_MARKER=0

    for p in $PARTS; do
        echo ""
        info "── $p ──"
        # size in bytes
        if [ "$OS" = "Darwin" ]; then
            psize=$(diskutil info "$p" 2>/dev/null | awk -F'[()]' '/Disk Size:/ {print $2}' | awk '{print $1}')
        else
            psize=$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)
        fi
        [ -z "${psize:-}" ] && psize=0
        info "size: $(human_size "$psize")"

        kind=$(detect_part_kind "$p")
        case "$kind" in
            ext)
                label=$(ext_label "$p" || true)
                ok "Type: ext2/3/4 (magic 0xEF53)${label:+, label: $label}"
                # Keenetic layout: SWAP-labeled ext partition holds the swapfile,
                # DATA/other holds the entware rootfs.
                is_swap_part=0
                if echo "${label:-}" | grep -qi "swap"; then
                    is_swap_part=1
                    HAS_SWAP=1
                    info "Recognized as Keenetic swap partition (ext + swapfile)"
                else
                    HAS_ROOT=1
                fi

                if [ -n "$E2FSCK" ]; then
                    if [ "$OS" = "Darwin" ]; then
                        diskutil unmount "$p" >/dev/null 2>&1 || true
                    fi
                    out=$("$E2FSCK" -fn "$p" 2>&1)
                    rc=$?
                    if [ "$rc" -eq 0 ]; then
                        ok "e2fsck: clean"
                    else
                        note_warn "e2fsck rc=$rc — issues present"
                    fi
                    echo "$out" | sed 's/^/        /'
                else
                    note_warn "e2fsck missing — install: brew install e2fsprogs"
                fi

                if [ -n "$DEBUGFS" ] && [ "$is_swap_part" -eq 0 ]; then
                    echo ""
                    info "Root directory:"
                    debugfs_ls "$p" "/" | sed 's/^/        /'

                    # entware markers — typical layout: rootfs with /opt, /etc/opkg.conf, /bin/opkg, OR
                    # the partition itself is /opt content directly
                    markers_found=0
                    for m in /opt /etc/opkg.conf /bin/opkg /sbin/init /etc/init.d /usr/bin/opkg \
                             /opkg.conf /etc/entware /share/entware; do
                        if debugfs_has "$p" "$m"; then
                            ok "marker: $m"
                            markers_found=$((markers_found+1))
                        fi
                    done

                    if [ "$markers_found" -gt 0 ]; then
                        HAS_ENTWARE_MARKER=1
                    else
                        note_warn "No entware markers in root of $p — may be data partition"
                    fi
                elif [ -n "$DEBUGFS" ] && [ "$is_swap_part" -eq 1 ]; then
                    # look for a swapfile on the swap partition
                    for sf in /swap /swapfile /.swap /swap.img; do
                        if debugfs_has "$p" "$sf"; then
                            ok "swapfile: $sf"
                        fi
                    done
                else
                    note_warn "debugfs missing — install: brew install e2fsprogs (then content not verified)"
                fi
                ;;
            swap:*)
                pgsz="${kind#swap:}"
                ok "Type: Linux swap (signature 'SWAPSPACE2', page size $pgsz)"
                HAS_SWAP=1
                # parse mkswap v1 header — version(u32 LE) + last_page(u32 LE) at offset 1024
                # offset 1024 = sector 2 start, so an aligned bs=512 read works
                hdr_bytes=$(dd if="${p/disk/rdisk}" bs=512 count=1 iseek=2 2>/dev/null | xxd -p | tr -d '\n' | cut -c1-16 || true)
                if [ ${#hdr_bytes} -eq 16 ]; then
                    # little-endian u32 reverse via Python (pre-installed on macOS)
                    parsed=$(python3 -c "
import sys
h=bytes.fromhex('$hdr_bytes')
ver=int.from_bytes(h[0:4],'little')
lp =int.from_bytes(h[4:8],'little')
print(f'{ver} {lp}')" 2>/dev/null || true)
                    if [ -n "$parsed" ]; then
                        ver=$(echo "$parsed" | awk '{print $1}')
                        lp=$(echo "$parsed" | awk '{print $2}')
                        swap_bytes=$(( (lp + 1) * pgsz ))
                        info "version: $ver, last_page: $lp"
                        info "declared swap size: $(human_size "$swap_bytes")"
                        [ "$ver" != "1" ] && note_warn "Unexpected swap version $ver (expected 1)"
                    fi
                fi
                ;;
            unknown)
                note_warn "Unknown filesystem on $p — no ext or swap signature found"
                ;;
        esac
    done

    echo ""
    title "Entware verdict"
    [ "$HAS_ROOT" -eq 1 ]            && ok   "rootfs partition: present"      || note_fail "No ext rootfs found"
    [ "$HAS_SWAP" -eq 1 ]            && ok   "swap partition:   present"      || note_warn "No swap partition found (may be intentional)"
    [ "$HAS_ENTWARE_MARKER" -eq 1 ]  && ok   "entware markers:  found"        || note_warn "Could not confirm entware content (need debugfs)"
fi

# ----------------------------------------------------------------------------
# destructive write test
# ----------------------------------------------------------------------------
if [ "$MODE" = "write" ]; then
    title "DESTRUCTIVE write/verify test"
    echo "${C_RED}This will OVERWRITE the first 256 MiB of $DISK with a pattern,${C_RESET}"
    echo "${C_RED}then read it back and verify. Existing partition table will be destroyed.${C_RESET}"
    if [ "$ASSUME_YES" -ne 1 ]; then
        read -r -p "Type 'YES' to proceed: " conf
        [ "$conf" = "YES" ] || { echo "Aborted."; exit 0; }
    fi

    if [ "$OS" = "Darwin" ]; then
        diskutil unmountDisk "$DISK" >/dev/null 2>&1 || true
    fi

    TEST_BYTES=$((256*1024*1024))
    [ "$SIZE_BYTES" -gt 0 ] && [ "$SIZE_BYTES" -lt "$TEST_BYTES" ] && TEST_BYTES="$SIZE_BYTES"
    TEST_MIB=$(( TEST_BYTES / 1024 / 1024 ))
    PATTERN_FILE=$(mktemp)
    READBACK=$(mktemp)

    echo "  Writing $TEST_MIB MiB of pseudo-random pattern..."
    dd if=/dev/urandom of="$PATTERN_FILE" bs=1048576 count="$TEST_MIB" 2>/dev/null
    if dd if="$PATTERN_FILE" of="$RAW_DISK" bs=1m count="$TEST_MIB" conv=sync 2>&1 | sed 's/^/  /'; then
        ok "Write completed."
    else
        note_fail "Write FAILED — flash is read-only or dying."
        rm -f "$PATTERN_FILE" "$READBACK"
        exit 1
    fi

    sync
    sleep 1

    echo "  Reading back..."
    dd if="$RAW_DISK" of="$READBACK" bs=1m count="$TEST_MIB" 2>&1 | sed 's/^/  /'

    if cmp -s "$PATTERN_FILE" "$READBACK"; then
        ok "Readback matches written pattern — write/verify PASSED."
    else
        note_fail "Readback DIFFERS — flash is corrupting data."
        cmp "$PATTERN_FILE" "$READBACK" 2>&1 | head -5 | sed 's/^/        /'
    fi
    rm -f "$PATTERN_FILE" "$READBACK"
fi

# ----------------------------------------------------------------------------
# summary
# ----------------------------------------------------------------------------
title "Summary"
echo "  Failures: $ERRORS"
echo "  Warnings: $WARNS"
if [ "$ERRORS" -eq 0 ] && [ "$WARNS" -eq 0 ]; then
    ok "Device looks healthy on tests performed."
    if [ "$MODE" = "quick" ]; then
        echo ""
        echo "  Quick mode only sampled 3 spots (~12 MiB of $(human_size "$SIZE_BYTES"))."
        echo "  If problems persist, scan whole device:"
        echo "      sudo $0 full $DISK"
        echo "  Or destructive write/verify (wipes data):"
        echo "      sudo $0 write $DISK"
    fi
    exit 0
elif [ "$ERRORS" -eq 0 ]; then
    warn "Some warnings. Consider running: sudo $0 full $DISK"
    exit 0
else
    fail "Device shows errors. Replace it — do not trust it with data."
    exit 1
fi
