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

if grep -q 'ENABLE_SLIMLO' "$REPO_MODULE"; then
    echo "    RepositoryModule_host.mk already patched (skipping)"
    exit 0
fi

# Modules to remove for SlimLO builds.
# Each of these appears as a line like "	modulename \" in the main module list.
# We wrap them with: $(if $(ENABLE_SLIMLO),, modulename) \
MODULES_TO_STRIP=(
    # Database
    "dbaccess"
    "reportbuilder"
    # reportdesign is already guarded by DBCONNECTIVITY

    # UI and desktop integration
    "cui"
    # fpicker is already guarded by DESKTOP
    "wizards"
    "sysui"

    # Help, translations, extras
    # helpcontent2 is already guarded by HELP
    # dictionaries is already guarded by DICTIONARIES
    "extras"

    # Accessibility
    # winaccessibility is already guarded by WASM_STRIP_ACCESSIBILITY

    # Media and presentation
    "avmedia"
    # slideshow, animations are already guarded by WASM_STRIP_BASIC_DRAW_MATH_IMPRESS

    # Scripting and extensions
    # basctl is already guarded by WASM_STRIP_CALC
    "scripting"
    # librelogo is already guarded by LIBRELOGO
    "extensions"
    # swext is already guarded by WASM_STRIP_WRITER
    # sdext is already guarded by WASM_STRIP_BASIC_DRAW_MATH_IMPRESS

    # Legacy filters
    "lotuswordpro"
    "hwpfilter"
    "writerperfect"
    # starmath is already guarded by WASM_STRIP_BASIC_DRAW_MATH_IMPRESS

    # Java components
    "bean"
    "javaunohelper"
    "jurt"
    "jvmaccess"
    "jvmfwk"

    # Python
    # pyuno is already guarded by PYUNO

    # Installers
    # instsetoo_native, scp2, setup_native are already guarded by DESKTOP

    # Misc
    # icon-themes: not in the module list directly (handled differently)
    # onlineupdate: controlled by configure flag
    # opencl: already guarded by OPENCL

    # Solvers
    # nlpsolver is already guarded by NLPSOLVER
    # scaddins, sccomp are already guarded by WASM_STRIP_CALC

    # Development tools not needed at runtime
    "codemaker"
    "cpputools"
    "idl"
    "unodevtools"
    "soltools"
    "readlicense_oo"

    # Test infrastructure
    "test"
    "testtools"
    "smoketest"
    "unotest"
    # qadevOOo is already guarded by QADEVOOO
    # uitest is already guarded by PYUNO

    # UNO tools not needed
    "remotebridges"
    "UnoControls"
    "unoil"
    "ridljar"
    "net_ure"

    # Misc modules not needed for headless PDF
    "embedserv"
    "apple_remote"
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
