#!/bin/bash
# 018-fix-icu-windows-configure-flags.sh
# Harden ICU configure flags on Windows (MSYS2 + MSVC):
# - disable samples/layout/extras to avoid non-essential tool builds
#   that are fragile with cygwin+cl argument quoting.
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"
TARGET="$LO_SRC/external/icu/ExternalProject_icu.mk"

if [ ! -f "$TARGET" ]; then
    echo "    Skip (not found): $TARGET"
    exit 0
fi

if grep -Fq -- '--disable-layout --disable-samples --disable-extras' "$TARGET"; then
    echo "    ICU Windows configure flags already patched (skipping)"
    exit 0
fi

awk '
BEGIN { in_wnt=0; done=0 }
{
    if ($0 ~ /^ifeq \(\$\(OS\),WNT\)/) {
        in_wnt=1
    } else if ($0 ~ /^else # \$\(OS\)/) {
        in_wnt=0
    }

    print $0

    if (in_wnt && !done && $0 ~ /\$\(if \$\(MSVC_USE_DEBUG_RUNTIME\),--enable-debug --disable-release\)/) {
        print "\t\t\t--disable-layout --disable-samples --disable-extras \\"
        done=1
    }
}
END {
    if (!done) exit 2
}
' "$TARGET" > "$TARGET.tmp" || {
    rm -f "$TARGET.tmp"
    echo "    ERROR: could not inject ICU Windows configure flags into $TARGET"
    exit 1
}

mv "$TARGET.tmp" "$TARGET"
echo "    Patched: external/icu/ExternalProject_icu.mk (add --disable-layout --disable-samples --disable-extras on WNT)"
