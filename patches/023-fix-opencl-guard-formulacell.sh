#!/bin/bash
# 023-fix-opencl-guard-formulacell.sh
# Fixes missing HAVE_FEATURE_OPENCL guard in sc/source/core/data/formulacell.cxx.
#
# The upstream code has an #ifdef _WIN32 block that references openclwrapper::gpuEnv
# but does not check HAVE_FEATURE_OPENCL. When OpenCL is disabled (--disable-opencl),
# the header is not included and the symbol does not exist, causing:
#   error C2653: 'openclwrapper': is not a class or namespace name
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"
TARGET="$LO_SRC/sc/source/core/data/formulacell.cxx"

if [ ! -f "$TARGET" ]; then
    echo "    Warning: sc/source/core/data/formulacell.cxx not found"
    exit 0
fi

# Already patched? Check if HAVE_FEATURE_OPENCL appears near openclwrapper::gpuEnv
if grep -B2 'openclwrapper::gpuEnv' "$TARGET" | grep -q 'HAVE_FEATURE_OPENCL'; then
    echo "    Patch 023 already applied (HAVE_FEATURE_OPENCL guard present)"
    exit 0
fi

# The problematic pattern is:
#   #ifdef _WIN32
#       // Heuristic: ... OpenCL ...
#       if (openclwrapper::gpuEnv.mbNeedsTDRAvoidance)
#           nMaxGroupLength = 1000;
#   #endif
#
# Wrap the openclwrapper usage with HAVE_FEATURE_OPENCL inside the _WIN32 block.
awk '
/openclwrapper::gpuEnv/ {
    print "#if HAVE_FEATURE_OPENCL"
    print $0
    getline
    print $0
    print "#endif"
    next
}
{ print }
' "$TARGET" > "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"

# Verify
if grep -q 'HAVE_FEATURE_OPENCL' "$TARGET"; then
    echo "    Patch 023 complete"
else
    echo "    ERROR: Patch 023 failed — guard not inserted"
    exit 2
fi
