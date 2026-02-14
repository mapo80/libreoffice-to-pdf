#!/bin/bash
# windows-build.sh — Windows build wrapper for SlimLO.
# Configures the MSYS2 environment to match the CI and launches build.sh.
# Run inside an MSYS2 shell (MSYS, not MINGW64).
# Supports both ARM64 and x64 Windows.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

HOST_ARCH="$(uname -m 2>/dev/null || echo unknown)"

echo "============================================"
echo " SlimLO — Windows Build ($HOST_ARCH)"
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

    case "$HOST_ARCH" in
        aarch64|arm64)
            # ARM64 native compiler
            CL_BIN="$(find "$VS_INSTALL_POSIX/VC/Tools/MSVC" -path "*/Hostarm64/arm64/cl.exe" 2>/dev/null | head -1 || true)"
            if [ -z "$CL_BIN" ]; then
                # Fallback: ARM64 cross-compiler from x64 host tools (runs under emulation)
                CL_BIN="$(find "$VS_INSTALL_POSIX/VC/Tools/MSVC" -path "*/Hostx64/arm64/cl.exe" 2>/dev/null | head -1 || true)"
            fi
            ;;
        x86_64|i686)
            CL_BIN="$(find "$VS_INSTALL_POSIX/VC/Tools/MSVC" -path "*/Hostx64/x64/cl.exe" 2>/dev/null | head -1 || true)"
            ;;
    esac
fi

if [ -z "$CL_BIN" ]; then
    echo "ERROR: cl.exe not found for $HOST_ARCH"
    echo "       Ensure Visual Studio C++ tools are installed for your architecture."
    echo "       Try opening a 'Developer Command Prompt' and running this script from there."
    exit 1
fi

CL_DIR="$(dirname "$CL_BIN")"
export PATH="$CL_DIR:$PATH"
echo "    cl.exe: $CL_BIN"
echo "    link.exe: $(command -v link.exe 2>/dev/null || echo 'not found')"

# Also need MSVC lib.exe, headers, etc. — set up INCLUDE/LIB if not already set
# (If run from a Developer Command Prompt, these are already set.)
if [ -z "${INCLUDE:-}" ]; then
    echo "    NOTE: INCLUDE not set. For best results, run from a VS Developer Command Prompt."
    echo "          Or run: source \"$VS_INSTALL\\VC\\Auxiliary\\Build\\vcvarsall.bat\" $HOST_ARCH"
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
# NASM (x86/x64 only — not needed on ARM64)
# -----------------------------------------------------------
case "$HOST_ARCH" in
    x86_64|i686)
        echo ">>> Finding NASM (x86 SIMD)..."
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
        ;;
    aarch64|arm64)
        echo ">>> ARM64 detected — NASM not required (x86 SIMD only)"
        echo ""
        ;;
esac

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

# -----------------------------------------------------------
# Launch build
# -----------------------------------------------------------
echo ">>> Launching build.sh..."
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
