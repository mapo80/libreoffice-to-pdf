#!/bin/bash
# 010-icu-data-filter.sh
# Enables ICU data filtering for minimal locale data (en-US only).
#
# Problem: LibreOffice's ICU build uses a pre-built icudt*.dat archive (30+ MB)
# containing locale data for ALL languages. We only need en-US for DOCX→PDF.
#
# ICU supports filtering via ICU_DATA_FILTER_FILE env var + Python databuilder,
# but LO's build prevents this in three ways:
#   1. Only extracts data/misc/icudata.rc from the ICU data zip (not source files)
#   2. Patches out Python (no-python.patch sets PYTHON=) so databuilder never runs
#   3. Pre-built .dat file in source/data/in/ overrides any filter
#
# Fix:
#   1. Extract data SOURCE files from ICU data zip (locales, brkitr, coll, etc.)
#      but NOT build system files (Makefile.in, pkgdataMakefile.in) which LO patches
#   2. Remove the no-python.patch so the databuilder can run
#   3. Delete the pre-built .dat file so ICU rebuilds from source
#
# Requires: ICU_DATA_FILTER_FILE env var set to point to a filter JSON file,
#           python3 available in PATH (already in our Docker deps stage).
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"

UNPACK_MK="$LO_SRC/external/icu/UnpackedTarball_icu.mk"

if [ ! -f "$UNPACK_MK" ]; then
    echo "    ERROR: $UNPACK_MK not found"
    exit 1
fi

# --- Step 0: Restore UnpackedTarball_icu.mk from git to ensure clean state ---
# Previous patch attempts may have left the file corrupted.
if [ -d "$LO_SRC/.git" ]; then
    git -C "$LO_SRC" checkout -- external/icu/UnpackedTarball_icu.mk 2>/dev/null || true
    echo "    Restored UnpackedTarball_icu.mk from git"
fi

# --- Step 1: Extract data SOURCE files from ICU data zip ---
# Original pre_action extracts only data/misc/icudata.rc.
# We change it to extract data source directories (locales, brkitr, coll, etc.)
# but EXCLUDE build system files (Makefile.in, pkgdataMakefile.in, etc.)
# which LO patches (icu4c-rpath.patch.1, icu4c-mkdir.patch.1) modify.
# Then delete the pre-built .dat so ICU rebuilds from source with the filter.

if grep -q 'data/misc/icudata.rc' "$UNPACK_MK"; then
    # Replace the unzip command to selectively extract data source directories
    # Use unzip -x to exclude build system files that LO patches target
    sed 's|unzip -q -d source -o $(gb_UnpackedTarget_TARFILE_LOCATION)/$(ICU_DATA_TARBALL) data/misc/icudata.rc|unzip -q -d source -o $(gb_UnpackedTarget_TARFILE_LOCATION)/$(ICU_DATA_TARBALL) -x data/Makefile.in data/pkgdataMakefile.in data/makedata.mak data/build.xml data/BUILDRULES.py \&\& rm -f source/data/in/*.dat|' \
        "$UNPACK_MK" > "$UNPACK_MK.tmp" && mv "$UNPACK_MK.tmp" "$UNPACK_MK"
    # Add the SlimLO marker comment (using sed with temp file for macOS compat)
    sed '/gb_UnpackedTarball_set_pre_action,icu/{
i\
# SlimLO: ICU data filter - extract data sources, exclude build files, remove pre-built .dat
}' "$UNPACK_MK" > "$UNPACK_MK.tmp" && mv "$UNPACK_MK.tmp" "$UNPACK_MK"
    echo "    Changed unzip to extract data sources (excluding build files) + remove pre-built .dat"
else
    echo "    WARNING: Could not find 'data/misc/icudata.rc' extraction line"
    echo "    ICU data zip extraction may already be modified"
fi

# --- Step 2: Remove no-python.patch from the patch list ---
# The no-python.patch sets PYTHON= in ICU's configure.ac, which prevents
# the Python databuilder from running. We need it to process ICU_DATA_FILTER_FILE.
if grep -q 'external/icu/no-python.patch' "$UNPACK_MK"; then
    sed '/external\/icu\/no-python\.patch/d' "$UNPACK_MK" > "$UNPACK_MK.tmp" && mv "$UNPACK_MK.tmp" "$UNPACK_MK"
    echo "    Removed no-python.patch from ICU patch list"
else
    echo "    no-python.patch already removed (skipping)"
fi

# Verify
if grep -q 'rm -f source/data/in' "$UNPACK_MK"; then
    echo "    Verified: selective data extraction + .dat removal in UnpackedTarball_icu.mk"
else
    echo "    ERROR: Failed to patch UnpackedTarball_icu.mk"
    exit 1
fi

if grep -q 'no-python.patch' "$UNPACK_MK"; then
    echo "    ERROR: Failed to remove no-python.patch"
    exit 1
else
    echo "    Verified: no-python.patch removed"
fi

# --- Step 3: Force ICU rebuild by removing cached workdir artifacts ---
# The cached workdir may have ICU built with pre-built data. Force re-unpack + rebuild.
rm -rf "$LO_SRC/workdir/UnpackedTarball/icu" 2>/dev/null || true
rm -f "$LO_SRC/workdir/UnpackedTarball/icu.done" 2>/dev/null || true
rm -rf "$LO_SRC/workdir/ExternalProject/icu" 2>/dev/null || true
echo "    Cleared cached ICU build artifacts"

echo "    Patch 010 complete"
