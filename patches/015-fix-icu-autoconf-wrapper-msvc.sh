#!/bin/bash
# 015-fix-icu-autoconf-wrapper-msvc.sh
# Ensure ICU external project uses LibreOffice autoconf wrappers on MSC.
# This aligns ICU configure with other autoconf projects in MSYS2+MSVC builds.
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"
TARGET="$LO_SRC/external/icu/ExternalProject_icu.mk"

if [ ! -f "$TARGET" ]; then
    echo "    Skip (not found): $TARGET"
    exit 0
fi

if grep -Fq '$(eval $(call gb_ExternalProject_use_autoconf,icu,build))' "$TARGET"; then
    echo "    ExternalProject_icu.mk already patched (autoconf wrapper enabled, skipping)"
    exit 0
fi

awk '
BEGIN { in_register=0; inserted=0 }
{
    print $0
    if ($0 ~ /^\$\(eval \$\(call gb_ExternalProject_register_targets,icu,\\$/) {
        in_register=1
        next
    }
    if (in_register && $0 ~ /^\)\)$/ && !inserted) {
        print ""
        print "$(eval $(call gb_ExternalProject_use_autoconf,icu,build))"
        inserted=1
        in_register=0
    }
}
END {
    if (!inserted) {
        exit 2
    }
}
' "$TARGET" > "$TARGET.tmp" || {
    rm -f "$TARGET.tmp"
    echo "    ERROR: could not locate register_targets block in $TARGET"
    exit 1
}

mv "$TARGET.tmp" "$TARGET"
echo "    Patched: external/icu/ExternalProject_icu.mk (enable gb_ExternalProject_use_autoconf for ICU)"
