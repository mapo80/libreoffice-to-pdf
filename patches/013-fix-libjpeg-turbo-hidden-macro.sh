#!/bin/bash
# 013-fix-libjpeg-turbo-hidden-macro.sh
# In LO's vendored libjpeg-turbo config header, HIDDEN is only defined for GCC.
# With MSVC this leaves "HIDDEN" as a bare token, breaking declarations such as:
#   const unsigned char HIDDEN jpeg_nbits_table[65536]
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"
TARGET="$LO_SRC/external/libjpeg-turbo/jconfigint.h"

if [ ! -f "$TARGET" ]; then
    echo "    Skip (not found): $TARGET"
    exit 0
fi

if grep -q '^#define HIDDEN$' "$TARGET"; then
    echo "    libjpeg-turbo jconfigint.h already patched (skipping)"
    exit 0
fi

awk '
{
    print
    if ($0 ~ /^#define HIDDEN  __attribute__\(\(visibility\("hidden"\)\)\)$/) {
        print "#else"
        print "#define HIDDEN"
    }
}
' "$TARGET" > "$TARGET.tmp"
mv "$TARGET.tmp" "$TARGET"

echo "    Patched: external/libjpeg-turbo/jconfigint.h (fallback HIDDEN for non-GCC)"
