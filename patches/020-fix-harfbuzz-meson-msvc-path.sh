#!/bin/bash
# 020-fix-harfbuzz-meson-msvc-path.sh
# Normalizes compiler/linker paths for HarfBuzz meson on Windows.
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

awk '
BEGIN { replaced=0; skip=0; }
{
    if ($0 ~ /^python_listify = / && replaced == 0) {
        print $0
        print "# Normalize POSIX compiler/linker paths for meson when running under Windows python"
        print "# Convert /... paths to native Windows paths for Meson (python.exe)."
        print "cross_path_to_native = $(if $(filter /%,$(1)),$(shell cygpath -m \"$(1)\"),$(1))"
        print "cross_cc_path := $(firstword $(gb_CC))"
        print "cross_cc_native := $(call cross_path_to_native,$(cross_cc_path))"
        print "cross_c = $(call python_listify,$(cross_cc_native))"
        print "cross_cxx_path := $(firstword $(gb_CXX))"
        print "cross_cxx_native := $(call cross_path_to_native,$(cross_cxx_path))"
        print "cross_cxx = $(call python_listify,$(cross_cxx_native))"
        print "cross_ld_cmd := $(subst -fuse-ld=,,$(USE_LD))"
        print "cross_ld_path := $(firstword $(cross_ld_cmd))"
        print "cross_ld_rest := $(wordlist 2,$(words $(cross_ld_cmd)),$(cross_ld_cmd))"
        print "cross_ld_native := $(call cross_path_to_native,$(cross_ld_path)) $(cross_ld_rest)"
        print "cross_ld := $(call python_listify,$(cross_ld_native))"
        print "cross_ar := $(call cross_path_to_native,$(AR))"
        print "cross_strip := $(call cross_path_to_native,$(STRIP))"
        replaced=1
        skip=1
        next
    }

    if (skip == 1) {
        if ($0 ~ /^define gb_harfbuzz_cross_compile/) {
            skip=0
            print $0
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

cat > "$TARGET.sed" <<'EOF'
s|^ar = '$(AR)'$|ar = '$(cross_ar)'|
s|^strip = '$(STRIP)'$|strip = '$(cross_strip)'|
s|^\([[:space:]]*\)\$(MESON) setup builddir \\$|\1CL= _CL_= CFLAGS= CXXFLAGS= CPPFLAGS= LDFLAGS= CC="$(cross_cc_native)" CXX="$(cross_cxx_native)" $(MESON) setup builddir \\|
EOF
sed -f "$TARGET.sed" "$TARGET" > "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"
rm -f "$TARGET.sed"

echo "    Patch 020 complete"
