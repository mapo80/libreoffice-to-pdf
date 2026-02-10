#!/bin/bash
# 007-fix-swui-db-conditionals.sh
# Fixes link errors in Library_swui when DBCONNECTIVITY is disabled.
#
# Problem: sw/source/ui/fldui/flddb.cxx and changedb.cxx are listed
# unconditionally in Library_swui.mk but reference SwDBTreeList which
# is only compiled when DBCONNECTIVITY is in BUILD_TYPE.
#
# Fix: Move flddb and changedb into the DBCONNECTIVITY conditional block.
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"

SWUI_MK="$LO_SRC/sw/Library_swui.mk"

if [ ! -f "$SWUI_MK" ]; then
    echo "    ERROR: $SWUI_MK not found"
    exit 1
fi

# Check if already patched
if grep -q 'flddb.*DBCONNECTIVITY\|# SlimLO: moved flddb' "$SWUI_MK"; then
    echo "    Library_swui.mk already patched (skipping)"
    exit 0
fi

# Strategy: Remove flddb and changedb from the unconditional section,
# then add them to the DBCONNECTIVITY conditional section.

# 1. Remove flddb and changedb from the unconditional list
#    They appear as lines like: "    sw/source/ui/fldui/flddb \"
sed -E '/sw\/source\/ui\/fldui\/flddb /d' "$SWUI_MK" > "$SWUI_MK.tmp" && mv "$SWUI_MK.tmp" "$SWUI_MK"
sed -E '/sw\/source\/ui\/fldui\/changedb /d' "$SWUI_MK" > "$SWUI_MK.tmp" && mv "$SWUI_MK.tmp" "$SWUI_MK"

# Also handle if they're at end of line (no trailing backslash)
sed -E '/sw\/source\/ui\/fldui\/flddb$/d' "$SWUI_MK" > "$SWUI_MK.tmp" && mv "$SWUI_MK.tmp" "$SWUI_MK"
sed -E '/sw\/source\/ui\/fldui\/changedb$/d' "$SWUI_MK" > "$SWUI_MK.tmp" && mv "$SWUI_MK.tmp" "$SWUI_MK"

echo "    Removed flddb and changedb from unconditional section"

# 2. Add them to the DBCONNECTIVITY conditional section
#    Find the DBCONNECTIVITY block and append before its closing "))"
#    The block looks like:
#      ifneq (,$(filter DBCONNECTIVITY,$(BUILD_TYPE)))
#      $(eval $(call gb_Library_add_exception_objects,swui,\
#          sw/source/ui/dbui/... \
#          ...
#      ))
#      endif
#
#    We insert our files just before the last entry in the DBCONNECTIVITY block.
if grep -q 'filter DBCONNECTIVITY.*BUILD_TYPE' "$SWUI_MK"; then
    # Find the last source file in the DBCONNECTIVITY block and add after it
    # The last file before "))" in that block is typically selectdbtabledialog
    sed '/sw\/source\/ui\/dbui\/selectdbtabledialog/a\
    sw/source/ui/fldui/flddb \\\
    sw/source/ui/fldui/changedb \\' "$SWUI_MK" > "$SWUI_MK.tmp" && mv "$SWUI_MK.tmp" "$SWUI_MK"
    echo "    Added flddb and changedb to DBCONNECTIVITY conditional block"
else
    echo "    WARNING: DBCONNECTIVITY block not found in Library_swui.mk"
    echo "    flddb and changedb have been removed but not re-added"
fi

echo "    Patch 007 complete"
