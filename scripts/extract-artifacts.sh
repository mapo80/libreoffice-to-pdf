#!/bin/bash
# extract-artifacts.sh — Extract only necessary files from LibreOffice instdir
# Super Slim: only DOCX→PDF conversion, no Calc/Impress/Math.
#
# With --enable-mergelibs, most code is in libmergedlo.so.
# Stub .so files (21-byte "invalid - merged lib") are kept — UNO needs them.
# Only Writer + core libraries are kept; Calc/Impress/Math/VBA removed.
# soffice.cfg/ pruned to Writer-only (removes ~25 MB of UI toolbar/menu XML).
set -euo pipefail

INSTDIR="${1:?Usage: extract-artifacts.sh <instdir> <output-dir>}"
OUTPUT_DIR="${2:?Usage: extract-artifacts.sh <instdir> <output-dir>}"

if [ ! -d "$INSTDIR" ]; then
    echo "ERROR: instdir not found: $INSTDIR"
    exit 1
fi

echo "Extracting artifacts from $INSTDIR to $OUTPUT_DIR..."

# Clean output directory
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"/program

# -----------------------------------------------------------
# 1. Copy ALL shared libraries from program/
#    With mergelibs=more, this is mostly libmergedlo.so + URE + externals.
#    Copying all .so/.dylib is safer than cherry-picking.
# -----------------------------------------------------------
echo "  Copying libraries..."
find "$INSTDIR/program" \( -name "*.so" -o -name "*.so.*" -o -name "*.dylib" \) \
    -exec cp -a {} "$OUTPUT_DIR/program/" \;

# -----------------------------------------------------------
# 2. UNO type and service registries (required for component loading)
# -----------------------------------------------------------
echo "  Copying UNO registries..."
cp -a "$INSTDIR"/program/types.rdb "$OUTPUT_DIR/program/" 2>/dev/null || true
cp -a "$INSTDIR"/program/services.rdb "$OUTPUT_DIR/program/" 2>/dev/null || true
# Some builds use subdirectories for split registries
if [ -d "$INSTDIR/program/types" ]; then
    cp -a "$INSTDIR/program/types" "$OUTPUT_DIR/program/"
fi
if [ -d "$INSTDIR/program/services" ]; then
    cp -a "$INSTDIR/program/services" "$OUTPUT_DIR/program/"
fi

# -----------------------------------------------------------
# 3. Bootstrap RC files (required for LOKit initialization)
# -----------------------------------------------------------
echo "  Copying bootstrap configuration..."
for rc in sofficerc soffice.ini fundamentalrc fundamental.ini versionrc version.ini \
          bootstraprc bootstrap.ini unorc uno.ini lounorc loaborc saborc; do
    cp -a "$INSTDIR/program/$rc" "$OUTPUT_DIR/program/" 2>/dev/null || true
done

# -----------------------------------------------------------
# 4. Configuration (XCD files — required for UNO bootstrap)
# -----------------------------------------------------------
echo "  Copying XCD configuration..."
if [ -d "$INSTDIR/share/registry" ]; then
    mkdir -p "$OUTPUT_DIR/share/registry"
    cp -a "$INSTDIR"/share/registry/*.xcd "$OUTPUT_DIR/share/registry/" 2>/dev/null || true
fi

# -----------------------------------------------------------
# 5. Filter definitions (required for format detection/export)
# -----------------------------------------------------------
echo "  Copying filter definitions..."
if [ -d "$INSTDIR/share/filter" ]; then
    cp -a "$INSTDIR/share/filter" "$OUTPUT_DIR/share/"
fi

# -----------------------------------------------------------
# 6. Misc share data
# -----------------------------------------------------------
echo "  Copying share data..."
# Config directory — copy all, then prune non-essential soffice.cfg modules
if [ -d "$INSTDIR/share/config" ]; then
    cp -a "$INSTDIR/share/config" "$OUTPUT_DIR/share/"
    # Remove soffice.cfg modules not needed for DOCX→PDF (saves ~25 MB)
    for mod in scalc simpress sdraw schart smath sglobal BasicIDE \
               swxform swform swreport sweb sabpilot scanner StartModule; do
        rm -rf "$OUTPUT_DIR/share/config/soffice.cfg/modules/$mod"
    done
    # Remove CUI dialogs config (4 MB — UI only)
    rm -rf "$OUTPUT_DIR/share/config/soffice.cfg/cui"
    # Remove Impress config
    rm -rf "$OUTPUT_DIR/share/config/soffice.cfg/simpress"
    # Remove swriter UI dialog files (8 MB — headless never shows dialogs)
    rm -rf "$OUTPUT_DIR/share/config/soffice.cfg/modules/swriter/ui"
    # Remove toolbar/menubar/popupmenu/statusbar XML (UI only)
    rm -rf "$OUTPUT_DIR/share/config/soffice.cfg/modules/swriter/toolbar"
    rm -rf "$OUTPUT_DIR/share/config/soffice.cfg/modules/swriter/menubar"
    rm -rf "$OUTPUT_DIR/share/config/soffice.cfg/modules/swriter/popupmenu"
    rm -rf "$OUTPUT_DIR/share/config/soffice.cfg/modules/swriter/statusbar"
fi
# Color palettes
if [ -d "$INSTDIR/share/palette" ]; then
    cp -a "$INSTDIR/share/palette" "$OUTPUT_DIR/share/"
fi
# Fonts (only present if --without-fonts was NOT used)
if [ -d "$INSTDIR/share/fonts" ]; then
    cp -a "$INSTDIR/share/fonts" "$OUTPUT_DIR/share/"
fi
# Presets directory (required for user profile initialization)
# LOKit's userinstall::create() copies BRAND_BASE_DIR/presets to user profile.
# LIBO_SHARE_PRESETS_FOLDER="presets" is relative to install root, NOT share/.
# An empty directory satisfies the check; missing directory causes fatal error.
if [ -d "$INSTDIR/presets" ]; then
    cp -a "$INSTDIR/presets" "$OUTPUT_DIR/"
else
    mkdir -p "$OUTPUT_DIR/presets"
fi

# -----------------------------------------------------------
# 7. Remove executables we don't need
# -----------------------------------------------------------
echo "  Removing unnecessary executables..."
for exe in soffice soffice.bin unopkg oosplash; do
    rm -f "$OUTPUT_DIR/program/$exe"
done

# -----------------------------------------------------------
# 7a. Stub .so files ("invalid - merged lib" placeholders)
#     These are 21-byte text files created by --enable-mergelibs.
#     UNO component loader checks for file existence before falling
#     back to the merged lib, so we keep them (~1.7 KB total).
# -----------------------------------------------------------

# -----------------------------------------------------------
# 7b. Remove libraries not needed for DOCX→PDF conversion
# -----------------------------------------------------------
echo "  Removing non-essential libraries..."
for lib in \
    libsclo libsdlo libscfiltlo libslideshowlo libscdlo libsddlo \
    libPresentationMinimizerlo \
    libcuilo \
    libswuilo libscuilo libsduilo libdeploymentguilo \
    libvbaobjlo libvbaswobjlo \
    liblocaledata_others liblocaledata_euro liblocaledata_es \
    libsmlo libsmdlo \
    libbiblo \
    libanalysislo libdatelo libpricinglo libsolverlo \
    libucpdav1 libcmdmaillo \
    libmigrationoo2lo libmigrationoo3lo \
    libabplo libLanguageToollo libscnlo \
    libtextconversiondlgslo libanimcorelo libicglo \
    libmsformslo libscriptframe libdlgprovlo libunopkgapp \
    libprotocolhandlerlo libnamingservicelo libproxyfaclo liblog_uno_uno \
    libxmlsecurity \
; do
    rm -f "$OUTPUT_DIR/program/${lib}.so"
    rm -f "$OUTPUT_DIR/program/${lib}.dylib"
done

# -----------------------------------------------------------
# 7b2. Remove external import libraries for formats we don't need
#      (DOCX-only: no Mac Word, Keynote, StarOffice, Works, etc.)
# -----------------------------------------------------------
echo "  Removing non-essential external import libraries..."
for extlib in \
    "libmwaw-0.3-lo.so*" \
    "libetonyek-0.1-lo.so*" \
    "libstaroffice-0.0-lo.so*" \
    "libwps-0.4-lo.so*" \
    "liborcus-0.20.so*" \
    "liborcus-parser-0.20.so*" \
    "libodfgen-0.1-lo.so*" \
    "libwpd-0.10-lo.so*" \
    "libwpg-0.3-lo.so*" \
    "librevenge-0.0-lo.so*" \
    "libexslt.so*" \
; do
    rm -f "$OUTPUT_DIR/program/"$extlib
done
# Remove GDB helper scripts
rm -f "$OUTPUT_DIR/program/"*.py

# -----------------------------------------------------------
# 7c. Remove XCD config for unused modules
# -----------------------------------------------------------
echo "  Removing unused XCD files..."
for xcd in math base xsltfilter ogltrans ctlseqcheck cjk impress calc draw; do
    rm -f "$OUTPUT_DIR/share/registry/${xcd}.xcd"
done

# -----------------------------------------------------------
# 8. Strip binaries to reduce size
# -----------------------------------------------------------
echo "  Stripping binaries..."
find "$OUTPUT_DIR/program" -name "*.so" -exec strip --strip-unneeded {} \; 2>/dev/null || true
find "$OUTPUT_DIR/program" -name "*.so.*" -exec strip --strip-unneeded {} \; 2>/dev/null || true
find "$OUTPUT_DIR/program" -name "*.dylib" -exec strip -x {} \; 2>/dev/null || true

# -----------------------------------------------------------
# 9. Verify constructor symbols survived stripping
# -----------------------------------------------------------
echo "  Verifying constructor symbol visibility..."
MERGEDSO="$OUTPUT_DIR/program/libmergedlo.so"
if [ -f "$MERGEDSO" ]; then
    CTOR_COUNT=$(readelf --dyn-syms -W "$MERGEDSO" 2>/dev/null | grep -c "get_implementation" || echo "0")
    echo "  Constructor symbols in .dynsym: $CTOR_COUNT"
    if [ "$CTOR_COUNT" -eq 0 ] 2>/dev/null; then
        echo "  WARNING: No constructor symbols found in libmergedlo.so .dynsym!"
        echo "  UNO component loading will likely fail at runtime."
    fi
fi

# -----------------------------------------------------------
# Report
# -----------------------------------------------------------
echo ""
echo "=== Artifact Summary ==="
LIB_COUNT=$(find "$OUTPUT_DIR/program" \( -name "*.so" -o -name "*.so.*" -o -name "*.dylib" \) | wc -l)
echo "Libraries: $LIB_COUNT"
echo ""
echo "Total size:"
du -sh "$OUTPUT_DIR"
echo ""
echo "Breakdown:"
du -sh "$OUTPUT_DIR"/* 2>/dev/null || true
