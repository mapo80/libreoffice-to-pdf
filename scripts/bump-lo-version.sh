#!/bin/bash
# bump-lo-version.sh — Update LibreOffice version and test patches
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

NEW_VERSION="${1:?Usage: bump-lo-version.sh <new-lo-tag>}"

# Validate tag format
if [[ ! "$NEW_VERSION" =~ ^libreoffice-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Invalid tag format. Expected: libreoffice-X.Y.Z.W"
    echo "       Got: $NEW_VERSION"
    exit 1
fi

CURRENT_VERSION="$(cat "$PROJECT_DIR/LO_VERSION" | tr -d '[:space:]')"

echo "=== Bumping LibreOffice version ==="
echo "Current: $CURRENT_VERSION"
echo "New:     $NEW_VERSION"
echo ""

# Update version file
echo "$NEW_VERSION" > "$PROJECT_DIR/LO_VERSION"
echo "Updated LO_VERSION"

# Test patches against new version
echo ""
echo "Testing patches against $NEW_VERSION..."
echo ""

"$SCRIPT_DIR/test-patches.sh"

echo ""
echo "=== Version bump complete ==="
echo "Next steps:"
echo "  1. Run: ./scripts/build.sh"
echo "  2. Test the output"
echo "  3. Commit: git add LO_VERSION && git commit -m 'Bump LO to $NEW_VERSION'"
