#!/bin/bash
# 010-force-native-winsymlinks.sh
# On Windows/MSYS2, some upstream tarballs contain symlinks whose target is
# extracted later (effectively dangling at creation time). With non-native
# winsymlink mode this can fail during unpack.
#
# Force winsymlinks:native for affected external tarballs.
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"

patch_winsymlinks_mode() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "    Skip (not found): $file"
        return
    fi

    if grep -q 'winsymlinks:native' "$file"; then
        echo "    Already patched: $(basename "$file")"
        return
    fi

    if grep -q 'winsymlinks' "$file"; then
        sed -E 's/winsymlinks([^a-zA-Z0-9:]|$)/winsymlinks:native\1/g' "$file" > "$file.tmp"
        mv "$file.tmp" "$file"
        echo "    Patched: $(basename "$file") -> winsymlinks:native"
    else
        echo "    Skip (winsymlinks marker not found): $(basename "$file")"
    fi
}

echo "    --- Forcing winsymlinks:native for unpack targets ---"
patch_winsymlinks_mode "$LO_SRC/external/zstd/UnpackedTarball_zstd.mk"
patch_winsymlinks_mode "$LO_SRC/external/zxing/UnpackedTarball_zxing.mk"
echo "    Patch 010 complete"
