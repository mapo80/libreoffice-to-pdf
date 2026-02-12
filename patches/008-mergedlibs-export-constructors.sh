#!/bin/bash
# 008-mergedlibs-export-constructors.sh
# Exports UNO component constructor symbols from libmergedlo.so.
#
# With --enable-mergelibs, component .o files are linked into libmergedlo.so.
# Constructor symbols (e.g. *_get_implementation) are declared with
# SAL_DLLPUBLIC_EXPORT (visibility("default")) and should appear in .dynsym.
#
# --export-dynamic tells the linker to add ALL default-visibility symbols
# to .dynsym. With LTO (patch 009), this also prevents the LTO plugin
# from eliminating constructor symbols (they are marked as exported roots).
#
# NOTE: We cannot use a version script with "local: *;" because non-merged
# libraries (libcuilo.so, etc.) link against libmergedlo.so and need to
# resolve normal symbols (SfxTabPage, etc.) from its .dynsym.
# v15: --export-dynamic only (proven working in build #9)
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"

MERGED_MK="$LO_SRC/Library_merged.mk"

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

# --- Step 1: Add --export-dynamic to Library_merged.mk ---
# On macOS (ld64), default-visibility symbols are exported automatically.
# --export-dynamic is only needed on Linux (GNU ld) to preserve symbols in .dynsym.
case "$(uname -s)" in
    Darwin)
        echo "    macOS: skipping --export-dynamic (ld64 exports default-visibility symbols automatically)"
        ;;
    *)
        if ! grep -q 'export-dynamic' "$MERGED_MK"; then
            TAB="$(printf '\t')"
            TMPBLOCK=$(mktemp)
            cat > "$TMPBLOCK" << BLOCKEOF

# SlimLO: export all default-visibility symbols for UNO dlsym + non-merged lib linking
\$(eval \$(call gb_Library_add_ldflags,merged,\\
${TAB}-Wl\$(COMMA)--export-dynamic \\
))
BLOCKEOF
            # Insert the block after the gb_Library_Library,merged line
            sed "/gb_Library_Library,merged/r $TMPBLOCK" "$MERGED_MK" > "$MERGED_MK.tmp" && mv "$MERGED_MK.tmp" "$MERGED_MK"
            rm -f "$TMPBLOCK"
            echo "    Added --export-dynamic to Library_merged.mk"
        fi

        # Verify
        if grep -q 'export-dynamic' "$MERGED_MK"; then
            echo "    Verified: --export-dynamic in Library_merged.mk"
            grep -A4 'gb_Library_add_ldflags,merged' "$MERGED_MK" | head -6
        else
            echo "    ERROR: Failed to add --export-dynamic to Library_merged.mk"
            exit 1
        fi
        ;;
esac

echo "    Patch 008 complete"
