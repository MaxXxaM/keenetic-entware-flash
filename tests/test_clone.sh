#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_file_bytes() {
    local file="$1"
    local offset="$2"
    local count="$3"
    local expected_hex="$4"
    local actual_hex

    actual_hex=$(dd if="$file" bs=1 skip="$offset" count="$count" 2>/dev/null | xxd -p -c 256)
    [ "$actual_hex" = "$expected_hex" ] || fail "unexpected bytes at offset $offset: got $actual_hex, want $expected_hex"
}

test_source_does_not_run_main() {
    local output
    output=$(CLONE_SH_TESTING=1 bash -c "source '$REPO_DIR/clone.sh'; declare -F restore_raw_image >/dev/null; echo sourced-ok") || \
        fail "clone.sh cannot be sourced in test mode"

    [ "$output" = "sourced-ok" ] || fail "clone.sh ran main while being sourced: $output"

    CLONE_SH_TESTING=1 source "$REPO_DIR/clone.sh"
    declare -F restore_raw_image >/dev/null || fail "restore_raw_image function is not defined"
    declare -F copy_with_progress >/dev/null || fail "copy_with_progress function is not defined"
}

test_restore_raw_image_writes_zero_blocks() {
    local tmpdir image target
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    image="$tmpdir/source.img"
    target="$tmpdir/target.img"

    printf '\x11\x22\x33\x44' > "$image"
    dd if=/dev/zero bs=1 count=4 >> "$image" 2>/dev/null
    printf '\xaa\xbb\xcc\xdd' >> "$image"

    printf '\xff%.0s' {1..12} > "$target"

    restore_raw_image "$image" "$target"

    assert_file_bytes "$target" 0 4 "11223344"
    assert_file_bytes "$target" 4 4 "00000000"
    assert_file_bytes "$target" 8 4 "aabbccdd"
}

test_copy_with_progress_uses_operation_label_and_human_sizes() {
    local tmpdir src dst output
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    src="$tmpdir/source.bin"
    dst="$tmpdir/dest.bin"

    printf '\x01\x02\x03\x04' > "$src"
    output=$(copy_with_progress "Read" "$src" "$dst" 4 2>&1)

    cmp "$src" "$dst" >/dev/null || fail "copy_with_progress did not copy file contents"
    [[ "$output" == *"Read:"* ]] || fail "progress output does not use operation label: $output"
    [[ "$output" == *"4 B / 4 B"* ]] || fail "progress output does not show done/total: $output"
    [[ "$output" == *"left 0 B"* ]] || fail "progress output does not show remaining bytes: $output"
}

test_copy_with_progress_keeps_stdout_clean_for_pipes() {
    local tmpdir src streamed log
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    src="$tmpdir/source.bin"
    streamed="$tmpdir/streamed.bin"
    log="$tmpdir/progress.log"

    printf '\x01\x02\x03\x04' > "$src"
    copy_with_progress "Read" "$src" - 4 > "$streamed" 2> "$log"

    cmp "$src" "$streamed" >/dev/null || fail "stdout stream was contaminated by progress output"
    grep -q "Read:" "$log" || fail "progress for stdout mode was not written to stderr"
}

test_source_does_not_run_main
test_restore_raw_image_writes_zero_blocks
test_copy_with_progress_uses_operation_label_and_human_sizes
test_copy_with_progress_keeps_stdout_clean_for_pipes

echo "clone.sh tests passed"
