#!/bin/bash
# 024-fix-avmedia-guard-svdomedia.sh
# Fixes missing HAVE_FEATURE_AVMEDIA guards for PlayerListener across the codebase.
#
# When avmedia is disabled (--disable-avmedia), PlayerListener references that are
# not wrapped in HAVE_FEATURE_AVMEDIA guards cause unresolved external symbols:
#   - svdomedia.cxx: m_xPlayerListener declared/used without guard
#   - View.hxx: forward decl and member mxDropMediaSizeListener without guard
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"

# ---------- Part 1: svx/source/svdraw/svdomedia.cxx ----------
TARGET="$LO_SRC/svx/source/svdraw/svdomedia.cxx"
if [ -f "$TARGET" ]; then
    if grep -B1 'm_xPlayerListener' "$TARGET" | grep -q 'HAVE_FEATURE_AVMEDIA'; then
        echo "    Part 1 (svdomedia.cxx): already patched"
    else
        awk '
/m_xPlayerListener/ {
    if (prev !~ /HAVE_FEATURE_AVMEDIA/) {
        print "#if HAVE_FEATURE_AVMEDIA"
        print $0
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

        if grep -B1 'm_xPlayerListener' "$TARGET" | grep -q 'HAVE_FEATURE_AVMEDIA'; then
            echo "    Part 1 (svdomedia.cxx): patched"
        else
            echo "    ERROR: Part 1 (svdomedia.cxx) failed"
            exit 2
        fi
    fi
else
    echo "    Warning: svdomedia.cxx not found"
fi

# ---------- Part 2: sd/source/ui/inc/View.hxx ----------
TARGET2="$LO_SRC/sd/source/ui/inc/View.hxx"
if [ -f "$TARGET2" ]; then
    if grep -B1 'namespace avmedia' "$TARGET2" | grep -q 'HAVE_FEATURE_AVMEDIA'; then
        echo "    Part 2 (View.hxx): already patched"
    else
        # Guard both:
        #   namespace avmedia { class PlayerListener; }
        #   rtl::Reference<avmedia::PlayerListener> mxDropMediaSizeListener;
        awk '
/^namespace avmedia \{ class PlayerListener;/ {
    print "#if HAVE_FEATURE_AVMEDIA"
    print $0
    print "#endif"
    next
}
/rtl::Reference<avmedia::PlayerListener> mxDropMediaSizeListener/ {
    print "#if HAVE_FEATURE_AVMEDIA"
    print $0
    print "#endif"
    next
}
{ print }
' "$TARGET2" > "$TARGET2.tmp" && mv "$TARGET2.tmp" "$TARGET2"

        if grep -B1 'namespace avmedia' "$TARGET2" | grep -q 'HAVE_FEATURE_AVMEDIA'; then
            echo "    Part 2 (View.hxx): patched"
        else
            echo "    ERROR: Part 2 (View.hxx) failed"
            exit 2
        fi
    fi
else
    echo "    Warning: View.hxx not found"
fi

echo "    Patch 024 complete"
