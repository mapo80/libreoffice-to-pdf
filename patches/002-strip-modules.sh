#!/bin/bash
# 002-strip-modules.sh
# Modifies RepositoryModule_host.mk to conditionally exclude non-essential modules
# when ENABLE_SLIMLO=TRUE.
#
# Strategy: wrap each removable module in $(if $(ENABLE_SLIMLO),,module \)
# This follows the same pattern as ENABLE_WASM_STRIP_* already used in this file.
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"

REPO_MODULE="$LO_SRC/RepositoryModule_host.mk"

# Always restore from upstream before applying SlimLO wrappers so updates to this
# script take effect on already-patched source trees.
git -C "$LO_SRC" checkout -- RepositoryModule_host.mk 2>/dev/null || true
echo "    Restored RepositoryModule_host.mk from git"

# Modules to remove for SlimLO builds.
# Each of these appears as a line like "	modulename \" in the main module list.
# We wrap them with: $(if $(ENABLE_SLIMLO),, modulename) \
MODULES_TO_STRIP=(
    # Keep app modules in clean builds: installer/package graph still expects
    # their deliverables (e.g. libsdlo/libsclo). Runtime slimming happens via
    # merged/install guards + extraction, not by breaking this dependency graph.
    "writerperfect"
    "hwpfilter"
    "xmlsecurity"

    # Database (leaf — reportdesign already guarded by DBCONNECTIVITY)
    "dbaccess"

    # UI integration (leaf modules only)
    # NOTE: Do NOT strip cui, avmedia, scripting, extensions, UnoControls —
    # they have reverse dependencies from kept modules (sfx2, svx, etc.)
    # Let configure flags (--disable-avmedia, --disable-scripting) handle them.
    "wizards"
    "sysui"

    # Extras (templates, galleries — leaf)
    "extras"

    # Java components (disabled by --with-java=no, safe to strip)
    "bean"
    "javaunohelper"
    "jurt"
    "jvmaccess"
    "jvmfwk"

    # NOTE: Do NOT strip build tools (codemaker, cpputools, idl, soltools) —
    # they produce executables (cppumaker, svidl, etc.) needed during build.
    # They don't affect runtime size (not installed to instdir/).
    "unodevtools"
    "readlicense_oo"

    # Test infrastructure (leaf)
    "test"
    "testtools"
    "smoketest"
    "unotest"

    # UNO tools / bindings (leaf)
    "remotebridges"
    "unoil"
    "ridljar"
    "net_ure"

    # Platform-specific (leaf)
    "embedserv"
    # Windows accessibility bridge (ATL/COM heavy, not needed for headless DOCX->PDF)
    "winaccessibility"
    # NOTE: apple_remote is needed on macOS (vclplug_osx links against AppleRemote).
    # Only strip on non-macOS platforms.
    "android"
    "cli_ure"
)

cp "$REPO_MODULE" "$REPO_MODULE.bak"

for mod in "${MODULES_TO_STRIP[@]}"; do
    # Skip comments
    [[ "$mod" =~ ^# ]] && continue

    # Match module in the file: tab + modulename + ' \' or tab + modulename (end)
    # Use printf for literal tab matching (portable across macOS/Linux)
    TAB="$(printf '\t')"
    if grep -q "^${TAB}${mod} " "$REPO_MODULE" || grep -q "^${TAB}${mod}$" "$REPO_MODULE"; then
        # Wrap with conditional: $(if $(ENABLE_SLIMLO),, modulename)
        # Use temp file for portability (macOS sed -i requires extension arg)
        sed "s|^${TAB}${mod} \\\\|${TAB}\$(if \$(ENABLE_SLIMLO),,${mod}) \\\\|" "$REPO_MODULE" > "$REPO_MODULE.tmp" && mv "$REPO_MODULE.tmp" "$REPO_MODULE"
        sed "s|^${TAB}${mod}\$|${TAB}\$(if \$(ENABLE_SLIMLO),,${mod})|" "$REPO_MODULE" > "$REPO_MODULE.tmp" && mv "$REPO_MODULE.tmp" "$REPO_MODULE"
        echo "    Wrapped: $mod"
    else
        echo "    Skip (not found or already guarded): $mod"
    fi
done

rm -f "$REPO_MODULE.bak"
echo "    Patch 002 complete"
