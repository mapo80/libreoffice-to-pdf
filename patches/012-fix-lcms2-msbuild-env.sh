#!/bin/bash
# 012-fix-lcms2-msbuild-env.sh
# For the MSVC external lcms2 project, clear CL/CFLAGS/CXXFLAGS env overrides
# before invoking MSBuild. This avoids inheriting GNU-style flags into CL task.
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"
TARGET="$LO_SRC/external/lcms2/ExternalProject_lcms2.mk"

if [ ! -f "$TARGET" ]; then
    echo "    Skip (not found): $TARGET"
    exit 0
fi

if grep -q 'CL= CFLAGS= CXXFLAGS= MSBuild.exe lcms2_DLL.vcxproj' "$TARGET"; then
    echo "    ExternalProject_lcms2.mk already patched (skipping)"
    exit 0
fi

sed 's/MSBuild\.exe lcms2_DLL\.vcxproj/CL= CFLAGS= CXXFLAGS= MSBuild.exe lcms2_DLL.vcxproj/' \
    "$TARGET" > "$TARGET.tmp"
mv "$TARGET.tmp" "$TARGET"

echo "    Patched: external/lcms2/ExternalProject_lcms2.mk (clear CL/CFLAGS/CXXFLAGS)"
