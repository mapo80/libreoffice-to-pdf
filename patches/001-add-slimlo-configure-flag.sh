#!/bin/bash
# 001-add-slimlo-configure-flag.sh
# Adds --enable-slimlo flag to configure.ac and wires it into config_host.mk.in
# This follows the exact same pattern as --enable-wasm-strip
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"

CONFIGURE="$LO_SRC/configure.ac"
CONFIG_HOST="$LO_SRC/config_host.mk.in"

# ---------------------------------------------------------------
# 1. Add AC_ARG_ENABLE(slimlo, ...) near the wasm-strip definition
# ---------------------------------------------------------------
if grep -q 'enable-slimlo' "$CONFIGURE"; then
    echo "    configure.ac already patched (skipping)"
else
    # Insert our AC_ARG_ENABLE right after the wasm-strip one
    sed -i.bak '/^AC_ARG_ENABLE(wasm-strip,/,/^,)/ {
        /^,)/ a\
\
AC_ARG_ENABLE(slimlo,\
    AS_HELP_STRING([--enable-slimlo],\
        [Build a minimal headless PDF conversion library (SlimLO). Strips UI, scripting, and non-essential modules.]),\
,)
    }' "$CONFIGURE"
    rm -f "$CONFIGURE.bak"
    echo "    Added AC_ARG_ENABLE(slimlo) to configure.ac"
fi

# ---------------------------------------------------------------
# 2. Add the SlimLO stripping block (before the wasm_strip block)
# ---------------------------------------------------------------
if grep -q 'enable_slimlo' "$CONFIGURE"; then
    echo "    SlimLO strip block already exists (skipping)"
else
    # Find the line "if test "$enable_wasm_strip" = "yes"; then"
    # and insert our block BEFORE it
    SLIMLO_BLOCK='# SlimLO: minimal headless PDF conversion build.\
# Disables everything not needed for OOXML -> PDF conversion.\
if test "$enable_slimlo" = "yes"; then\
    enable_avmedia=no\
    enable_libcmis=no\
    enable_coinmp=no\
    enable_cups=no\
    enable_database_connectivity=no\
    enable_dbus=no\
    enable_dconf=no\
    enable_extension_integration=no\
    enable_extensions=no\
    enable_extension_update=no\
    enable_gio=no\
    enable_gpgmepp=no\
    enable_ldap=no\
    enable_lotuswordpro=no\
    enable_lpsolve=no\
    enable_odk=no\
    enable_online_update=no\
    enable_opencl=no\
    enable_pdfimport=no\
    enable_randr=no\
    enable_report_builder=no\
    enable_scripting=no\
    enable_sdremote=no\
    enable_sdremote_bluetooth=no\
    enable_skia=no\
    enable_xmlhelp=no\
    enable_zxing=no\
    test_libepubgen=no\
    test_libcmis=no\
    with_galleries=no\
    with_gssapi=no\
    with_templates=no\
    with_x=no\
\
    ENABLE_SLIMLO=TRUE\
fi\
'

    # Insert before the wasm_strip block
    sed -i.bak "/^if test \"\$enable_wasm_strip\" = \"yes\"; then/i\\
$SLIMLO_BLOCK" "$CONFIGURE"
    rm -f "$CONFIGURE.bak"
    echo "    Added SlimLO strip block to configure.ac"
fi

# ---------------------------------------------------------------
# 3. Add AC_SUBST(ENABLE_SLIMLO) near the WASM ones
# ---------------------------------------------------------------
if grep -q 'AC_SUBST(ENABLE_SLIMLO)' "$CONFIGURE"; then
    echo "    AC_SUBST already present (skipping)"
else
    sed -i.bak '/^AC_SUBST(ENABLE_WASM_STRIP)$/a\
AC_SUBST(ENABLE_SLIMLO)' "$CONFIGURE"
    rm -f "$CONFIGURE.bak"
    echo "    Added AC_SUBST(ENABLE_SLIMLO) to configure.ac"
fi

# ---------------------------------------------------------------
# 4. Add ENABLE_SLIMLO to config_host.mk.in
# ---------------------------------------------------------------
if grep -q 'ENABLE_SLIMLO' "$CONFIG_HOST"; then
    echo "    config_host.mk.in already patched (skipping)"
else
    # Add after the ENABLE_WASM_STRIP_DBACCESS line
    sed -i.bak '/^export ENABLE_WASM_STRIP_DBACCESS/a\
export ENABLE_SLIMLO=@ENABLE_SLIMLO@' "$CONFIG_HOST"
    rm -f "$CONFIG_HOST.bak"
    echo "    Added ENABLE_SLIMLO to config_host.mk.in"
fi

echo "    Patch 001 complete"
