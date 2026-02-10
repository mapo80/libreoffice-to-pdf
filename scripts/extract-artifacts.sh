#!/bin/bash
# extract-artifacts.sh — Extract only necessary files from LibreOffice instdir
# This reduces the output from ~300MB to the minimum needed for PDF conversion.
#
# LibreOffice instdir/ structure (after build):
#   program/        — libraries (.so/.dylib), executables, UNO registries, RC files
#   share/registry/ — XCD configuration files (required for bootstrap)
#   share/config/   — misc config (fontconfig, etc.)
#   share/filter/   — filter definitions (format detection)
#   share/palette/  — color palettes (may be needed for chart rendering)
#   share/fonts/    — bundled fonts (excluded with --without-fonts)
#   share/gallery/  — galleries (excluded with --without-galleries)
#   share/template/ — templates (excluded with --without-templates)
#
# With --enable-mergelibs=more, almost all code is in libmergedlo.so.
# Only URE libraries and some external dependencies remain separate.
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
# 6. Misc share data that may be needed for rendering
# -----------------------------------------------------------
echo "  Copying share data..."
# Fontconfig configuration
if [ -d "$INSTDIR/share/config" ]; then
    cp -a "$INSTDIR/share/config" "$OUTPUT_DIR/share/"
fi
# Color palettes (needed for chart/drawing color resolution)
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
# 7. Remove executables and UI-only libraries we don't need
# -----------------------------------------------------------
echo "  Removing unnecessary executables..."
for exe in soffice soffice.bin unopkg oosplash; do
    rm -f "$OUTPUT_DIR/program/$exe"
done

# Remove UI dialog libraries (not needed for headless PDF conversion)
echo "  Removing UI-only libraries..."
for uilib in libswuilo libscuilo libsduilo libdeploymentguilo; do
    rm -f "$OUTPUT_DIR/program/${uilib}.so"
    rm -f "$OUTPUT_DIR/program/${uilib}.dylib"
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
    CTOR_COUNT=$(readelf --dyn-syms "$MERGEDSO" 2>/dev/null | grep -c "get_implementation" || echo "0")
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
