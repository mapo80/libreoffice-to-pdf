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
DOCX_AGGRESSIVE="${DOCX_AGGRESSIVE:-0}"
SKIP_CONFIGURE="${SKIP_CONFIGURE:-0}"

# Detect platform
case "$(uname -s)" in
    CYGWIN*|MINGW*|MSYS*) PLATFORM="windows" ;;
    Darwin)               PLATFORM="macos" ;;
    *)                    PLATFORM="linux" ;;
esac

# LibreOffice gbuild enables a WSL path-conversion branch when MSYSTEM is set.
# In GitHub Actions MSYS2 this causes broken "/..." source paths and
# "wslpath: No such file or directory" during make.
if [ "$PLATFORM" = "windows" ] && [ -n "${MSYSTEM:-}" ]; then
    echo "Detected MSYSTEM=$MSYSTEM, unsetting for LibreOffice gbuild compatibility"
    unset MSYSTEM
    unset WSL
fi

# MSBuild on Windows treats environment-variable names case-insensitively.
# Having both UCRTVERSION (from LibreOffice configure) and UCRTVersion
# (from VS devcmd) can trigger an internal dictionary key collision.
if [ "$PLATFORM" = "windows" ] && [ -n "${UCRTVersion:-}" ]; then
    echo "Unsetting UCRTVersion to avoid MSBuild env collision with UCRTVERSION"
    unset UCRTVersion
fi

if [ "$PLATFORM" = "windows" ] && command -v cl.exe >/dev/null 2>&1; then
    CL_BIN="$(command -v cl.exe)"
    CL_DIR="$(dirname "$CL_BIN")"
    case ":$PATH:" in
        *":$CL_DIR:"*) ;;
        *) export PATH="$CL_DIR:$PATH" ;;
    esac
    echo "Prioritized MSVC toolchain dir: $CL_DIR"
    echo "MSVC linker in use: $(command -v link.exe || echo 'not found')"
fi

if [ "$PLATFORM" = "windows" ] && [ -n "${ICU_DATA_FILTER_FILE:-}" ]; then
    case "$ICU_DATA_FILTER_FILE" in
        /*)
            if command -v cygpath >/dev/null 2>&1; then
                ICU_DATA_FILTER_FILE="$(cygpath -m "$ICU_DATA_FILTER_FILE")"
                export ICU_DATA_FILTER_FILE
            fi
            ;;
    esac
    ICU_FILTER_CHECK="$ICU_DATA_FILTER_FILE"
    case "$ICU_FILTER_CHECK" in
        [A-Za-z]:/*)
            if command -v cygpath >/dev/null 2>&1; then
                ICU_FILTER_CHECK="$(cygpath -u "$ICU_FILTER_CHECK")"
            fi
            ;;
    esac
    if [ ! -f "$ICU_FILTER_CHECK" ]; then
        echo "ERROR: ICU_DATA_FILTER_FILE not found: $ICU_DATA_FILTER_FILE"
        exit 1
    fi
    echo "Using ICU_DATA_FILTER_FILE=$ICU_DATA_FILTER_FILE"
fi

if [ "$PLATFORM" = "windows" ] && ! command -v wslpath >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
    SHIM_DIR="$PROJECT_DIR/.slimlo-tools"
    mkdir -p "$SHIM_DIR"
    cat > "$SHIM_DIR/wslpath" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-}"
if [ "$MODE" = "-u" ] || [ "$MODE" = "-w" ] || [ "$MODE" = "-m" ]; then
    shift
else
    MODE="-u"
fi
exec cygpath "$MODE" "$1"
EOF
    chmod +x "$SHIM_DIR/wslpath"
    export PATH="$SHIM_DIR:$PATH"
    echo "Installed local wslpath shim: $SHIM_DIR/wslpath"
fi

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
if [ "$SKIP_CONFIGURE" = "1" ]; then
echo " Mode:         build-only (skip configure)"
fi
echo "============================================"
echo ""

if [ "$SKIP_CONFIGURE" = "1" ]; then
    if [ ! -f "$LO_SRC_DIR/config_host.mk" ]; then
        echo "ERROR: SKIP_CONFIGURE=1 but config_host.mk not found."
        echo "       Run a full build first before using --skip-configure."
        exit 1
    fi
    echo ">>> Skipping steps 1-4.5 (SKIP_CONFIGURE=1)"
    echo ""
    cd "$LO_SRC_DIR"
else

# -----------------------------------------------------------
# Step 1: Clone upstream source (shallow for speed)
# -----------------------------------------------------------
if [ ! -d "$LO_SRC_DIR/.git" ]; then
    echo ">>> Step 1: Cloning LibreOffice $LO_VERSION..."
    # Use larger buffers for reliability on slow/flaky connections.
    # MSYS2 git may segfault after a successful clone on large repos,
    # so verify the result by checking for .git dir instead of exit code.
    git -c http.postBuffer=524288000 -c pack.windowMemory=256m \
        clone --depth 1 --branch "$LO_VERSION" \
        https://github.com/LibreOffice/core.git "$LO_SRC_DIR" || true
    if [ ! -d "$LO_SRC_DIR/.git" ] || [ ! -f "$LO_SRC_DIR/configure.ac" ]; then
        echo "ERROR: git clone failed — $LO_SRC_DIR is incomplete"
        exit 1
    fi
    # MSYS2 git may segfault mid-checkout, leaving files missing.
    # Detect and repair by checking for deleted files and restoring them.
    MISSING="$(git -C "$LO_SRC_DIR" status --short 2>/dev/null | grep -c '^D ' || true)"
    if [ "$MISSING" -gt 0 ]; then
        echo "    WARNING: $MISSING files missing after clone (likely git segfault during checkout)"
        echo "    Restoring missing files..."
        rm -f "$LO_SRC_DIR/.git/index.lock"
        git -C "$LO_SRC_DIR" checkout HEAD -- .
        echo "    OK: files restored"
    fi
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
    windows) DISTRO_CONF="SlimLO-windows.conf" ;;
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
AUTOGEN_ARGS=("--with-distro=$DISTRO_NAME")
if [ -n "${PKG_CONFIG:-}" ]; then
    echo "    Using PKG_CONFIG=$PKG_CONFIG"
    AUTOGEN_ARGS=("PKG_CONFIG=$PKG_CONFIG" "${AUTOGEN_ARGS[@]}")
fi
PYTHON_BUILD_BIN="${PYTHON_FOR_BUILD:-${PYTHON:-}}"
if [ "$PLATFORM" = "windows" ]; then
    case "${PYTHON_BUILD_BIN:-}" in
        ""|/usr/bin/*|/mingw*/*)
            WIN_PYTHON="$(command -v python.exe 2>/dev/null || true)"
            case "$WIN_PYTHON" in
                ""|/usr/bin/*|/mingw*/*)
                    for candidate in /c/hostedtoolcache/windows/Python/*/x64/python.exe /c/hostedtoolcache/windows/Python/*/arm64/python.exe /c/Users/*/AppData/Local/Programs/Python/Python3*/python.exe "/c/Program Files/Python3"*/python.exe /c/Python*/python.exe; do
                        [ -x "$candidate" ] || continue
                        WIN_PYTHON="$candidate"
                        break
                    done
                    ;;
            esac
            if [ -n "$WIN_PYTHON" ] && [ -x "$WIN_PYTHON" ]; then
                PYTHON_BUILD_BIN="$WIN_PYTHON"
            fi
            ;;
    esac
fi
if [ -z "$PYTHON_BUILD_BIN" ] && command -v python >/dev/null 2>&1; then
    PYTHON_BUILD_BIN="$(command -v python)"
fi
if [ -z "$PYTHON_BUILD_BIN" ] && command -v python3 >/dev/null 2>&1; then
    PYTHON_BUILD_BIN="$(command -v python3)"
fi
if [ -n "$PYTHON_BUILD_BIN" ]; then
    echo "    Using PYTHON_FOR_BUILD=$PYTHON_BUILD_BIN"
    export PYTHON_FOR_BUILD="$PYTHON_BUILD_BIN"
    export PYTHON="${PYTHON:-$PYTHON_BUILD_BIN}"
fi
if [ "$PLATFORM" = "windows" ]; then
    WIN_ARCH="$(uname -m 2>/dev/null || echo unknown)"
    case "$WIN_ARCH" in
        x86_64|i686)
            # NASM required for x86/x64 SIMD (libjpeg-turbo assembly)
            NASM_BIN="${NASM:-}"
            if [ -z "$NASM_BIN" ]; then
                NASM_BIN="$(command -v nasm 2>/dev/null || command -v nasm.exe 2>/dev/null || true)"
            fi
            if [ -z "$NASM_BIN" ]; then
                echo "ERROR: nasm not found. Install it and ensure it is available in PATH."
                exit 1
            fi
            export NASM="$NASM_BIN"
            echo "    Using NASM=$NASM"
            "$NASM" -v || true
            ;;
        aarch64|arm64)
            echo "    ARM64 detected — NASM not required"
            ;;
        *)
            echo "    Unknown architecture $WIN_ARCH — skipping NASM check"
            ;;
    esac
fi
if [ "$PLATFORM" = "windows" ]; then
    # Auto-detect VS version if not explicitly set
    if [ -z "${SLIMLO_VISUAL_STUDIO_YEAR:-}" ]; then
        VS_MAJOR="$("${VSWHERE:-/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe}" -products '*' -latest -property installationVersion 2>/dev/null | cut -d. -f1 || true)"
        case "$VS_MAJOR" in
            18) VISUAL_STUDIO_YEAR="2026" ;;
            17) VISUAL_STUDIO_YEAR="2022" ;;
            16) VISUAL_STUDIO_YEAR="2019" ;;
            *)  VISUAL_STUDIO_YEAR="2022" ;;
        esac
    else
        VISUAL_STUDIO_YEAR="$SLIMLO_VISUAL_STUDIO_YEAR"
    fi
    WIN_PROGRAMFILES_X86="${WIN_PROGRAMFILES_X86:-C:/Program Files (x86)}"
    echo "    Forcing Visual Studio year: $VISUAL_STUDIO_YEAR"
    echo "    Forcing ProgramFiles(x86) for configure: $WIN_PROGRAMFILES_X86"
    AUTOGEN_ARGS+=("--with-visual-studio=$VISUAL_STUDIO_YEAR")
    env "ProgramFiles(x86)=$WIN_PROGRAMFILES_X86" \
        "PROGRAMFILESX86=$WIN_PROGRAMFILES_X86" \
        "PYTHON_FOR_BUILD=${PYTHON_FOR_BUILD:-}" \
        "PYTHON=${PYTHON:-}" \
        ./autogen.sh "${AUTOGEN_ARGS[@]}"
else
    ./autogen.sh "${AUTOGEN_ARGS[@]}"
fi
if [ "$PLATFORM" = "windows" ] && [ -f "$LO_SRC_DIR/config_host.mk" ]; then
    CONFIG_PYTHON="$(awk -F= '/^export PYTHON=/{print $2; exit}' "$LO_SRC_DIR/config_host.mk" || true)"
    CONFIG_PYTHON_FOR_BUILD="$(awk -F= '/^export PYTHON_FOR_BUILD=/{print $2; exit}' "$LO_SRC_DIR/config_host.mk" || true)"
    echo "    config_host.mk PYTHON=$CONFIG_PYTHON"
    echo "    config_host.mk PYTHON_FOR_BUILD=$CONFIG_PYTHON_FOR_BUILD"
    case "$CONFIG_PYTHON $CONFIG_PYTHON_FOR_BUILD" in
        *"/usr/bin/python"*|*"/mingw"* )
            echo "ERROR: configure selected MSYS Python; Windows python.exe is required for D:/ paths."
            exit 1
            ;;
    esac
fi
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

fi # end SKIP_CONFIGURE

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
if [ "$PLATFORM" = "windows" ]; then
    MSYSTEM= WSL= make -j"$NPROC"
else
    make -j"$NPROC"
fi
echo ""

# -----------------------------------------------------------
# Step 6: Extract minimal artifacts
# -----------------------------------------------------------
echo ">>> Step 6: Extracting artifacts (DOCX_AGGRESSIVE=$DOCX_AGGRESSIVE)..."
cd "$PROJECT_DIR"
case "$PLATFORM" in
    macos) INSTDIR_ROOT="$LO_SRC_DIR/instdir/LibreOffice.app/Contents" ;;
    *)     INSTDIR_ROOT="$LO_SRC_DIR/instdir" ;;
esac
DOCX_AGGRESSIVE="$DOCX_AGGRESSIVE" \
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
    # Copy worker executable (needed by .NET SDK for out-of-process conversion)
    cp -a "$PROJECT_DIR/slimlo-api/build"/slimlo_worker "$OUTPUT_DIR/program/" 2>/dev/null || true
    cp -a "$PROJECT_DIR/slimlo-api/build"/slimlo_worker.exe "$OUTPUT_DIR/program/" 2>/dev/null || true
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
