#!/bin/sh
# Copyright 2026 Mattia Giambirtone & All Contributors
# SPDX-License-Identifier: Apache-2.0
# Generated release header. Compressed engine slices and shared weights follow.

# Parse the complete function before reaching the binary payload.
heimdall_main() {
    fail() { echo "heimdall: $*" >&2; exit 1; }
    [ "$(uname -s)" = Linux ] || fail 'this executable requires Linux'
    case "$(uname -m)" in
        x86_64|amd64)
            arch=amd64
            engine_offset=@AMD64_OFFSET@
            engine_size=@AMD64_SIZE@
            engine_hash=@AMD64_HASH@
            ;;
        aarch64|arm64)
            arch=arm64
            engine_offset=@ARM64_OFFSET@
            engine_size=@ARM64_SIZE@
            engine_hash=@ARM64_HASH@
            ;;
        *) fail 'this executable requires AMD64 or ARM64 Linux' ;;
    esac
    self=$(readlink -f -- "$0") || fail 'cannot locate this executable'
    cache_root=${HEIMDALL_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME:?HOME or HEIMDALL_CACHE_DIR must be set}/.cache}/heimdall}
    case "$cache_root" in /*) ;; *) fail 'cache directory must be an absolute path' ;; esac
    original_umask=$(umask)
    umask 077
    mkdir -p -- "$cache_root" || fail "cannot create cache directory $cache_root"
    private_directory() {
        [ -d "$1" ] && [ ! -L "$1" ] &&
            [ "$(stat -c %u -- "$1")" = "$(id -u)" ] &&
            [ "$(stat -c %a -- "$1")" = 700 ]
    }
    private_directory "$cache_root" || fail 'cache must be a private, user-owned directory (mode 700), not a symlink'
    cache="$cache_root/@BUNDLE_ID@-$arch"
    mkdir -p -- "$cache" || fail "cannot create cache directory $cache"
    private_directory "$cache" || fail 'unsafe cache entry'
    valid_files() {
        [ -f "$1/heimdall" ] && [ ! -L "$1/heimdall" ] &&
            [ -x "$1/heimdall" ] && [ -f "$1/network.bin" ] && [ ! -L "$1/network.bin" ] &&
            (cd -- "$1" && sha256sum --status -c <<SUMS
$engine_hash  heimdall
@NETWORK_HASH@  network.bin
SUMS
            )
    }
    if ! valid_files "$cache"; then
        stage=$(mktemp -d "$cache/.extract.XXXXXXXXXX") || fail 'cannot create extraction directory'
        trap 'rm -rf -- "$stage"' 0
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        extract() {
            dd if="$self" bs=65536 skip="$1" count="$2" iflag=skip_bytes,count_bytes status=none |
                gzip -dc > "$3"
        }
        extract "$engine_offset" "$engine_size" "$stage/heimdall" || fail 'engine extraction failed'
        extract @NETWORK_OFFSET@ @NETWORK_SIZE@ "$stage/network.bin" || fail 'network extraction failed'
        chmod 500 "$stage/heimdall" && chmod 400 "$stage/network.bin" || fail 'cannot set cache permissions'
        valid_files "$stage" || fail 'payload checksum mismatch; download the executable again'
        # Atomic file replacement also repairs corrupt caches without modifying
        # an inode used by a running engine. Concurrent writers publish identical
        # verified bytes; no lock or stale lock recovery is needed.
        mv -fT -- "$stage/network.bin" "$cache/network.bin" &&
            mv -fT -- "$stage/heimdall" "$cache/heimdall" || fail 'cannot install cached files'
        rm -rf -- "$stage"
        trap - 0 HUP INT TERM
    fi
    umask "$original_umask"
    # exec preserves UCI pipes, cwd, arguments, PID, signals and exit status.
    # If execution fails (e.g. a noexec mount), the shell reports the error.
    exec "$cache/heimdall" "$@"
}
heimdall_main "$@"
exit 1
# Compressed payload follows.
