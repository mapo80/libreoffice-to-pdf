#!/bin/bash
# 005-strip-ui-libraries.sh
# Strips non-essential UI targets from application modules for headless builds.
#
# NOTE: We do NOT strip Library_swui, Library_scui, Library_sdui because they are
# NOT in the merged libs list and the component packaging system expects them.
# They get built as standalone .so files which are excluded at artifact extraction.
#
# We only strip targets that don't cause delivery/packaging issues:
#   sw/Module_sw.mk:      UIConfig_* targets (UI resource configs)
#   sc/Module_sc.mk:      UIConfig_* targets
#   sd/Module_sd.mk:      UIConfig_* targets
#   desktop/Module_desktop.mk: Library_deploymentgui, UIConfig_deployment
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"

PATCHED=0

# --- Helper function: wrap a target with $(if $(ENABLE_SLIMLO),,target) ---
# Handles both tab and space indentation (LO makefiles use inconsistent indentation)
wrap_target() {
    local FILE="$1"
    local TARGET="$2"
    local LABEL="$3"

    # Check if this specific target is already wrapped
    if grep -q "ENABLE_SLIMLO.*${TARGET}" "$FILE"; then
        echo "    $TARGET in $LABEL already patched (skipping)"
        return 0
    fi

    # Match target with any leading whitespace (tabs or spaces)
    if grep -qE "^[[:space:]]+${TARGET}( |\\\\|\\))" "$FILE"; then
        # Replace preserving original indentation
        # Handle "target \" pattern (with trailing backslash)
        sed -E "s|^([[:space:]]+)${TARGET} \\\\|\1\$(if \$(ENABLE_SLIMLO),,${TARGET}) \\\\|" "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"
        # Handle "target)" pattern (last entry before closing paren)
        sed -E "s|^([[:space:]]+)${TARGET}\)|\\1\$(if \$(ENABLE_SLIMLO),,${TARGET})|" "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"
        echo "    Wrapped: $TARGET in $LABEL"
        PATCHED=$((PATCHED + 1))
    else
        echo "    Skip (not found): $TARGET in $LABEL"
    fi
}

# --- Undo previous swui/scui/sdui stripping if present in cached source ---
# Previous versions of this patch stripped Library_swui/scui/sdui which caused
# delivery errors. Restore them if they were wrapped.
undo_wrap() {
    local FILE="$1"
    local TARGET="$2"

    if [ ! -f "$FILE" ]; then return; fi
    if grep -q "ENABLE_SLIMLO.*${TARGET}" "$FILE"; then
        # Restore: $(if $(ENABLE_SLIMLO),,Library_swui) → Library_swui
        sed -E "s|\\\$\\(if \\\$\\(ENABLE_SLIMLO\\),,${TARGET}\\)|${TARGET}|g" "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"
        echo "    Restored: $TARGET (removed old SLIMLO guard)"
    fi
}

undo_wrap "$LO_SRC/sw/Module_sw.mk" "Library_swui"
undo_wrap "$LO_SRC/sc/Module_sc.mk" "Library_scui"
undo_wrap "$LO_SRC/sd/Module_sd.mk" "Library_sdui"

# --- Desktop: strip deploymentgui + UIConfig_deployment ---
DESKTOP_MODULE="$LO_SRC/desktop/Module_desktop.mk"
if [ -f "$DESKTOP_MODULE" ]; then
    wrap_target "$DESKTOP_MODULE" "Library_deploymentgui" "desktop/Module_desktop.mk"
    wrap_target "$DESKTOP_MODULE" "UIConfig_deployment" "desktop/Module_desktop.mk"
else
    echo "    Warning: desktop/Module_desktop.mk not found"
fi

echo "    Patch 005 complete ($PATCHED targets wrapped)"
