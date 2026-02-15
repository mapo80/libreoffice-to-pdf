#!/bin/bash
# 022-fix-external-patch-line-endings.sh
# Converts all CRLF patch files under external/ to LF line endings.
# On Windows (MSVC), gbuild applies patches with --binary flag which
# requires exact byte match. CRLF patches fail against LF tarball sources.
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"

EXTERNAL="$LO_SRC/external"
if [ ! -d "$EXTERNAL" ]; then
    echo "    external/ directory not found (skipping)"
    exit 0
fi

if ! command -v dos2unix >/dev/null 2>&1; then
    echo "    dos2unix not found, using sed fallback..."
    COUNT=0
    while IFS= read -r -d '' pf; do
        if file "$pf" | grep -q 'CRLF'; then
            sed -i 's/\r$//' "$pf"
            COUNT=$((COUNT + 1))
        fi
    done < <(find "$EXTERNAL" -name "*.patch*" -print0 2>/dev/null)
else
    echo "    Converting external/ patch files from CRLF to LF..."
    COUNT=$(find "$EXTERNAL" -name "*.patch*" -exec file {} \; 2>/dev/null | grep -c CRLF || true)
    if [ "$COUNT" -gt 0 ]; then
        find "$EXTERNAL" -name "*.patch*" -print0 2>/dev/null | xargs -0 dos2unix 2>/dev/null
    fi
fi

if [ "$COUNT" -gt 0 ]; then
    echo "    OK: Converted $COUNT patch files from CRLF to LF"
else
    echo "    All patch files already have LF line endings (skipping)"
fi
