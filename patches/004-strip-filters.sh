#!/bin/bash
# 004-strip-filters.sh
# Strips non-essential export filters from filter/Module_filter.mk
# when ENABLE_SLIMLO=TRUE.
#
# We keep: pdffilter, msfilter, filterconfig, odfflatxml, graphicfilter,
#          storagefd, textfd, xmlfa, xmlfd, Configuration_filter
# We strip: svgfilter, t602filter, xsltdlg, xsltfilter, icg,
#           CustomTarget_svg, CustomTarget_docbook, Package_docbook,
#           Package_xhtml, Package_xslt, UIConfig_filter
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"

MODULE_FILTER="$LO_SRC/filter/Module_filter.mk"

if grep -q 'ENABLE_SLIMLO' "$MODULE_FILTER"; then
    echo "    filter/Module_filter.mk already patched (skipping)"
    exit 0
fi

cp "$MODULE_FILTER" "$MODULE_FILTER.bak"

# Targets to wrap with $(if $(ENABLE_SLIMLO),, target)
# These are libraries and targets not needed for OOXML → PDF conversion
TARGETS_TO_STRIP=(
    # SVG export — not needed for PDF output
    "CustomTarget_svg"
    "Library_svgfilter"

    # DocBook/XHTML/XSLT — not needed
    "CustomTarget_docbook"
    "Package_docbook"
    "Package_xhtml"
    "Package_xslt"
    "Library_xsltdlg"
    "Library_xsltfilter"

    # T602 legacy format — not needed
    "Library_t602filter"

    # ICG (Image Conversion Gateway) — not needed
    "Library_icg"

    # UI config — not needed for headless
    "UIConfig_filter"
)

TAB="$(printf '\t')"

for target in "${TARGETS_TO_STRIP[@]}"; do
    # Skip comments
    [[ "$target" =~ ^# ]] && continue

    # Match target in the file with various patterns:
    # 1) "    target \" (with trailing backslash)
    # 2) "    target)" (last entry before closing paren)
    # 3) "    target" (standalone)
    if grep -q "${TAB}${target} " "$MODULE_FILTER" || grep -q "${TAB}${target})" "$MODULE_FILTER" || grep -q "${TAB}${target}$" "$MODULE_FILTER"; then
        # Wrap with conditional: $(if $(ENABLE_SLIMLO),, target)
        # Handle "target \" pattern
        sed "s|${TAB}${target} \\\\|${TAB}\$(if \$(ENABLE_SLIMLO),,${target}) \\\\|" "$MODULE_FILTER" > "$MODULE_FILTER.tmp" && mv "$MODULE_FILTER.tmp" "$MODULE_FILTER"
        # Handle "target)" pattern (last entry before closing paren)
        sed "s|${TAB}${target})|${TAB}\$(if \$(ENABLE_SLIMLO),,${target}))|" "$MODULE_FILTER" > "$MODULE_FILTER.tmp" && mv "$MODULE_FILTER.tmp" "$MODULE_FILTER"
        # Handle "target" at end of line
        sed "s|${TAB}${target}$|${TAB}\$(if \$(ENABLE_SLIMLO),,${target})|" "$MODULE_FILTER" > "$MODULE_FILTER.tmp" && mv "$MODULE_FILTER.tmp" "$MODULE_FILTER"
        echo "    Wrapped: $target"
    else
        echo "    Skip (not found or already guarded): $target"
    fi
done

# Also strip the l10n and screenshot targets for SlimLO
# These are in separate gb_Module_add_l10n_targets and gb_Module_add_screenshot_targets blocks
# We can wrap the entire l10n block
if grep -q 'gb_Module_add_l10n_targets,filter' "$MODULE_FILTER"; then
    sed "s|^\$(eval \$(call gb_Module_add_l10n_targets,filter,|\$(if \$(ENABLE_SLIMLO),,\$(eval \$(call gb_Module_add_l10n_targets,filter,|" "$MODULE_FILTER" > "$MODULE_FILTER.tmp" && mv "$MODULE_FILTER.tmp" "$MODULE_FILTER"
    # Close the wrapping: add closing paren after the block
    sed "s|^	AllLangMoTarget_flt \\\\|	AllLangMoTarget_flt \\\\|" "$MODULE_FILTER" > "$MODULE_FILTER.tmp" && mv "$MODULE_FILTER.tmp" "$MODULE_FILTER"
    echo "    Note: l10n targets kept as-is (harmless to include)"
fi

rm -f "$MODULE_FILTER.bak"
echo "    Patch 004 complete"
