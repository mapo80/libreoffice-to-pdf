#!/bin/bash
# 024-fix-avmedia-guard-svdomedia.sh
# Fixes missing HAVE_FEATURE_AVMEDIA guard for PlayerListener in svdomedia.cxx.
#
# When avmedia is disabled (--disable-avmedia), m_xPlayerListener is still
# declared and used unconditionally, causing unresolved external symbols for
# comphelper::WeakComponentImplHelper<XPlayerListener>::release in mergedlo.dll.
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"
TARGET="$LO_SRC/svx/source/svdraw/svdomedia.cxx"

if [ ! -f "$TARGET" ]; then
    echo "    Warning: svx/source/svdraw/svdomedia.cxx not found"
    exit 0
fi

# Already patched? Check if HAVE_FEATURE_AVMEDIA appears near m_xPlayerListener
if grep -B1 'm_xPlayerListener' "$TARGET" | grep -q 'HAVE_FEATURE_AVMEDIA'; then
    echo "    Patch 024 already applied"
    exit 0
fi

# Wrap all m_xPlayerListener occurrences with HAVE_FEATURE_AVMEDIA guards.
# 1. Declaration in struct Impl
# 2. Any usage outside existing HAVE_FEATURE_AVMEDIA blocks
awk '
/m_xPlayerListener/ {
    # Check if previous line already has a HAVE_FEATURE_AVMEDIA guard
    if (prev !~ /HAVE_FEATURE_AVMEDIA/) {
        print "#if HAVE_FEATURE_AVMEDIA"
        print $0
        # If next line is NOT already #endif, add one
        getline
        print $0
        if ($0 !~ /^#endif/) {
            print "#endif"
        }
    } else {
        print $0
    }
    next
}
{ prev = $0; print }
' "$TARGET" > "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"

# Verify
if grep -B1 'm_xPlayerListener' "$TARGET" | grep -q 'HAVE_FEATURE_AVMEDIA'; then
    echo "    Patch 024 complete"
else
    echo "    ERROR: Patch 024 failed"
    exit 2
fi
