#!/bin/bash
# test-patches.sh — Verify all patches apply cleanly against a LO version (dry-run)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LO_VERSION="$(cat "$PROJECT_DIR/LO_VERSION" | tr -d '[:space:]')"
PATCHES_DIR="$PROJECT_DIR/patches"
TMP_DIR="$(mktemp -d)"

trap "rm -rf $TMP_DIR" EXIT

echo "=== SlimLO Patch Test ==="
echo "LO Version: $LO_VERSION"
echo ""

# Shallow clone for testing
echo "Cloning LibreOffice $LO_VERSION (shallow)..."
git clone --depth 1 --branch "$LO_VERSION" \
    https://github.com/LibreOffice/core.git "$TMP_DIR/lo-src" 2>&1 | tail -1

echo ""
echo "Testing patches..."
echo ""

TOTAL=0
OK=0
FAIL=0

for patch in "$PATCHES_DIR"/*.patch; do
    [ -f "$patch" ] || continue
    PATCH_NAME="$(basename "$patch")"
    TOTAL=$((TOTAL + 1))

    if git -C "$TMP_DIR/lo-src" apply --check "$patch" 2>/dev/null; then
        echo "  OK   $PATCH_NAME"
        OK=$((OK + 1))
    else
        echo "  FAIL $PATCH_NAME"
        # Show the conflict details
        git -C "$TMP_DIR/lo-src" apply --check "$patch" 2>&1 | head -5 || true
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo "=== Results ==="
echo "Total:  $TOTAL"
echo "OK:     $OK"
echo "Failed: $FAIL"

if [ "$TOTAL" -eq 0 ]; then
    echo "NOTE: No patches found in $PATCHES_DIR"
    exit 0
fi

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "ACTION REQUIRED: Fix failed patches before building."
    exit 1
fi

echo ""
echo "All patches apply cleanly against $LO_VERSION"
