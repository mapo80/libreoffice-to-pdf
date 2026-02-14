#!/bin/bash
# 020-fix-harfbuzz-meson-msvc-path.sh
# Normalizes compiler/linker paths for HarfBuzz meson cross file on Windows.
#
# In MSYS/Cygwin + MSVC builds, gb_CC/gb_CXX may be POSIX-style paths
# (e.g. /c/PROGRA~1/.../cl.exe). Meson is executed via native Windows Python,
# which cannot spawn POSIX-style executable paths and fails with:
#   "Unknown compiler(s)" / "WinError 2"
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"
TARGET="$LO_SRC/external/harfbuzz/ExternalProject_harfbuzz.mk"

if [ ! -f "$TARGET" ]; then
    echo "    Warning: external/harfbuzz/ExternalProject_harfbuzz.mk not found"
    exit 0
fi

if grep -q 'cross_cc_path :=' "$TARGET"; then
    echo "    HarfBuzz meson path normalization already patched (skipping)"
    exit 0
fi

awk '
BEGIN { replaced=0; skip=0; }
{
    if ($0 ~ /^python_listify = / && replaced == 0) {
        print $0
        print "# Normalize POSIX compiler/linker paths for meson when running under Windows python"
        print "cross_cc_path := $(firstword $(gb_CC))"
        print "cross_cc_rest := $(wordlist 2,$(words $(gb_CC)),$(gb_CC))"
        print "cross_c = $(call python_listify,$(if $(filter WNT,$(OS)),$(if $(filter /%,$(cross_cc_path)),$(shell cygpath -m \"$(cross_cc_path)\") $(cross_cc_rest),$(gb_CC)),$(gb_CC)))"
        print "cross_cxx_path := $(firstword $(gb_CXX))"
        print "cross_cxx_rest := $(wordlist 2,$(words $(gb_CXX)),$(gb_CXX))"
        print "cross_cxx = $(call python_listify,$(if $(filter WNT,$(OS)),$(if $(filter /%,$(cross_cxx_path)),$(shell cygpath -m \"$(cross_cxx_path)\") $(cross_cxx_rest),$(gb_CXX)),$(gb_CXX)))"
        print "cross_ld_cmd := $(subst -fuse-ld=,,$(USE_LD))"
        print "cross_ld_path := $(firstword $(cross_ld_cmd))"
        print "cross_ld_rest := $(wordlist 2,$(words $(cross_ld_cmd)),$(cross_ld_cmd))"
        print "cross_ld := $(call python_listify,$(if $(filter WNT,$(OS)),$(if $(filter /%,$(cross_ld_path)),$(shell cygpath -m \"$(cross_ld_path)\") $(cross_ld_rest),$(cross_ld_cmd)),$(cross_ld_cmd)))"
        print "cross_ar := $(if $(filter WNT,$(OS)),$(if $(filter /%,$(AR)),$(shell cygpath -m \"$(AR)\"),$(AR)),$(AR))"
        print "cross_strip := $(if $(filter WNT,$(OS)),$(if $(filter /%,$(STRIP)),$(shell cygpath -m \"$(STRIP)\"),$(STRIP)),$(STRIP))"
        replaced=1
        skip=1
        next
    }

    if (skip == 1) {
        if ($0 ~ /^cross_ld := /) {
            skip=0
            next
        }
        if ($0 ~ /^cross_c = / || $0 ~ /^cross_cxx = /) {
            next
        }
        next
    }

    print $0
}
END {
    if (replaced == 0) {
        exit 2
    }
}
' "$TARGET" > "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"

sed -e "s|^ar = '\$(AR)'$|ar = '\$(cross_ar)'|" \
    -e "s|^strip = '\$(STRIP)'$|strip = '\$(cross_strip)'|" \
    "$TARGET" > "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"

echo "    Patch 020 complete"
