#!/bin/bash
# apply-patches.sh — Apply SlimLO modifications to vanilla LibreOffice source
#
# Supports two types of patches:
#   *.patch  — applied via git apply (exact diff, may break on new LO versions)
#   *.sh     — executed as scripts with $1 = LO source dir (more robust)
#
set -euo pipefail

LO_SRC_DIR="${1:?Usage: apply-patches.sh <lo-src-dir>}"
PATCHES_DIR="$(cd "$(dirname "$0")/../patches" && pwd)"

if [ ! -d "$LO_SRC_DIR" ]; then
    echo "ERROR: LibreOffice source directory not found: $LO_SRC_DIR"
    exit 1
fi

# Make LO_SRC_DIR absolute
LO_SRC_DIR="$(cd "$LO_SRC_DIR" && pwd)"

TOTAL=0
OK=0
FAIL=0

# Process .sh scripts first, then .patch files (both sorted by name)
for file in "$PATCHES_DIR"/*.sh "$PATCHES_DIR"/*.patch; do
    [ -f "$file" ] || continue
    NAME="$(basename "$file")"
    TOTAL=$((TOTAL + 1))

    echo "--- [$TOTAL] $NAME"

    case "$file" in
        *.sh)
            if bash "$file" "$LO_SRC_DIR"; then
                echo "    OK"
                OK=$((OK + 1))
            else
                echo "    FAILED"
                FAIL=$((FAIL + 1))
            fi
            ;;
        *.patch)
            if git -C "$LO_SRC_DIR" apply --check "$file" 2>/dev/null; then
                git -C "$LO_SRC_DIR" apply "$file"
                echo "    OK"
                OK=$((OK + 1))
            else
                echo "    FAILED: Patch does not apply cleanly"
                FAIL=$((FAIL + 1))
            fi
            ;;
    esac
done

echo ""
echo "=== Patch Summary ==="
echo "Total:   $TOTAL"
echo "Applied: $OK"
echo "Failed:  $FAIL"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "ERROR: Some patches failed. Fix them before building."
    exit 1
fi

if [ "$TOTAL" -eq 0 ]; then
    echo "NOTE: No patches found in $PATCHES_DIR"
fi
