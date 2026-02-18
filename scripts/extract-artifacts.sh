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
DOCX_AGGRESSIVE="${DOCX_AGGRESSIVE:-1}"

if [ "$DOCX_AGGRESSIVE" != "1" ]; then
    echo "ERROR: DOCX_AGGRESSIVE=$DOCX_AGGRESSIVE is unsupported."
    echo "       SlimLO extraction now runs in always-aggressive DOCX-only mode."
    exit 1
fi

if [ ! -d "$INSTDIR" ]; then
    echo "ERROR: instdir not found: $INSTDIR"
    exit 1
fi

echo "Extracting artifacts from $INSTDIR to $OUTPUT_DIR..."
echo "  Profile: docx-aggressive"

# Platform-specific folder names (macOS .app bundle uses different layout)
case "$(uname -s)" in
    Darwin)
        LIB_FOLDER="Frameworks"
        ETC_FOLDER="Resources"
        SHARE_FOLDER="Resources"
        PRESETS_FOLDER="Resources/presets"
        LIB_EXT="dylib"
        ;;
    *)
        LIB_FOLDER="program"
        ETC_FOLDER="program"
        SHARE_FOLDER="share"
        PRESETS_FOLDER="presets"
        LIB_EXT="so"
        ;;
esac

remove_program_library_variants() {
    local name="$1"
    rm -f "$OUTPUT_DIR/program/${name}.so"
    rm -f "$OUTPUT_DIR/program/${name}.so."*
    rm -f "$OUTPUT_DIR/program/${name}.dylib"
    rm -f "$OUTPUT_DIR/program/${name}.dylib."*
    rm -f "$OUTPUT_DIR/program/${name}.dll"
}

# Clean output directory — always use program/ and share/ in output for consistency
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"/program

# -----------------------------------------------------------
# 1. Copy ALL shared libraries from program/
#    With mergelibs=more, this is mostly libmergedlo.so + URE + externals.
#    Copying all .so/.dylib is safer than cherry-picking.
# -----------------------------------------------------------
echo "  Copying libraries..."
find "$INSTDIR/$LIB_FOLDER" \( -name "*.so" -o -name "*.so.*" -o -name "*.dylib" -o -name "*.dylib.*" -o -name "*.dll" \) \
    -exec cp -a {} "$OUTPUT_DIR/program/" \;

# -----------------------------------------------------------
# 2. UNO type and service registries (required for component loading)
# -----------------------------------------------------------
echo "  Copying UNO registries..."
cp -a "$INSTDIR/$ETC_FOLDER"/types.rdb "$OUTPUT_DIR/program/" 2>/dev/null || true
cp -a "$INSTDIR/$ETC_FOLDER"/services.rdb "$OUTPUT_DIR/program/" 2>/dev/null || true
# Some builds use subdirectories for split registries
if [ -d "$INSTDIR/$ETC_FOLDER/types" ]; then
    cp -a "$INSTDIR/$ETC_FOLDER/types" "$OUTPUT_DIR/program/"
fi
if [ -d "$INSTDIR/$ETC_FOLDER/services" ]; then
    cp -a "$INSTDIR/$ETC_FOLDER/services" "$OUTPUT_DIR/program/"
fi
# macOS: URE base registries are in Resources/ure/share/misc/
case "$(uname -s)" in
    Darwin)
        if [ -d "$INSTDIR/Resources/ure/share/misc" ]; then
            echo "    Copying URE base registries..."
            cp -a "$INSTDIR/Resources/ure/share/misc/types.rdb" "$OUTPUT_DIR/program/" 2>/dev/null || true
            cp -a "$INSTDIR/Resources/ure/share/misc/services.rdb" "$OUTPUT_DIR/program/" 2>/dev/null || true
        fi
        ;;
esac

# -----------------------------------------------------------
# 3. Bootstrap RC files (required for LOKit initialization)
# -----------------------------------------------------------
echo "  Copying bootstrap configuration..."
for rc in sofficerc soffice.ini fundamentalrc fundamental.ini versionrc version.ini \
          bootstraprc bootstrap.ini unorc uno.ini lounorc louno.ini loaborc saborc; do
    cp -a "$INSTDIR/$ETC_FOLDER/$rc" "$OUTPUT_DIR/program/" 2>/dev/null || true
done
# macOS: unorc lives in Resources/ure/etc/unorc — copy and adapt paths for flat layout
case "$(uname -s)" in
    Darwin)
        MACOS_UNORC="$INSTDIR/Resources/ure/etc/unorc"
        if [ -f "$MACOS_UNORC" ] && [ ! -f "$OUTPUT_DIR/program/unorc" ]; then
            echo "    Creating flat-layout unorc for macOS..."
            # Original uses ${ORIGIN} = ure/etc/, paths like ${ORIGIN}/../../../Frameworks
            # Our flat layout has everything in program/, so rewrite paths
            cat > "$OUTPUT_DIR/program/unorc" << 'UNORC_EOF'
[Bootstrap]
URE_INTERNAL_LIB_DIR=${ORIGIN}
URE_INTERNAL_JAVA_DIR=${ORIGIN}/../Resources/java
URE_INTERNAL_JAVA_CLASSPATH=${URE_MORE_JAVA_TYPES}
UNO_TYPES=${ORIGIN}/types.rdb ${URE_MORE_TYPES}
UNO_SERVICES=${ORIGIN}/services.rdb ${URE_MORE_SERVICES}
UNORC_EOF
        fi
        ;;
esac

# -----------------------------------------------------------
# 4. Configuration (XCD files — required for UNO bootstrap)
# -----------------------------------------------------------
echo "  Copying XCD configuration..."
if [ -d "$INSTDIR/$SHARE_FOLDER/registry" ]; then
    mkdir -p "$OUTPUT_DIR/share/registry"
    cp -a "$INSTDIR/$SHARE_FOLDER"/registry/*.xcd "$OUTPUT_DIR/share/registry/" 2>/dev/null || true
fi

# -----------------------------------------------------------
# 5. Filter definitions (required for format detection/export)
# -----------------------------------------------------------
echo "  Copying filter definitions..."
if [ -d "$INSTDIR/$SHARE_FOLDER/filter" ]; then
    mkdir -p "$OUTPUT_DIR/share"
    cp -a "$INSTDIR/$SHARE_FOLDER/filter" "$OUTPUT_DIR/share/"
fi

# -----------------------------------------------------------
# 6. Misc share data
# -----------------------------------------------------------
echo "  Copying share data..."
# Config directory — copy all, then prune non-essential soffice.cfg modules
if [ -d "$INSTDIR/$SHARE_FOLDER/config" ]; then
    mkdir -p "$OUTPUT_DIR/share"
    cp -a "$INSTDIR/$SHARE_FOLDER/config" "$OUTPUT_DIR/share/"
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
if [ -d "$INSTDIR/$SHARE_FOLDER/palette" ]; then
    cp -a "$INSTDIR/$SHARE_FOLDER/palette" "$OUTPUT_DIR/share/"
fi
# Fonts (only present if --without-fonts was NOT used)
if [ -d "$INSTDIR/$SHARE_FOLDER/fonts" ]; then
    cp -a "$INSTDIR/$SHARE_FOLDER/fonts" "$OUTPUT_DIR/share/"
fi
# Language tag registry data (required by i18nlangtag/liblangtag runtime lookups)
if [ -d "$INSTDIR/$SHARE_FOLDER/liblangtag" ]; then
    cp -a "$INSTDIR/$SHARE_FOLDER/liblangtag" "$OUTPUT_DIR/share/"
fi
# Presets directory (required for user profile initialization)
# LOKit's userinstall::create() copies BRAND_BASE_DIR/presets to user profile.
# On Linux: LIBO_SHARE_PRESETS_FOLDER="presets" relative to install root.
# On macOS: LIBO_SHARE_PRESETS_FOLDER="Resources/presets" relative to Contents/.
# An empty directory satisfies the check; missing directory causes fatal error.
if [ -d "$INSTDIR/$PRESETS_FOLDER" ]; then
    mkdir -p "$OUTPUT_DIR/presets"
    cp -a "$INSTDIR/$PRESETS_FOLDER"/* "$OUTPUT_DIR/presets/" 2>/dev/null || true
else
    mkdir -p "$OUTPUT_DIR/presets"
fi

# -----------------------------------------------------------
# 6b. macOS: Create .app-compatible directory symlinks
#     LOKit on macOS hardcodes: aAppProgramURL + "/../Resources/" for sofficerc,
#     and fundamentalrc uses BRAND_BASE_DIR/Resources/ and BRAND_BASE_DIR/Frameworks/.
#     Our flat output has everything in program/ and share/.
#     Create symlinks so LOKit finds files where it expects them.
# -----------------------------------------------------------
case "$(uname -s)" in
    Darwin)
        echo "  Creating macOS .app-compatible symlinks..."
        # LOKit looks for ../Resources/ relative to the program directory passed to lok_init
        ln -sfn program "$OUTPUT_DIR/Resources"
        # fundamentalrc references BRAND_BASE_DIR/Frameworks/ for LO_LIB_DIR
        ln -sfn program "$OUTPUT_DIR/Frameworks"
        # fundamentalrc uses BRAND_BASE_DIR/Resources/registry, BRAND_BASE_DIR/Resources/config etc.
        # Since Resources → program, these resolve to program/registry, program/config etc.
        # But our data is in share/. Create symlinks inside program/ to share/ subdirs.
        for subdir in registry filter config palette fonts liblangtag; do
            if [ -d "$OUTPUT_DIR/share/$subdir" ]; then
                ln -sfn "../share/$subdir" "$OUTPUT_DIR/program/$subdir"
            fi
        done
        ;;
esac

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
    rm -f "$OUTPUT_DIR/program/${lib}.dll"
done

# -----------------------------------------------------------
# 7b2. Remove external import libraries for formats we don't need
#      (DOCX-only: no Mac Word, Keynote, StarOffice, Works, etc.)
# -----------------------------------------------------------
echo "  Removing non-essential external import libraries..."
for extlib in \
    "libmwaw-0.3*" "mwaw-0.3-lo.dll" \
    "libetonyek-0.1*" "etonyek-0.1-lo.dll" \
    "libstaroffice-0.0*" "staroffice-0.0-lo.dll" \
    "libwps-0.4*" "wps-0.4-lo.dll" \
    "liborcus-0.20*" "orcus-0.20.dll" \
    "liborcus-parser-0.20*" "orcus-parser-0.20.dll" \
    "libodfgen-0.1*" "odfgen-0.1-lo.dll" \
    "libwpd-0.10*" "wpd-0.10-lo.dll" \
    "libwpg-0.3*" "wpg-0.3-lo.dll" \
    "librevenge-0.0*" "revenge-0.0-lo.dll" \
    "libexslt.*" "exslt.dll" \
; do
    rm -f "$OUTPUT_DIR/program/"$extlib
done
# Remove GDB helper scripts
rm -f "$OUTPUT_DIR/program/"*.py

# -----------------------------------------------------------
# 7b3. Remove external libraries already unlinked by dep-ladder patches
#      These are built by LO's external system but nothing links to them.
# -----------------------------------------------------------
echo "  Removing dep-ladder unlinked external libraries..."
# OpenGL binding library — S02 removed from merged deps, nothing links to it.
for extlib in "libepoxy*" "epoxy.dll"; do
    rm -f "$OUTPUT_DIR/program/"$extlib
done
# Color management library — S06 removed from vcl externals, nothing links to it.
for extlib in "liblcms2*" "lcms2.dll"; do
    rm -f "$OUTPUT_DIR/program/"$extlib
done
# Liblangtag locale data — language-subtag-registry.xml (1.3 MB) + common/ (0.5 MB).
# Warnings are non-fatal; DOCX→PDF conversion works without these BCP 47 data files.
rm -rf "$OUTPUT_DIR/share/liblangtag"
rm -f "$OUTPUT_DIR/program/liblangtag"
# RDF/Redland stack — S07 guards all RDF-consuming code in merged lib.
# libunordflo is the sole consumer; services.rdb cleaning handles component removal.
for extlib in "librdf-lo*" "libraptor2-lo*" "librasqal-lo*" "libunordflo*"; do
    rm -f "$OUTPUT_DIR/program/"$extlib
done

# -----------------------------------------------------------
# 7c. Remove XCD config for unused modules
# -----------------------------------------------------------
echo "  Removing unused XCD files..."
for xcd in math base xsltfilter ogltrans ctlseqcheck cjk impress calc draw; do
    rm -f "$OUTPUT_DIR/share/registry/${xcd}.xcd"
done

# -----------------------------------------------------------
# 7d. Remove signature SVG files (not needed for rendering)
# -----------------------------------------------------------
rm -f "$OUTPUT_DIR/share/filter/signature-line.svg"
rm -f "$OUTPUT_DIR/share/filter/signature-line-draw.svg"

# -----------------------------------------------------------
# 7e. Remove VBA type registry (no macro execution needed)
# -----------------------------------------------------------
rm -f "$OUTPUT_DIR/program/types/oovbaapi.rdb"

# -----------------------------------------------------------
# 7f. Remove lingucomponent XCD (spellcheck — not needed for conversion)
# -----------------------------------------------------------
rm -f "$OUTPUT_DIR/share/registry/lingucomponent.xcd"

# -----------------------------------------------------------
# 7f2. Always-aggressive DOCX runtime pruning
# -----------------------------------------------------------
echo "  Applying DOCX aggressive pruning profile..."

# Additional runtime libraries validated for DOCX-only conversion.
# NOTE: libsoftokn3/libfreebl3 are intentionally kept (probe-rejected).
for lib in \
    libmswordlo libcached1 libgraphicfilterlo libfps_aqualo \
    libnssckbi libnssdbm3 libssl3 \
    libnet_uno libmacbe1lo libintrospectionlo libinvocationlo \
    libinvocadaptlo libreflectionlo libunsafe_uno_uno libaffine_uno_uno \
    libbinaryurplo libbootstraplo libiolo libloglo libstoragefdlo \
    libtllo libucbhelper libucppkg1 libsal_textenc libsal_textenclo \
; do
    remove_program_library_variants "$lib"
done

# UI/config modules not needed in headless DOCX-only mode.
# NOTE: sfx, svx, vcl must be KEPT — LOKit loads their .ui files even in headless mode.
# Removing them causes "Unspecified Application Error" (DeploymentException) during conversion.
for cfg in fps formula uui xmlsec; do
    rm -rf "$OUTPUT_DIR/share/config/soffice.cfg/$cfg"
done

# Remove filter data and selected registry entries not needed for DOCX->PDF.
rm -rf "$OUTPUT_DIR/share/filter"
# Keep Langpack-en-US.xcd — it registers en-US as an installed locale.
# Without it, Linux/Windows SetupL10N fails: "user interface language cannot be determined"
# (macOS doesn't need it — locale is detected via CFLocale system API).
rm -f "$OUTPUT_DIR/share/registry/ctl.xcd"
rm -f "$OUTPUT_DIR/share/registry/graphicfilter.xcd"

# -----------------------------------------------------------
# 7f3. Remove mergelibs stub files (21-byte "invalid - merged lib" placeholders).
#      These are created by --enable-mergelibs but serve no runtime purpose:
#      UNO component loading uses services.rdb, not file existence probing.
# -----------------------------------------------------------
echo "  Removing mergelibs stub files..."
STUB_COUNT=0
while IFS= read -r stubfile; do
    rm -f "$stubfile"
    STUB_COUNT=$((STUB_COUNT + 1))
done < <(find "$OUTPUT_DIR/program" -maxdepth 1 -type f -size 21c 2>/dev/null)
echo "    Removed $STUB_COUNT stub files"

# -----------------------------------------------------------
# 7g. Remove NEEDED-but-unused external libraries via patchelf
#     libcurl.so.4 is NEEDED by libmergedlo.so but never called for local conversion.
#     NOTE: librdf/libraptor2/librasqal removed in step 7b3 (S07 guards RDF calls).
# -----------------------------------------------------------
echo "  Removing unused NEEDED libraries..."
case "$(uname -s)" in
    CYGWIN*|MINGW*|MSYS*)
        echo "    Windows: skipping NEEDED removal (not applicable to PE format)"
        ;;
    Darwin)
        # macOS: install_name_tool cannot remove NEEDED deps (no --remove-needed equivalent).
        # Keep libcurl.4.dylib — it's small and harmless.
        echo "    macOS: skipping NEEDED removal (install_name_tool cannot remove deps)"
        ;;
    *)
        MERGEDSO_PRE="$OUTPUT_DIR/program/libmergedlo.so"
        if command -v patchelf &>/dev/null && [ -f "$MERGEDSO_PRE" ]; then
            for needlib in libcurl.so.4; do
                if readelf -d "$MERGEDSO_PRE" 2>/dev/null | grep -q "$needlib"; then
                    patchelf --remove-needed "$needlib" "$MERGEDSO_PRE"
                    rm -f "$OUTPUT_DIR/program/$needlib"
                    echo "    Removed NEEDED + file: $needlib"
                fi
            done
        else
            echo "    patchelf not available — skipping NEEDED removal"
        fi
        ;;
esac

# -----------------------------------------------------------
# 8. Strip binaries to reduce size
# -----------------------------------------------------------
echo "  Stripping binaries..."
find "$OUTPUT_DIR/program" -name "*.so" -exec strip --strip-unneeded {} \; 2>/dev/null || true
find "$OUTPUT_DIR/program" -name "*.so.*" -exec strip --strip-unneeded {} \; 2>/dev/null || true
find "$OUTPUT_DIR/program" -name "*.dylib" -exec strip -x {} \; 2>/dev/null || true
find "$OUTPUT_DIR/program" -name "*.dylib.*" -exec strip -x {} \; 2>/dev/null || true
find "$OUTPUT_DIR/program" -name "*.dll" -exec strip --strip-unneeded {} \; 2>/dev/null || true

# -----------------------------------------------------------
# 8b. Clean services.rdb — remove component entries for libraries
#     we don't ship. On macOS, some libraries are NOT merged into
#     libmergedlo.dylib, and the UNO service manager crashes when
#     trying to instantiate services from missing libraries (e.g.,
#     libLanguageToollo.dylib grammar checker causes null ptr crash
#     in LngSvcMgr::GetAvailableGrammarSvcs_Impl).
# -----------------------------------------------------------
echo "  Cleaning services.rdb (removing entries for missing libraries)..."
SERVICES_RDB="$OUTPUT_DIR/program/services/services.rdb"
if [ -f "$SERVICES_RDB" ] && command -v python3 &>/dev/null; then
    python3 -c "
import xml.etree.ElementTree as ET
import os, sys

ET.register_namespace('', 'http://openoffice.org/2010/uno-components')
tree = ET.parse('$SERVICES_RDB')
root = tree.getroot()
ns = {'ns': 'http://openoffice.org/2010/uno-components'}
prog = '$OUTPUT_DIR/program'
removed = 0
for comp in list(root.findall('ns:component', ns)):
    uri = comp.get('uri', '')
    lib = uri.split('/')[-1]
    if lib and not os.path.exists(os.path.join(prog, lib)):
        root.remove(comp)
        removed += 1
print(f'    Removed {removed} component entries for missing libraries', file=sys.stderr)
tree.write('$SERVICES_RDB', xml_declaration=True, encoding='unicode')
" 2>&1
else
    echo "    Skipping (services.rdb not found or python3 not available)"
fi

# -----------------------------------------------------------
# 9. Verify constructor symbols survived stripping
# -----------------------------------------------------------
echo "  Verifying constructor symbol visibility..."
case "$(uname -s)" in
    CYGWIN*|MINGW*|MSYS*)
        MERGEDSO="$OUTPUT_DIR/program/mergedlo.dll"
        if [ -f "$MERGEDSO" ]; then
            CTOR_COUNT=$(dumpbin.exe /exports "$MERGEDSO" 2>/dev/null | grep -c "get_implementation" || echo "0")
            echo "  Constructor symbols (exports): $CTOR_COUNT"
            if [ "$CTOR_COUNT" -eq 0 ] 2>/dev/null; then
                echo "  WARNING: No constructor symbols found in mergedlo.dll!"
                echo "  UNO component loading will likely fail at runtime."
            fi
        fi
        ;;
    Darwin)
        MERGEDSO="$OUTPUT_DIR/program/libmergedlo.dylib"
        if [ -f "$MERGEDSO" ]; then
            CTOR_COUNT=$(nm -g "$MERGEDSO" 2>/dev/null | grep -c "get_implementation" || echo "0")
            echo "  Constructor symbols: $CTOR_COUNT"
            if [ "$CTOR_COUNT" -eq 0 ] 2>/dev/null; then
                echo "  WARNING: No constructor symbols found in libmergedlo.dylib!"
                echo "  UNO component loading will likely fail at runtime."
            fi
        fi
        ;;
    *)
        MERGEDSO="$OUTPUT_DIR/program/libmergedlo.so"
        if [ -f "$MERGEDSO" ]; then
            CTOR_COUNT=$(readelf --dyn-syms -W "$MERGEDSO" 2>/dev/null | grep -c "get_implementation" || echo "0")
            echo "  Constructor symbols in .dynsym: $CTOR_COUNT"
            if [ "$CTOR_COUNT" -eq 0 ] 2>/dev/null; then
                echo "  WARNING: No constructor symbols found in libmergedlo.so .dynsym!"
                echo "  UNO component loading will likely fail at runtime."
            fi
        fi
        ;;
esac

# -----------------------------------------------------------
# Report
# -----------------------------------------------------------
echo ""
echo "=== Artifact Summary ==="
echo "Profile: docx-aggressive"
LIB_COUNT=$(find "$OUTPUT_DIR/program" \( -name "*.so" -o -name "*.so.*" -o -name "*.dylib" -o -name "*.dylib.*" -o -name "*.dll" \) | wc -l)
echo "Libraries: $LIB_COUNT"
echo ""
echo "Total size:"
du -sh "$OUTPUT_DIR"
echo ""
echo "Breakdown:"
du -sh "$OUTPUT_DIR"/* 2>/dev/null || true
echo ""
echo "Largest files:"
find "$OUTPUT_DIR/program" -type f -exec du -h {} + 2>/dev/null | sort -hr | head -20 || true
