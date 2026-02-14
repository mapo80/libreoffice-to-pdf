#!/bin/bash
# 016-fix-nss-msvc-env.sh
# Harden NSS external build environment on Windows (MSYS2 + MSVC).
#
# Fixes:
# 1) Ensure NSS build target uses LibreOffice autoconf wrappers on MSC.
# 2) Keep existing LIB env as fallback when ILIB is empty/partial.
# 3) Clear leaked compiler flag env vars before invoking nss make.
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"
TARGET="$LO_SRC/external/nss/ExternalProject_nss.mk"

if [ ! -f "$TARGET" ]; then
    echo "    Skip (not found): $TARGET"
    exit 0
fi

if ! grep -Fq '$(eval $(call gb_ExternalProject_use_autoconf,nss,build))' "$TARGET"; then
    awk '
BEGIN { in_register=0; inserted=0 }
{
    print $0
    if ($0 ~ /^\$\(eval \$\(call gb_ExternalProject_register_targets,nss,\\$/) {
        in_register=1
        next
    }
    if (in_register && $0 ~ /^\)\)$/ && !inserted) {
        print ""
        print "$(eval $(call gb_ExternalProject_use_autoconf,nss,build))"
        inserted=1
        in_register=0
    }
}
END { if (!inserted) exit 2 }
' "$TARGET" > "$TARGET.tmp" || {
        rm -f "$TARGET.tmp"
        echo "    ERROR: could not patch register_targets block in $TARGET"
        exit 1
    }
    mv "$TARGET.tmp" "$TARGET"
    echo "    Enabled autoconf wrappers for NSS on MSC"
else
    echo "    Autoconf wrappers already enabled for NSS (skipping)"
fi

if grep -Fq 'LIB="$(if $(strip $(ILIB)),$(ILIB)$${LIB:+;$${LIB}},$${LIB})"' "$TARGET"; then
    echo "    NSS LIB fallback already patched (skipping)"
else
    sed 's/LIB="$(ILIB)"/LIB="$(if $(strip $(ILIB)),$(ILIB)$${LIB:+;$${LIB}},$${LIB})"/' \
        "$TARGET" > "$TARGET.tmp"
    mv "$TARGET.tmp" "$TARGET"
    echo "    Patched NSS LIB env to preserve existing LIB fallback"
fi

if grep -Fq 'CL= CFLAGS= CXXFLAGS= CPPFLAGS= LDFLAGS= $(MAKE) nss_build_all' "$TARGET"; then
    echo "    NSS make env cleanup already patched (skipping)"
else
    sed 's/$(MAKE) nss_build_all/CL= CFLAGS= CXXFLAGS= CPPFLAGS= LDFLAGS= $(MAKE) nss_build_all/' \
        "$TARGET" > "$TARGET.tmp"
    mv "$TARGET.tmp" "$TARGET"
    echo "    Patched NSS build to clear CL/CFLAGS/CXXFLAGS/CPPFLAGS/LDFLAGS"
fi
