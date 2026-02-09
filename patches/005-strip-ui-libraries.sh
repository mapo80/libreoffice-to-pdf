#!/bin/bash
# 005-strip-ui-libraries.sh
# Strips pure UI dialog libraries from application modules for headless builds.
#
# These are separate libraries containing ONLY dialogs, sidebars, and UI components.
# The core document processing logic remains in the main libraries (sw, sc, sd).
#
# Libraries stripped:
#   sw/Module_sw.mk:      Library_swui  (Writer dialogs)
#   sc/Module_sc.mk:      Library_scui  (Calc dialogs)
#   sd/Module_sd.mk:      Library_sdui  (Impress/Draw dialogs + presenter console)
#   desktop/Module_desktop.mk: Library_deploymentgui (extension GUI)
#                               UIConfig_deployment   (deployment UI config)
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"

PATCHED=0

# --- Helper function: wrap a target with $(if $(ENABLE_SLIMLO),,target) ---
# Handles both tab and space indentation (LO makefiles use inconsistent indentation)
wrap_target() {
    local FILE="$1"
    local TARGET="$2"
    local LABEL="$3"

    if grep -q 'ENABLE_SLIMLO' "$FILE"; then
        echo "    $LABEL already patched (skipping)"
        return 0
    fi

    # Match target with any leading whitespace (tabs or spaces)
    if grep -qE "^[[:space:]]+${TARGET}( |\\))" "$FILE"; then
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

# --- Writer: strip swui ---
SW_MODULE="$LO_SRC/sw/Module_sw.mk"
if [ -f "$SW_MODULE" ]; then
    wrap_target "$SW_MODULE" "Library_swui" "sw/Module_sw.mk"
else
    echo "    Warning: sw/Module_sw.mk not found"
fi

# --- Calc: strip scui ---
SC_MODULE="$LO_SRC/sc/Module_sc.mk"
if [ -f "$SC_MODULE" ]; then
    wrap_target "$SC_MODULE" "Library_scui" "sc/Module_sc.mk"
else
    echo "    Warning: sc/Module_sc.mk not found"
fi

# --- Impress/Draw: strip sdui ---
SD_MODULE="$LO_SRC/sd/Module_sd.mk"
if [ -f "$SD_MODULE" ]; then
    wrap_target "$SD_MODULE" "Library_sdui" "sd/Module_sd.mk"
else
    echo "    Warning: sd/Module_sd.mk not found"
fi

# --- Desktop: strip deploymentgui + UIConfig_deployment ---
DESKTOP_MODULE="$LO_SRC/desktop/Module_desktop.mk"
if [ -f "$DESKTOP_MODULE" ]; then
    if ! grep -q 'ENABLE_SLIMLO' "$DESKTOP_MODULE"; then
        wrap_target "$DESKTOP_MODULE" "Library_deploymentgui" "desktop/Module_desktop.mk"
        wrap_target "$DESKTOP_MODULE" "UIConfig_deployment" "desktop/Module_desktop.mk"
    else
        echo "    desktop/Module_desktop.mk already patched (skipping)"
    fi
else
    echo "    Warning: desktop/Module_desktop.mk not found"
fi

echo "    Patch 005 complete ($PATCHED targets wrapped)"
