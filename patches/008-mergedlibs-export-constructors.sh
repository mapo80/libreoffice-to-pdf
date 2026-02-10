#!/bin/bash
# 008-mergedlibs-export-constructors.sh
# Exports UNO component constructor symbols from libmergedlo.so.
#
# With --enable-mergelibs, component .o files are linked into libmergedlo.so.
# Constructor symbols (e.g. *_get_implementation) are declared with
# SAL_DLLPUBLIC_EXPORT (visibility("default")) and should appear in .dynsym.
# We add a linker version script to reinforce/guarantee their export.
# v11: restore from git before patching to avoid corruption from previous attempts
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"

MERGED_MK="$LO_SRC/Library_merged.mk"
VERSION_MAP="$LO_SRC/solenv/gbuild/mergedlo_constructors.map"

if [ ! -f "$MERGED_MK" ]; then
    echo "    ERROR: $MERGED_MK not found"
    exit 1
fi

# --- Step 0: Restore Library_merged.mk from git to ensure clean state ---
# Previous patch attempts may have left the file corrupted.
# git checkout restores the original, then we apply our changes cleanly.
if [ -d "$LO_SRC/.git" ]; then
    git -C "$LO_SRC" checkout -- Library_merged.mk 2>/dev/null || true
    echo "    Restored Library_merged.mk from git"
fi

# --- Step 1: Always create/overwrite version script ---
cat > "$VERSION_MAP" << 'MAPEOF'
SLIMLO_CONSTRUCTORS {
    global:
        *_get_implementation;
        *_component_getFactory;
        libreofficekit_hook;
        libreofficekit_hook_2;
        lok_preinit;
        lok_preinit_2;
        lok_open_urandom;
};
MAPEOF
echo "    Created version map: $VERSION_MAP"

# --- Step 2: Add version script to Library_merged.mk ---
# Since we restored from git in step 0, the file is clean.
# Just add our block if not already present.
if ! grep -q 'mergedlo_constructors' "$MERGED_MK"; then
    TAB="$(printf '\t')"
    # Write the block to a temp file (avoids sed multi-line escaping issues)
    TMPBLOCK=$(mktemp)
    cat > "$TMPBLOCK" << BLOCKEOF

\$(eval \$(call gb_Library_add_ldflags,merged,\\
${TAB}-Wl\$(COMMA)--version-script=\$(SRCDIR)/solenv/gbuild/mergedlo_constructors.map \\
))
BLOCKEOF
    # Insert the block after the gb_Library_Library,merged line
    sed "/gb_Library_Library,merged/r $TMPBLOCK" "$MERGED_MK" > "$MERGED_MK.tmp" && mv "$MERGED_MK.tmp" "$MERGED_MK"
    rm -f "$TMPBLOCK"
    echo "    Added version script to Library_merged.mk"
fi

# Verify
if grep -q 'mergedlo_constructors' "$MERGED_MK"; then
    echo "    Verified: version script reference in Library_merged.mk"
    grep -A3 'gb_Library_add_ldflags,merged' "$MERGED_MK" | head -6
else
    echo "    ERROR: Failed to add version script to Library_merged.mk"
    exit 1
fi

echo "    Patch 008 complete"
