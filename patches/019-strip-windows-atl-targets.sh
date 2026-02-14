#!/bin/bash
# 019-strip-windows-atl-targets.sh
# Excludes ATL-dependent Windows targets from extensions module for SlimLO.
#
# In GitHub Actions Windows runners, ATL headers/libs may be unavailable
# (e.g. missing atlmfc component), causing errors like:
#   fatal error C1083: Cannot open include file: 'atlbase.h'
# For headless DOCX->PDF SlimLO builds these targets are not required.
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"
EXT_MODULE="$LO_SRC/extensions/Module_extensions.mk"
REPO_MODULE="$LO_SRC/RepositoryModule_host.mk"

if [ ! -f "$EXT_MODULE" ]; then
    echo "    Warning: extensions/Module_extensions.mk not found"
    exit 0
fi

PATCHED=0

wrap_target() {
    local FILE="$1"
    local TARGET="$2"

    if grep -q "ENABLE_SLIMLO.*${TARGET}" "$FILE"; then
        echo "    $TARGET already patched (skipping)"
        return 0
    fi

    if grep -qE "^[[:space:]]+${TARGET}( |\\\\|\\))" "$FILE"; then
        sed -E "s|^([[:space:]]+)${TARGET} \\\\|\\1\$(if \$(ENABLE_SLIMLO),,${TARGET}) \\\\|" "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"
        sed -E "s|^([[:space:]]+)${TARGET}\)|\\1\$(if \$(ENABLE_SLIMLO),,${TARGET})|" "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"
        echo "    Wrapped: $TARGET"
        PATCHED=$((PATCHED + 1))
    else
        echo "    Skip (not found): $TARGET"
    fi
}

wrap_target "$EXT_MODULE" "WinResTarget_activex"
wrap_target "$EXT_MODULE" "Library_so_activex"
wrap_target "$EXT_MODULE" "CustomTarget_so_activex_idl"
wrap_target "$EXT_MODULE" "Library_oleautobridge"

echo "    Patch 019 complete ($PATCHED targets wrapped)"

if [ -f "$REPO_MODULE" ]; then
    if grep -q "ENABLE_SLIMLO.*winaccessibility" "$REPO_MODULE"; then
        echo "    winaccessibility module already patched (skipping)"
    elif grep -qE "^[[:space:]]+winaccessibility( |\\\\|$)" "$REPO_MODULE"; then
        sed -E "s|^([[:space:]]+)winaccessibility \\\\|\\1\$(if \$(ENABLE_SLIMLO),,winaccessibility) \\\\|" "$REPO_MODULE" > "$REPO_MODULE.tmp" && mv "$REPO_MODULE.tmp" "$REPO_MODULE"
        sed -E "s|^([[:space:]]+)winaccessibility$|\\1\$(if \$(ENABLE_SLIMLO),,winaccessibility)|" "$REPO_MODULE" > "$REPO_MODULE.tmp" && mv "$REPO_MODULE.tmp" "$REPO_MODULE"
        echo "    Wrapped module: winaccessibility"
    else
        echo "    Skip module (not found): winaccessibility"
    fi
else
    echo "    Warning: RepositoryModule_host.mk not found"
fi
