#!/bin/bash
# windows-debug-harfbuzz.sh — Debug harfbuzz meson build in isolation.
# Prerequisite: at least one run of windows-build.sh through configure (autogen.sh).
# Run inside an MSYS2 shell (MSYS, not MINGW64).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LO_SRC_DIR="${LO_SRC_DIR:-$PROJECT_DIR/lo-src}"

HOST_ARCH="$(uname -m 2>/dev/null || echo unknown)"

echo "============================================"
echo " SlimLO — HarfBuzz Debug Build ($HOST_ARCH)"
echo "============================================"
echo ""

# -----------------------------------------------------------
# Verify LO source is configured
# -----------------------------------------------------------
if [ ! -f "$LO_SRC_DIR/config_host.mk" ]; then
    echo "ERROR: $LO_SRC_DIR/config_host.mk not found."
    echo "       Run windows-build.sh at least once to clone + configure."
    exit 1
fi
echo ">>> LO source: $LO_SRC_DIR"
echo ">>> config_host.mk found"
echo ""

# -----------------------------------------------------------
# Show current MSVC/build configuration
# -----------------------------------------------------------
echo "--- Build configuration ---"
for var in gb_CC gb_CXX gb_LINK USE_LD AR STRIP CPUNAME OS; do
    VAL="$(grep "^export $var=" "$LO_SRC_DIR/config_host.mk" 2>/dev/null | head -1 | sed 's/^export [^=]*=//' || echo '(not set)')"
    echo "    $var = $VAL"
done
echo ""

# -----------------------------------------------------------
# Re-apply patch 020 (harfbuzz meson path fix)
# -----------------------------------------------------------
PATCH_020="$PROJECT_DIR/patches/020-fix-harfbuzz-meson-msvc-path.sh"
if [ -f "$PATCH_020" ]; then
    echo ">>> Re-applying patch 020..."

    # Restore original file from git first (idempotent re-apply)
    HARFBUZZ_MK="$LO_SRC_DIR/external/harfbuzz/ExternalProject_harfbuzz.mk"
    if [ -f "$HARFBUZZ_MK" ]; then
        git -C "$LO_SRC_DIR" checkout -- external/harfbuzz/ExternalProject_harfbuzz.mk 2>/dev/null || true
    fi

    bash "$PATCH_020" "$LO_SRC_DIR"
    echo ""
else
    echo ">>> Patch 020 not found at $PATCH_020 — skipping"
    echo ""
fi

# -----------------------------------------------------------
# Show patched harfbuzz makefile (relevant sections)
# -----------------------------------------------------------
HARFBUZZ_MK="$LO_SRC_DIR/external/harfbuzz/ExternalProject_harfbuzz.mk"
if [ -f "$HARFBUZZ_MK" ]; then
    echo "--- Patched ExternalProject_harfbuzz.mk (cross_path_to_native + cross vars) ---"
    grep -n "cross_path_to_native\|cross_cc\|cross_cxx\|cross_ld\|cross_ar\|cross_strip\|python_listify\|^ar =\|^strip =" "$HARFBUZZ_MK" 2>/dev/null || echo "(no matching lines)"
    echo ""
fi

# -----------------------------------------------------------
# Clean previous harfbuzz build
# -----------------------------------------------------------
echo ">>> Cleaning previous harfbuzz build..."
rm -rf "$LO_SRC_DIR/workdir/ExternalProject/harfbuzz" 2>/dev/null || true
echo "    Removed workdir/ExternalProject/harfbuzz"
echo ""

# -----------------------------------------------------------
# Prevent MSBuild/gbuild env issues (same as windows-build.sh)
# -----------------------------------------------------------
unset MSYSTEM 2>/dev/null || true
unset WSL 2>/dev/null || true
unset UCRTVersion 2>/dev/null || true

# -----------------------------------------------------------
# Build just harfbuzz
# -----------------------------------------------------------
echo ">>> Building ExternalProject_harfbuzz..."
echo "    Command: make ExternalProject_harfbuzz"
echo ""

cd "$LO_SRC_DIR"
BUILD_LOG="$PROJECT_DIR/harfbuzz-build.log"

if MSYSTEM= WSL= make ExternalProject_harfbuzz 2>&1 | tee "$BUILD_LOG"; then
    echo ""
    echo "============================================"
    echo " HarfBuzz build SUCCEEDED!"
    echo "============================================"
else
    BUILD_EXIT=$?
    echo ""
    echo "============================================"
    echo " HarfBuzz build FAILED (exit code $BUILD_EXIT)"
    echo "============================================"
    echo ""

    # --- Diagnostic: meson log ---
    MESON_LOG="$LO_SRC_DIR/workdir/ExternalProject/harfbuzz/meson-logs/meson-log.txt"
    if [ -f "$MESON_LOG" ]; then
        echo "=== meson-log.txt (last 80 lines) ==="
        tail -n 80 "$MESON_LOG"
        echo ""
    else
        echo "    meson-log.txt not found at: $MESON_LOG"
        # Search for it
        FOUND_LOG="$(find "$LO_SRC_DIR/workdir/ExternalProject/harfbuzz" -name "meson-log.txt" 2>/dev/null | head -1 || true)"
        if [ -n "$FOUND_LOG" ]; then
            echo "    Found at: $FOUND_LOG"
            echo "=== meson-log.txt (last 80 lines) ==="
            tail -n 80 "$FOUND_LOG"
            echo ""
        fi
    fi

    # --- Diagnostic: cross file ---
    echo "--- Searching for meson cross files ---"
    find "$LO_SRC_DIR/workdir/ExternalProject/harfbuzz" -name "*.cross" -o -name "cross_file*" -o -name "*.ini" 2>/dev/null | while read -r f; do
        echo ""
        echo "=== $f ==="
        cat "$f"
    done

    # --- Diagnostic: check if cl.exe path is reachable from Windows Python ---
    CL_PATH="$(command -v cl.exe 2>/dev/null || true)"
    if [ -n "$CL_PATH" ]; then
        echo ""
        echo "--- cl.exe reachability test ---"
        echo "    POSIX path: $CL_PATH"
        if command -v cygpath >/dev/null 2>&1; then
            WIN_CL="$(cygpath -m "$CL_PATH")"
            echo "    Windows path: $WIN_CL"
        fi

        WIN_PYTHON="${PYTHON_FOR_BUILD:-${PYTHON:-}}"
        if [ -n "$WIN_PYTHON" ] && [ -x "$WIN_PYTHON" ]; then
            echo "    Testing Python subprocess..."
            "$WIN_PYTHON" -c "import subprocess; r = subprocess.run(['$(cygpath -m "$CL_PATH" 2>/dev/null || echo "$CL_PATH")'], capture_output=True); print('returncode:', r.returncode)" 2>&1 || echo "    (Python test failed)"
        fi
    fi

    echo ""
    echo "Full build log: $BUILD_LOG"
    exit $BUILD_EXIT
fi
