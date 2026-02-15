#!/bin/bash
# 020-fix-harfbuzz-meson-msvc-path.sh
# Normalizes compiler/linker paths for HarfBuzz meson on Windows.
#
# In MSYS/Cygwin + MSVC builds, gb_CC/gb_CXX may be POSIX-style paths
# (e.g. /c/PROGRA~1/.../cl.exe). Meson is executed via native Windows Python,
# which cannot spawn POSIX-style executable paths and fails with:
#   "Unknown compiler(s)" / "WinError 2"
#
# Also ensures HarfBuzz can resolve Graphite2 via pkg-config by providing
# graphite2.pc when only graphite2-uninstalled.pc is present.
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
        print "cross_pkg_config := $(if $(wildcard /mingw64/bin/pkgconf.exe),$(call cross_path_to_native,/mingw64/bin/pkgconf.exe),$(firstword $(PKG_CONFIG)))"
        print "cross_ar := $(call cross_path_to_native,$(AR))"
        print "cross_strip := $(call cross_path_to_native,$(STRIP))"
        print "# PKG_CONFIG_PATH for harfbuzz meson: use ; separator and Windows paths on WNT"
        print "hb_graphite_dir := $(if $(filter WNT,$(OS)),$(shell cygpath -m \"$(gb_UnpackedTarball_workdir)/graphite\"),$(gb_UnpackedTarball_workdir)/graphite)"
        print "hb_icu_dir := $(if $(filter WNT,$(OS)),$(shell cygpath -m \"$(gb_UnpackedTarball_workdir)/icu\"),$(gb_UnpackedTarball_workdir)/icu)"
        print "hb_pkg_sep := $(if $(filter WNT,$(OS)),;,:)"
        print "hb_pkg_config_path := $(if $(filter WNT,$(OS)),$(hb_graphite_dir)$(hb_pkg_sep)$(hb_icu_dir),${PKG_CONFIG_PATH}$(LIBO_PATH_SEPARATOR)$(gb_UnpackedTarball_workdir)/graphite$(if $(SYSTEM_ICU),,$(LIBO_PATH_SEPARATOR)$(gb_UnpackedTarball_workdir)/icu))"
        print "# Reconstruct MSVC INCLUDE from SOLARINC for meson cl.exe (needs stdio.h etc.)"
        print "# Converts -IC:/path1 -IC:/path2 to C:/path1;C:/path2"
        print "hb_msvc_include := $(patsubst -I%,%,$(subst $(WHITESPACE)-I,;,$(strip $(SOLARINC))))"
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

if ! grep -Fq 'graphite2-uninstalled.pc' "$TARGET"; then
    awk '
BEGIN { inserted=0; }
{
    if (!inserted && $0 ~ /^[[:space:]]*PKG_CONFIG_PATH="/) {
        print "\t\tif [ -f \"$(gb_UnpackedTarball_workdir)/graphite/graphite2-uninstalled.pc\" ] && [ ! -f \"$(gb_UnpackedTarball_workdir)/graphite/graphite2.pc\" ]; then cp \"$(gb_UnpackedTarball_workdir)/graphite/graphite2-uninstalled.pc\" \"$(gb_UnpackedTarball_workdir)/graphite/graphite2.pc\"; fi && \\"
        inserted=1
    }
    print $0
}
END {
    if (!inserted) {
        exit 2
    }
}
' "$TARGET" > "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"
fi

# Also copy icu-uc-uninstalled.pc -> icu-uc.pc so pkgconf can find it
# (same issue as graphite2: pkgconf on Windows does not resolve -uninstalled suffix)
if ! grep -Fq 'icu-uc-uninstalled.pc' "$TARGET"; then
    awk '
BEGIN { inserted=0; }
{
    if (!inserted && $0 ~ /^[[:space:]]*PKG_CONFIG_PATH="/) {
        print "\t\tif [ -f \"$(gb_UnpackedTarball_workdir)/icu/icu-uc-uninstalled.pc\" ] && [ ! -f \"$(gb_UnpackedTarball_workdir)/icu/icu-uc.pc\" ]; then cp \"$(gb_UnpackedTarball_workdir)/icu/icu-uc-uninstalled.pc\" \"$(gb_UnpackedTarball_workdir)/icu/icu-uc.pc\"; fi && \\"
        inserted=1
    }
    print $0
}
END {
    if (!inserted) {
        exit 2
    }
}
' "$TARGET" > "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"
fi

cat > "$TARGET.sed" <<'EOF'
s|^ar = '$(AR)'$|ar = '$(cross_ar)'|
s|^strip = '$(STRIP)'$|strip = '$(cross_strip)'|
EOF
sed -f "$TARGET.sed" "$TARGET" > "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"
rm -f "$TARGET.sed"

# Replace the PKG_CONFIG_PATH / PYTHONWARNINGS / $(MESON) setup block.
# export INCLUDE is set as a shell command (persists for meson setup AND meson compile).
# PKG_CONFIG_PATH and PYTHONWARNINGS remain as inline env vars for the env+meson command.
if ! grep -Fq 'export INCLUDE="$(hb_msvc_include)"' "$TARGET"; then
    awk '
{
    if ($0 ~ /^[[:space:]]*PKG_CONFIG_PATH=.*\\$/) {
        # Insert export INCLUDE before the PKG_CONFIG_PATH line
        print "\t\texport INCLUDE=\"$(hb_msvc_include)\" && \\"
        # Keep PKG_CONFIG_PATH line as-is
        print $0
        # Read PYTHONWARNINGS line
        getline
        print $0
        # Read $(MESON) setup line and replace with env-wrapped version
        getline
        print "\t\tenv -u CL -u _CL_ -u cl -u _cl_ -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS -u cflags -u cxxflags -u cppflags -u ldflags -u include CC=\"$(cross_cc_native)\" CXX=\"$(cross_cxx_native)\" PKG_CONFIG=\"$(cross_pkg_config)\" $(MESON) setup builddir \\"
        next
    }
    print $0
}
' "$TARGET" > "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"
fi

# On Windows, Meson invokes pkgconf.exe (MinGW native) which requires ';' as
# PKG_CONFIG_PATH separator. But LIBO_PATH_SEPARATOR is ':' (POSIX, from MSYS2
# configure), and the inherited ${PKG_CONFIG_PATH} also uses ':' with POSIX paths.
# The hb_pkg_config_path variable (set in the awk block above) handles this by
# using ';' separator and cygpath-converted Windows paths on WNT.
# Here we just need to replace the PKG_CONFIG_PATH= line to use the pre-built variable.
sed -i 's|PKG_CONFIG_PATH="${PKG_CONFIG_PATH}$(LIBO_PATH_SEPARATOR)$(gb_UnpackedTarball_workdir)/graphite$(if $(SYSTEM_ICU),,$(LIBO_PATH_SEPARATOR)$(gb_UnpackedTarball_workdir)/icu)"|PKG_CONFIG_PATH="$(hb_pkg_config_path)"|' "$TARGET"

echo "    Patch 020 complete"
