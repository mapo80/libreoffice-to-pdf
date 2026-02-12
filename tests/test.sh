#!/bin/bash
# test.sh — SlimLO DOCX→PDF conversion test
#
# Cross-platform: runs natively on macOS/Linux, or via Docker on Linux.
#
# Usage:
#   ./tests/test.sh                              # auto-detect mode
#   SLIMLO_DIR=./output-macos ./tests/test.sh    # custom artifact dir
#   SLIMLO_TEST_MODE=docker ./tests/test.sh      # force Docker mode
#
# Environment variables:
#   SLIMLO_DIR         Path to extracted SlimLO artifacts (default: auto)
#   SLIMLO_TEST_MODE   "native" or "docker" (default: auto-detect)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_PDF="$SCRIPT_DIR/output.pdf"
TEST_BINARY="/tmp/slimlo_test_convert"
TEST_OUTPUT="/tmp/slimlo-test-output.pdf"

# -----------------------------------------------------------
# Detect mode and artifact directory
# -----------------------------------------------------------
SLIMLO_DIR="${SLIMLO_DIR:-}"
MODE="${SLIMLO_TEST_MODE:-}"

if [ -z "$SLIMLO_DIR" ]; then
    case "$(uname -s)" in
        Darwin) SLIMLO_DIR="$PROJECT_DIR/output-macos" ;;
        *)      SLIMLO_DIR="$PROJECT_DIR/output" ;;
    esac
fi

# Resolve to absolute path
SLIMLO_DIR="$(cd "$SLIMLO_DIR" 2>/dev/null && pwd)" || {
    echo "ERROR: Artifact directory not found: $SLIMLO_DIR"
    echo "Run ./scripts/build.sh first, or set SLIMLO_DIR=/path/to/artifacts"
    exit 1
}

if [ -z "$MODE" ]; then
    case "$(uname -s)" in
        Darwin) MODE="native" ;;
        *)
            if [ -d "$SLIMLO_DIR/program" ]; then
                MODE="native"
            elif command -v docker &>/dev/null; then
                MODE="docker"
            else
                MODE="native"
            fi
            ;;
    esac
fi

echo "=== SlimLO Integration Test ==="
echo "Mode:      $MODE"
echo "Artifacts: $SLIMLO_DIR"
echo ""

# -----------------------------------------------------------
# Generate test.docx if missing
# -----------------------------------------------------------
if [ ! -f "$SCRIPT_DIR/test.docx" ]; then
    echo "[Step 1] Generating test.docx..."
    python3 "$SCRIPT_DIR/generate_test_docx.py"
else
    SIZE=$(stat -f%z "$SCRIPT_DIR/test.docx" 2>/dev/null || stat -c%s "$SCRIPT_DIR/test.docx" 2>/dev/null)
    echo "[Step 1] test.docx exists ($SIZE bytes)"
fi
echo ""

# ===============================================================
# NATIVE MODE
# ===============================================================
if [ "$MODE" = "native" ]; then

    # --- Check artifacts ---
    echo "[Step 2] Checking artifacts..."
    MERGED_LIB=""
    for ext in dylib so dll; do
        if [ -f "$SLIMLO_DIR/program/libmergedlo.$ext" ]; then
            MERGED_LIB="$SLIMLO_DIR/program/libmergedlo.$ext"
            MERGED_SIZE=$(du -sh "$MERGED_LIB" | cut -f1)
            echo "  libmergedlo.$ext: OK ($MERGED_SIZE)"
            break
        fi
    done
    if [ -z "$MERGED_LIB" ]; then
        echo "  ERROR: libmergedlo.{so,dylib,dll} not found in $SLIMLO_DIR/program/"
        exit 1
    fi

    SLIMLO_LIB=""
    for ext in dylib so dll; do
        if [ -f "$SLIMLO_DIR/program/libslimlo.$ext" ] || [ -L "$SLIMLO_DIR/program/libslimlo.$ext" ]; then
            SLIMLO_LIB="found"
            echo "  libslimlo.$ext: OK"
            break
        fi
    done
    if [ -z "$SLIMLO_LIB" ]; then
        echo "  ERROR: libslimlo.{so,dylib,dll} not found in $SLIMLO_DIR/program/"
        exit 1
    fi

    # Check bootstrap RC chain
    # macOS chain: sofficerc → fundamentalrc → lounorc (no separate unorc)
    # Linux chain: sofficerc → fundamentalrc → unorc + lounorc
    case "$(uname -s)" in
        Darwin) RC_FILES="sofficerc fundamentalrc lounorc" ;;
        *)      RC_FILES="sofficerc fundamentalrc unorc lounorc" ;;
    esac
    for rc in $RC_FILES; do
        if [ -f "$SLIMLO_DIR/program/$rc" ]; then
            echo "  $rc: OK"
        else
            echo "  $rc: MISSING (may cause init failure)"
        fi
    done
    if [ -d "$SLIMLO_DIR/presets" ]; then
        echo "  presets/: OK"
    else
        echo "  presets/: MISSING (will cause fatal error)"
        exit 1
    fi

    # Check include header
    if [ ! -f "$SLIMLO_DIR/include/slimlo.h" ]; then
        echo "  ERROR: slimlo.h not found in $SLIMLO_DIR/include/"
        exit 1
    fi
    echo ""

    # --- Compile test program ---
    echo "[Step 3] Compiling test program..."
    cc -o "$TEST_BINARY" "$SCRIPT_DIR/test_convert.c" \
        -I"$SLIMLO_DIR/include" \
        -L"$SLIMLO_DIR/program" -lslimlo \
        -Wl,-rpath,"$SLIMLO_DIR/program"
    echo "  OK"
    echo ""

    # --- Run conversion test ---
    echo "[Step 4] Running conversion test..."
    rm -f "$TEST_OUTPUT"

    # Set library path as fallback (rpath should handle it, but just in case)
    case "$(uname -s)" in
        Darwin) export DYLD_LIBRARY_PATH="$SLIMLO_DIR/program${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" ;;
        *)      export LD_LIBRARY_PATH="$SLIMLO_DIR/program${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;;
    esac

    "$TEST_BINARY" "$SCRIPT_DIR/test.docx" "$TEST_OUTPUT" "$SLIMLO_DIR"
    echo ""

    # --- Validate and copy output ---
    if [ -f "$TEST_OUTPUT" ]; then
        cp "$TEST_OUTPUT" "$OUTPUT_PDF"
        rm -f "$TEST_OUTPUT" "$TEST_BINARY"
    fi

# ===============================================================
# DOCKER MODE
# ===============================================================
elif [ "$MODE" = "docker" ]; then

    echo "[Step 2] Building runtime Docker image..."
    DOCKER_BUILDKIT=1 docker build \
        -f "$PROJECT_DIR/docker/Dockerfile.linux-x64" \
        --target runtime \
        -t slimlo-runtime \
        "$PROJECT_DIR"
    echo ""

    echo "[Step 3] Running conversion test in Docker container..."
    docker run --rm \
        --security-opt seccomp=unconfined \
        -v "$SCRIPT_DIR/test.docx:/input/test.docx:ro" \
        -v "$SCRIPT_DIR/test_convert.c:/input/test_convert.c:ro" \
        -v "$SCRIPT_DIR:/output" \
        slimlo-runtime \
        sh -c '
            set -e
            echo "--- Compiling test program ---"
            apt-get update -qq && apt-get -y -qq install gcc > /dev/null 2>&1
            gcc -o /tmp/test_convert /input/test_convert.c \
                -I/opt/slimlo/include \
                -L/opt/slimlo/program -lslimlo \
                -Wl,-rpath,/opt/slimlo/program

            echo ""
            echo "--- Checking bootstrap RC files ---"
            for rc in sofficerc fundamentalrc unorc lounorc; do
                if [ -f "/opt/slimlo/program/$rc" ]; then
                    echo "  $rc: OK"
                else
                    echo "  $rc: MISSING"
                fi
            done
            echo "  presets/ dir: $(test -d /opt/slimlo/presets && echo OK || echo MISSING)"
            echo ""

            echo "--- Running conversion test ---"
            /tmp/test_convert /input/test.docx /tmp/output.pdf /opt/slimlo

            echo ""
            cp /tmp/output.pdf /output/output.pdf
        '
    echo ""

else
    echo "ERROR: Unknown mode: $MODE (expected 'native' or 'docker')"
    exit 1
fi

# -----------------------------------------------------------
# Verify output on host
# -----------------------------------------------------------
if [ -f "$OUTPUT_PDF" ]; then
    SIZE=$(stat -f%z "$OUTPUT_PDF" 2>/dev/null || stat -c%s "$OUTPUT_PDF" 2>/dev/null)
    echo "=== SUCCESS ==="
    echo "Output PDF: $OUTPUT_PDF ($SIZE bytes)"

    MAGIC=$(head -c 4 "$OUTPUT_PDF")
    if [ "$MAGIC" = "%PDF" ]; then
        echo "PDF validation: OK"
    else
        echo "PDF validation: FAILED (not a valid PDF)"
        exit 1
    fi
else
    echo "=== FAILED ==="
    echo "Output PDF not found at $OUTPUT_PDF"
    exit 1
fi
