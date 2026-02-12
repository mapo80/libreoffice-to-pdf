#!/bin/bash
# build.sh — Main SlimLO build script
# Clones LibreOffice source, applies patches, configures, builds, and extracts artifacts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LO_VERSION="$(cat "$PROJECT_DIR/LO_VERSION" | tr -d '[:space:]')"
LO_SRC_DIR="${LO_SRC_DIR:-$PROJECT_DIR/lo-src}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/output}"
NPROC="${NPROC:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

# Detect platform
case "$(uname -s)" in
    CYGWIN*|MINGW*|MSYS*) PLATFORM="windows" ;;
    Darwin)               PLATFORM="macos" ;;
    *)                    PLATFORM="linux" ;;
esac

# macOS: Ensure Homebrew tools take precedence over system ones.
# LO requires GNU Make >= 4.0 (macOS ships 3.81) and gperf >= 3.1 (macOS ships 3.0.3).
if [ "$PLATFORM" = "macos" ]; then
    # arm64 Homebrew (/opt/homebrew)
    [ -d "/opt/homebrew/opt/make/libexec/gnubin" ] && export PATH="/opt/homebrew/opt/make/libexec/gnubin:$PATH"
    [ -d "/opt/homebrew/bin" ] && export PATH="/opt/homebrew/bin:$PATH"
    # Intel Homebrew (/usr/local)
    [ -d "/usr/local/opt/make/libexec/gnubin" ] && export PATH="/usr/local/opt/make/libexec/gnubin:$PATH"
    [ -d "/usr/local/bin" ] && export PATH="/usr/local/bin:$PATH"
fi

echo "============================================"
echo " SlimLO Build"
echo " LO Version:  $LO_VERSION"
echo " Platform:    $PLATFORM"
echo " Source dir:   $LO_SRC_DIR"
echo " Output dir:   $OUTPUT_DIR"
echo " Parallelism:  $NPROC"
echo "============================================"
echo ""

# -----------------------------------------------------------
# Step 1: Clone upstream source (shallow for speed)
# -----------------------------------------------------------
if [ ! -d "$LO_SRC_DIR/.git" ]; then
    echo ">>> Step 1: Cloning LibreOffice $LO_VERSION..."
    git clone --depth 1 --branch "$LO_VERSION" \
        https://github.com/LibreOffice/core.git "$LO_SRC_DIR"
else
    echo ">>> Step 1: Source already exists at $LO_SRC_DIR (skipping clone)"
    CURRENT_TAG="$(git -C "$LO_SRC_DIR" describe --tags --exact-match 2>/dev/null || echo 'unknown')"
    if [ "$CURRENT_TAG" != "$LO_VERSION" ]; then
        echo "    WARNING: Existing source is at $CURRENT_TAG, expected $LO_VERSION"
        echo "    Delete $LO_SRC_DIR to re-clone, or set LO_SRC_DIR to a different path."
    fi
fi
echo ""

# -----------------------------------------------------------
# Step 2: Apply SlimLO patches
# -----------------------------------------------------------
echo ">>> Step 2: Applying patches..."
"$SCRIPT_DIR/apply-patches.sh" "$LO_SRC_DIR"
echo ""

# -----------------------------------------------------------
# Step 3: Copy distro config
# -----------------------------------------------------------
echo ">>> Step 3: Installing SlimLO distro config..."
case "$PLATFORM" in
    macos) DISTRO_CONF="SlimLO-macOS.conf" ;;
    *)     DISTRO_CONF="SlimLO.conf" ;;
esac
cp "$PROJECT_DIR/distro-configs/$DISTRO_CONF" "$LO_SRC_DIR/distro-configs/$DISTRO_CONF"
echo "    Copied $DISTRO_CONF to $LO_SRC_DIR/distro-configs/"
echo ""

# -----------------------------------------------------------
# Step 4: Configure
# -----------------------------------------------------------
DISTRO_NAME="${DISTRO_CONF%.conf}"
echo ">>> Step 4: Configuring LibreOffice (distro=$DISTRO_NAME)..."
cd "$LO_SRC_DIR"
./autogen.sh --with-distro="$DISTRO_NAME"
echo ""

# -----------------------------------------------------------
# Step 4.5: Apply post-autogen patches
# -----------------------------------------------------------
echo ">>> Step 4.5: Applying post-autogen patches..."
for patch in "$PROJECT_DIR"/patches/*.postautogen; do
    [ -f "$patch" ] || continue
    echo "    Running $(basename "$patch")"
    bash "$patch" "$LO_SRC_DIR"
done
# Force re-link of merged lib (ldflags change not detected by make)
case "$PLATFORM" in
    windows) rm -f "$LO_SRC_DIR/workdir/LinkTarget/Library/mergedlo.dll" 2>/dev/null || true ;;
    macos)   rm -f "$LO_SRC_DIR/workdir/LinkTarget/Library/libmergedlo.dylib" 2>/dev/null || true ;;
    *)       rm -f "$LO_SRC_DIR/workdir/LinkTarget/Library/libmergedlo.so" 2>/dev/null || true ;;
esac
echo ""

# -----------------------------------------------------------
# Step 5: Build
# -----------------------------------------------------------
echo ">>> Step 5: Building (this will take a while)..."
# Verify GNU Make >= 4.0 (macOS system make 3.81 can't handle nested define/endef in LO makefiles)
MAKE_VERSION=$(make --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
if [ "$(echo "$MAKE_VERSION < 4.0" | bc 2>/dev/null)" = "1" ]; then
    echo "ERROR: GNU Make >= 4.0 required (found $MAKE_VERSION)."
    echo "On macOS: brew install make"
    exit 1
fi
make -j"$NPROC"
echo ""

# -----------------------------------------------------------
# Step 6: Extract minimal artifacts
# -----------------------------------------------------------
echo ">>> Step 6: Extracting artifacts..."
cd "$PROJECT_DIR"
case "$PLATFORM" in
    macos) INSTDIR_ROOT="$LO_SRC_DIR/instdir/LibreOffice.app/Contents" ;;
    *)     INSTDIR_ROOT="$LO_SRC_DIR/instdir" ;;
esac
"$SCRIPT_DIR/extract-artifacts.sh" "$INSTDIR_ROOT" "$OUTPUT_DIR"
echo ""

# -----------------------------------------------------------
# Step 7: Build SlimLO C API wrapper
# -----------------------------------------------------------
echo ">>> Step 7: Building SlimLO C API..."
if [ -f "$PROJECT_DIR/slimlo-api/CMakeLists.txt" ]; then
    cmake -S "$PROJECT_DIR/slimlo-api" \
          -B "$PROJECT_DIR/slimlo-api/build" \
          -DINSTDIR="$INSTDIR_ROOT" \
          -DCMAKE_BUILD_TYPE=Release
    cmake --build "$PROJECT_DIR/slimlo-api/build" -j"$NPROC"

    # Copy library + symlinks to output (use libslimlo* to catch versioned names)
    cp -a "$PROJECT_DIR/slimlo-api/build"/libslimlo.so* "$OUTPUT_DIR/program/" 2>/dev/null || true
    cp -a "$PROJECT_DIR/slimlo-api/build"/libslimlo*.dylib* "$OUTPUT_DIR/program/" 2>/dev/null || true
    cp -a "$PROJECT_DIR/slimlo-api/build"/slimlo.dll "$OUTPUT_DIR/program/" 2>/dev/null || true
    mkdir -p "$OUTPUT_DIR/include"
    cp "$PROJECT_DIR/slimlo-api/include/slimlo.h" "$OUTPUT_DIR/include/"
    echo "    SlimLO C API built and copied to $OUTPUT_DIR/program/"
else
    echo "    WARNING: slimlo-api/CMakeLists.txt not found, skipping C API build"
fi
echo ""

# -----------------------------------------------------------
# Done
# -----------------------------------------------------------
echo "============================================"
echo " Build complete!"
echo " Output: $OUTPUT_DIR"
echo "============================================"
echo ""
du -sh "$OUTPUT_DIR" 2>/dev/null || true
