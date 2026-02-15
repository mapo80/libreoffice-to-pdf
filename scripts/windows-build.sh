#!/bin/bash
# windows-build.sh — Windows build wrapper for SlimLO.
# Configures the MSYS2 environment to match the CI and launches build.sh.
# Run inside an MSYS2 shell (MSYS, not MINGW64).
# Supports both ARM64 and x64 Windows.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

HOST_ARCH="$(uname -m 2>/dev/null || echo unknown)"

# Detect true target architecture from MSVC environment.
# MSYS2 may report x86_64 even on ARM64 Windows (Prism emulation).
# Priority: 1) TARGET_ARCH env var (from Start-WindowsBuild.ps1 -Arch)
#           2) VSCMD_ARG_TGT_ARCH (set by vcvarsall.bat)
#           3) LIB paths (contain "arm64" for ARM64 targets)
#           4) HOST_ARCH (uname -m, fallback)
TARGET_ARCH="${TARGET_ARCH:-$HOST_ARCH}"
if [ "${VSCMD_ARG_TGT_ARCH:-}" = "arm64" ]; then
    TARGET_ARCH="aarch64"
elif echo "${LIB:-}" | grep -qi 'arm64'; then
    TARGET_ARCH="aarch64"
fi

echo "============================================"
echo " SlimLO — Windows Build ($HOST_ARCH → target: $TARGET_ARCH)"
echo "============================================"
echo ""

# -----------------------------------------------------------
# Environment variables
# -----------------------------------------------------------
export CHERE_INVOKING=1
export MSYS=winsymlinks:native
export PATH="/usr/local/bin:$PATH:/mingw64/bin"

# LO configure expects a working pkgconf-2.4.3.exe
if [ -x /usr/local/bin/pkgconf-2.4.3.exe ]; then
    export PKG_CONFIG=/usr/local/bin/pkgconf-2.4.3.exe
else
    echo "WARNING: pkgconf-2.4.3.exe not found. Run setup-windows-msys2.sh first."
fi

# Prevent MSBuild env collisions and gbuild path issues
unset MSYSTEM 2>/dev/null || true
unset WSL 2>/dev/null || true
unset UCRTVersion 2>/dev/null || true

# -----------------------------------------------------------
# Find MSVC cl.exe via vswhere.exe
# -----------------------------------------------------------
echo ">>> Finding MSVC toolchain..."
VSWHERE="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
if [ ! -f "$VSWHERE" ]; then
    echo "ERROR: vswhere.exe not found at: $VSWHERE"
    echo "       Is Visual Studio installed?"
    exit 1
fi

# Find VS installation with VC tools
VS_INSTALL="$("$VSWHERE" -products '*' -latest -property installationPath | head -1)"
if [ -z "$VS_INSTALL" ]; then
    echo "ERROR: No Visual Studio installation found"
    exit 1
fi
echo "    VS install: $VS_INSTALL"

# Find cl.exe — check if already in PATH (e.g. from Developer Command Prompt)
CL_BIN="$(command -v cl.exe 2>/dev/null || true)"
if [ -z "$CL_BIN" ] || [[ "$CL_BIN" == /usr/* ]]; then
    # Not in PATH or is MSYS shim — search in VS directory
    VS_INSTALL_POSIX="$(cygpath -u "$VS_INSTALL" 2>/dev/null || echo "$VS_INSTALL")"

    case "$TARGET_ARCH" in
        aarch64|arm64)
            # ARM64 cross-compiler from x64 host tools (most common on MSYS2 x64-emulated)
            CL_BIN="$(find "$VS_INSTALL_POSIX/VC/Tools/MSVC" -path "*/Hostx64/arm64/cl.exe" 2>/dev/null | head -1 || true)"
            if [ -z "$CL_BIN" ]; then
                # Fallback: ARM64 native compiler (if running native ARM64 MSYS2)
                CL_BIN="$(find "$VS_INSTALL_POSIX/VC/Tools/MSVC" -path "*/Hostarm64/arm64/cl.exe" 2>/dev/null | head -1 || true)"
            fi
            ;;
        x86_64|i686)
            CL_BIN="$(find "$VS_INSTALL_POSIX/VC/Tools/MSVC" -path "*/Hostx64/x64/cl.exe" 2>/dev/null | head -1 || true)"
            ;;
    esac
fi

if [ -z "$CL_BIN" ]; then
    echo "ERROR: cl.exe not found for $TARGET_ARCH"
    echo "       Ensure Visual Studio C++ tools are installed for your architecture."
    echo "       Try opening a 'Developer Command Prompt' and running this script from there."
    exit 1
fi

CL_DIR="$(dirname "$CL_BIN")"
export PATH="$CL_DIR:$PATH"
echo "    cl.exe: $CL_BIN"
echo "    link.exe: $(command -v link.exe 2>/dev/null || echo 'not found')"

# Ensure Windows SDK tools (rc.exe, mt.exe) are in PATH.
# vcvarsall.bat sets WindowsSdkDir and WindowsSdkVersion but the bin directory
# may not survive PATH transformations when entering MSYS2.
if ! command -v rc.exe >/dev/null 2>&1; then
    SDK_DIR="${WindowsSdkDir:-}"
    SDK_VER="${WindowsSdkVersion:-}"
    if [ -n "$SDK_DIR" ] && [ -n "$SDK_VER" ]; then
        # Use target-arch SDK tools for cross-compilation
        case "$TARGET_ARCH" in
            aarch64|arm64) SDK_ARCH_DIR="arm64" ;;
            *)             SDK_ARCH_DIR="x64" ;;
        esac
        SDK_BIN="$(cygpath -u "${SDK_DIR}bin/${SDK_VER}${SDK_ARCH_DIR}" 2>/dev/null || true)"
        if [ -d "$SDK_BIN" ] && [ -x "$SDK_BIN/rc.exe" ]; then
            export PATH="$SDK_BIN:$PATH"
            echo "    Added Windows SDK bin to PATH: $SDK_BIN"
        fi
    fi
fi
echo "    rc.exe: $(command -v rc.exe 2>/dev/null || echo 'not found')"
echo "    mt.exe: $(command -v mt.exe 2>/dev/null || echo 'not found')"

# Check MSVC environment (INCLUDE, LIB, etc.)
# These should be set by Start-WindowsBuild.ps1 or by running from a VS Developer Command Prompt.
# Calling vcvarsall.bat from inside MSYS2 bash is unreliable and may hang.
if [ -z "${INCLUDE:-}" ]; then
    echo "    ERROR: MSVC environment not loaded (INCLUDE is empty)."
    echo ""
    echo "    Launch the build using one of these methods:"
    echo "      1. PowerShell:  .\\Start-WindowsBuild.ps1 -BuildOnly"
    echo "      2. Batch file:  run-windows-build.bat"
    echo "      3. VS Developer Command Prompt, then: msys2_shell.cmd -msys -here"
    echo ""
    echo "    The launcher will call vcvarsall.bat before entering MSYS2."
    exit 1
else
    echo "    OK: MSVC environment present"
    echo "    INCLUDE=${INCLUDE:0:80}..."
    echo "    WindowsSdkVersion=${WindowsSdkVersion:-not set}"
fi
echo ""

# -----------------------------------------------------------
# Find Windows Python (NOT MSYS2 python)
# -----------------------------------------------------------
echo ">>> Finding Windows Python..."
WIN_PYTHON="${PYTHON_FOR_BUILD:-${PYTHON:-}}"

case "${WIN_PYTHON:-}" in
    ""|/usr/bin/*|/mingw*/*)
        WIN_PYTHON="$(command -v python.exe 2>/dev/null || true)"
        case "$WIN_PYTHON" in
            ""|/usr/bin/*|/mingw*/*)
                WIN_PYTHON=""
                # Search common install locations
                for candidate in \
                    /c/Users/*/AppData/Local/Programs/Python/Python3*/python.exe \
                    /c/Program\ Files/Python3*/python.exe \
                    /c/Python3*/python.exe \
                    /c/hostedtoolcache/windows/Python/*/x64/python.exe \
                    /c/hostedtoolcache/windows/Python/*/arm64/python.exe; do
                    [ -x "$candidate" ] || continue
                    WIN_PYTHON="$candidate"
                    break
                done
                ;;
        esac
        ;;
esac

if [ -z "$WIN_PYTHON" ] || [ ! -x "$WIN_PYTHON" ]; then
    echo "ERROR: Windows python.exe not found."
    echo "       Install Python from python.org or via: winget install Python.Python.3"
    echo "       MSYS2 python is NOT sufficient — LO needs native Windows paths."
    exit 1
fi

export PYTHON_FOR_BUILD="$WIN_PYTHON"
export PYTHON="$WIN_PYTHON"
echo "    Python: $WIN_PYTHON"
"$WIN_PYTHON" --version 2>/dev/null || true
echo ""

# -----------------------------------------------------------
# NASM (always needed on Windows — even ARM64 cross-compile
# requires it for the x64 cross-toolset OpenSSL build)
# -----------------------------------------------------------
echo ">>> Finding NASM..."
NASM_BIN="${NASM:-}"
if [ -z "$NASM_BIN" ]; then
    NASM_BIN="$(command -v nasm 2>/dev/null || command -v nasm.exe 2>/dev/null || true)"
fi
if [ -z "$NASM_BIN" ]; then
    echo "ERROR: nasm not found. Install it: pacman -S mingw-w64-x86_64-nasm"
    exit 1
fi
export NASM="$NASM_BIN"
echo "    NASM: $NASM_BIN"
"$NASM_BIN" -v 2>/dev/null || true
echo ""

# -----------------------------------------------------------
# CMake (for SlimLO C API build — Step 7)
# -----------------------------------------------------------
echo ">>> Finding CMake..."
CMAKE_BIN="$(command -v cmake 2>/dev/null || command -v cmake.exe 2>/dev/null || true)"
if [ -z "$CMAKE_BIN" ]; then
    # Search in Visual Studio installation
    VS_INSTALL_POSIX="$(cygpath -u "$VS_INSTALL" 2>/dev/null || echo "$VS_INSTALL")"
    for candidate in \
        "$VS_INSTALL_POSIX/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe" \
        /c/Program\ Files/CMake/bin/cmake.exe \
        /c/Program\ Files\ \(x86\)/CMake/bin/cmake.exe; do
        if [ -x "$candidate" ]; then
            CMAKE_BIN="$candidate"
            export PATH="$(dirname "$CMAKE_BIN"):$PATH"
            break
        fi
    done
fi
if [ -n "$CMAKE_BIN" ]; then
    echo "    CMake: $CMAKE_BIN"
    "$CMAKE_BIN" --version 2>/dev/null | head -1 || true
else
    echo "    WARNING: cmake not found — SlimLO C API build (Step 7) will be skipped"
fi
echo ""

# -----------------------------------------------------------
# ICU data filter
# -----------------------------------------------------------
if [ -f "$PROJECT_DIR/icu-filter.json" ]; then
    export ICU_DATA_FILTER_FILE="$(cygpath -m "$PROJECT_DIR/icu-filter.json")"
    echo ">>> ICU filter: $ICU_DATA_FILTER_FILE"
else
    echo "WARNING: icu-filter.json not found in $PROJECT_DIR"
fi
echo ""

# -----------------------------------------------------------
# Build defaults
# -----------------------------------------------------------
export NPROC="${NPROC:-4}"
export LO_SRC_DIR="${LO_SRC_DIR:-$PROJECT_DIR/lo-src}"
export OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/output}"
export SKIP_CONFIGURE="${SKIP_CONFIGURE:-0}"

# -----------------------------------------------------------
# Launch build
# -----------------------------------------------------------
# Export TARGET_ARCH so build.sh can pass --host/--build to configure
export TARGET_ARCH
echo ">>> Launching build.sh (TARGET_ARCH=$TARGET_ARCH)..."
echo ""

if "$SCRIPT_DIR/build.sh"; then
    echo ""
    echo "============================================"
    echo " Windows build succeeded!"
    echo "============================================"
else
    BUILD_EXIT=$?
    echo ""
    echo "============================================"
    echo " Windows build FAILED (exit code $BUILD_EXIT)"
    echo "============================================"
    echo ""
    echo "--- Diagnostic logs ---"

    LO_SRC="${LO_SRC_DIR:-$PROJECT_DIR/lo-src}"

    # HarfBuzz meson log
    HB_LOG="$LO_SRC/workdir/ExternalProject/harfbuzz/meson-logs/meson-log.txt"
    if [ -f "$HB_LOG" ]; then
        echo ""
        echo "=== HarfBuzz meson-log.txt (last 50 lines) ==="
        tail -n 50 "$HB_LOG"
    fi

    # HarfBuzz cross file
    HB_CROSS="$(find "$LO_SRC/workdir/ExternalProject/harfbuzz" -name "*.cross" -o -name "cross_file*" 2>/dev/null | head -1 || true)"
    if [ -n "$HB_CROSS" ] && [ -f "$HB_CROSS" ]; then
        echo ""
        echo "=== HarfBuzz cross file: $HB_CROSS ==="
        cat "$HB_CROSS"
    fi

    # ICU config.log
    ICU_LOG="$LO_SRC/workdir/UnpackedTarball/icu/source/config.log"
    if [ -f "$ICU_LOG" ]; then
        echo ""
        echo "=== ICU config.log (last 50 lines) ==="
        tail -n 50 "$ICU_LOG"
    fi

    exit $BUILD_EXIT
fi
