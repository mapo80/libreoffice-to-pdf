#!/bin/bash
# 006-fix-mergelibs-conditionals.sh
# Fixes unconditional library entries in the BASE section of pre_MergedLibsList.mk
# that conflict with features disabled by SlimLO configure flags.
#
# With --enable-mergelibs (not =more), only the BASE section is used.
# Libraries in the BASE list that are conditional within their modules or
# in Repository.mk but unconditional in the merged list cause build failures.
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"

MERGED="$LO_SRC/solenv/gbuild/extensions/pre_MergedLibsList.mk"

if [ ! -f "$MERGED" ]; then
    echo "    ERROR: $MERGED not found"
    exit 1
fi

# Helper: wrap with $(call gb_Helper_optional,FLAG,lib)
wrap_optional() {
    local FLAG="$1" LIB="$2"
    if grep -q "gb_Helper_optional.*${FLAG}.*${LIB}\|gb_Helper_optionals_or.*${FLAG}.*${LIB}" "$MERGED"; then
        echo "    $LIB already patched (skipping)"
        return
    fi
    if grep -qE "^[[:space:]]+${LIB} \\\\" "$MERGED"; then
        sed -E "s|^([[:space:]]+)${LIB} (\\\\)|\1\$(call gb_Helper_optional,${FLAG},${LIB}) \2|" \
            "$MERGED" > "$MERGED.tmp" && mv "$MERGED.tmp" "$MERGED"
        echo "    Wrapped: $LIB (optional on $FLAG)"
    else
        echo "    Skip (not found): $LIB"
    fi
}

# Helper: wrap with $(if $(FLAG),,lib) — exclude when FLAG is set
wrap_exclude() {
    local FLAG="$1" LIB="$2"
    if grep -q "ENABLE_SLIMLO.*${LIB}" "$MERGED"; then
        echo "    $LIB already patched (skipping)"
        return
    fi
    if grep -qE "^[[:space:]]+${LIB} \\\\" "$MERGED"; then
        sed -E "s|^([[:space:]]+)${LIB} (\\\\)|\1\$(if \$(${FLAG}),,${LIB}) \2|" \
            "$MERGED" > "$MERGED.tmp" && mv "$MERGED.tmp" "$MERGED"
        echo "    Wrapped: $LIB (exclude when $FLAG)"
    else
        echo "    Skip (not found): $LIB"
    fi
}

# --- BASE section fixes ---

# SCRIPTING: vbaevents, vbahelper are unconditional in merged list
# but conditional on SCRIPTING in Repository.mk
echo "    --- SCRIPTING guards ---"
wrap_optional SCRIPTING vbaevents
wrap_optional SCRIPTING vbahelper

# HELPTOOLS/XMLHELP: helplinker has DESKTOP guard in merged list
# but HELPTOOLS/XMLHELP guard in Repository.mk — mismatch
echo "    --- HELPTOOLS/XMLHELP guard ---"
if grep -q 'gb_Helper_optionals_or,HELPTOOLS XMLHELP,helplinker' "$MERGED"; then
    echo "    helplinker already patched (skipping)"
else
    sed 's/\$(call gb_Helper_optional,DESKTOP,helplinker)/$(call gb_Helper_optionals_or,HELPTOOLS XMLHELP,helplinker)/' \
        "$MERGED" > "$MERGED.tmp" && mv "$MERGED.tmp" "$MERGED"
    echo "    Fixed helplinker (DESKTOP -> HELPTOOLS/XMLHELP)"
fi

# DESKTOP: fps_office is unconditional in merged list but fpicker module
# is conditional on DESKTOP in RepositoryModule_host.mk
echo "    --- DESKTOP guards ---"
wrap_optional DESKTOP fps_office

# DBCONNECTIVITY: frm (forms) is unconditional in merged list but
# forms module is conditional on DBCONNECTIVITY
echo "    --- DBCONNECTIVITY guards ---"
wrap_optional DBCONNECTIVITY frm

# ENABLE_SLIMLO: filter libraries stripped by patch 004
echo "    --- ENABLE_SLIMLO guards (filter libs from patch 004) ---"
wrap_exclude ENABLE_SLIMLO icg
wrap_exclude ENABLE_SLIMLO xsltdlg
wrap_exclude ENABLE_SLIMLO xsltfilter

echo "    Patch 006 complete"
