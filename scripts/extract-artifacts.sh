#!/bin/bash
# extract-artifacts.sh — Extract only necessary files from LibreOffice instdir
# This reduces the output from ~300MB to the minimum needed for PDF conversion.
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
mkdir -p "$OUTPUT_DIR"/{lib,share,program}

# -----------------------------------------------------------
# Core libraries (the merged library contains most of LO)
# -----------------------------------------------------------
echo "  Copying core libraries..."

# Merged library (contains most of LibreOffice when --enable-mergelibs=more)
cp -a "$INSTDIR"/program/libmergedlo.so* "$OUTPUT_DIR/lib/" 2>/dev/null || true
cp -a "$INSTDIR"/program/libmergedlo.dylib* "$OUTPUT_DIR/lib/" 2>/dev/null || true

# Essential individual libraries that may not be merged
for lib in \
    libuno_sal libuno_salhelpergcc3 libuno_cppu libuno_cppuhelpergcc3 \
    libreglo libstorelo libunoidllo \
    libjvmfwk libxmlreaderlo \
    libicudata libicui18n libicuuc \
    libxml2 libxslt libcairo libpixman \
    libfontconfig libfreetype libharfbuzz libgraphite2 \
    libpng libjpeg libtiff libexpat libcurl \
    libnss3 libnssutil3 libnspr4 libplc4 libplds4 libsmime3 libssl3 \
    libz \
    ; do
    # Try .so, .dylib patterns
    cp -a "$INSTDIR"/program/${lib}*.so* "$OUTPUT_DIR/lib/" 2>/dev/null || true
    cp -a "$INSTDIR"/program/${lib}*.dylib* "$OUTPUT_DIR/lib/" 2>/dev/null || true
done

# UNO component libraries (loaded via dlopen at runtime)
echo "  Copying UNO component libraries..."
for comp in \
    configmgr i18npool i18nlangtag \
    ucb1 ucpfile1 \
    filterconfig1 pdffilter \
    sax expwrap \
    bootstrap deployment \
    ; do
    cp -a "$INSTDIR"/program/${comp}*.so* "$OUTPUT_DIR/lib/" 2>/dev/null || true
    cp -a "$INSTDIR"/program/${comp}*.dylib* "$OUTPUT_DIR/lib/" 2>/dev/null || true
done

# -----------------------------------------------------------
# UNO type registries (required for component loading)
# -----------------------------------------------------------
echo "  Copying UNO registries..."
cp -a "$INSTDIR"/program/types.rdb "$OUTPUT_DIR/program/" 2>/dev/null || true
cp -a "$INSTDIR"/program/types/ "$OUTPUT_DIR/program/" 2>/dev/null || true
cp -a "$INSTDIR"/program/services.rdb "$OUTPUT_DIR/program/" 2>/dev/null || true
cp -a "$INSTDIR"/program/services/ "$OUTPUT_DIR/program/" 2>/dev/null || true

# -----------------------------------------------------------
# Configuration (XCD files - required for bootstrap)
# -----------------------------------------------------------
echo "  Copying configuration..."
mkdir -p "$OUTPUT_DIR/share/registry"
cp -a "$INSTDIR"/share/registry/*.xcd "$OUTPUT_DIR/share/registry/" 2>/dev/null || true

# -----------------------------------------------------------
# Filter definitions (required for format detection)
# -----------------------------------------------------------
echo "  Copying filter definitions..."
if [ -d "$INSTDIR/share/filter" ]; then
    cp -a "$INSTDIR/share/filter" "$OUTPUT_DIR/share/"
fi

# -----------------------------------------------------------
# Fundamental RC files (bootstrap configuration)
# -----------------------------------------------------------
echo "  Copying bootstrap configuration..."
cp -a "$INSTDIR"/program/fundamentalrc "$OUTPUT_DIR/program/" 2>/dev/null || true
cp -a "$INSTDIR"/program/fundamental.ini "$OUTPUT_DIR/program/" 2>/dev/null || true
cp -a "$INSTDIR"/program/versionrc "$OUTPUT_DIR/program/" 2>/dev/null || true
cp -a "$INSTDIR"/program/version.ini "$OUTPUT_DIR/program/" 2>/dev/null || true
cp -a "$INSTDIR"/program/bootstraprc "$OUTPUT_DIR/program/" 2>/dev/null || true
cp -a "$INSTDIR"/program/bootstrap.ini "$OUTPUT_DIR/program/" 2>/dev/null || true
cp -a "$INSTDIR"/program/unorc "$OUTPUT_DIR/program/" 2>/dev/null || true
cp -a "$INSTDIR"/program/uno.ini "$OUTPUT_DIR/program/" 2>/dev/null || true

# -----------------------------------------------------------
# Font configuration
# -----------------------------------------------------------
echo "  Copying font configuration..."
if [ -d "$INSTDIR/share/fonts" ]; then
    mkdir -p "$OUTPUT_DIR/share/fonts"
    cp -a "$INSTDIR/share/fonts" "$OUTPUT_DIR/share/"
fi

# -----------------------------------------------------------
# Cleanup: strip binaries
# -----------------------------------------------------------
echo "  Stripping binaries..."
find "$OUTPUT_DIR/lib" -name "*.so*" -exec strip --strip-unneeded {} \; 2>/dev/null || true
find "$OUTPUT_DIR/lib" -name "*.dylib" -exec strip -x {} \; 2>/dev/null || true

# -----------------------------------------------------------
# Report
# -----------------------------------------------------------
echo ""
echo "=== Artifact Summary ==="
LIB_COUNT=$(find "$OUTPUT_DIR/lib" -name "*.so*" -o -name "*.dylib" | wc -l)
echo "Libraries: $LIB_COUNT"
echo "Total size:"
du -sh "$OUTPUT_DIR"
echo ""
echo "Breakdown:"
du -sh "$OUTPUT_DIR"/*
