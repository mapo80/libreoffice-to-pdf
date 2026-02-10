#!/bin/bash
# test.sh — Build and run the SlimLO conversion test inside Docker
#
# Prerequisites:
#   docker build -f docker/Dockerfile.linux-x64 -t slimlo-build .
#
# Usage:
#   ./tests/test.sh
#
# What it does:
#   1. Builds the runtime image (slimlo-runtime) from Dockerfile
#   2. Runs a container that:
#      a. Compiles test_convert.c against libslimlo
#      b. Converts tests/test.docx → /tmp/output.pdf
#      c. Validates the PDF output
#   3. Copies the output PDF to tests/output.pdf for inspection
#
# Note: --security-opt seccomp=unconfined is required because LibreOffice
# uses clone3() for thread creation which Docker's default seccomp profile blocks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_PDF="$SCRIPT_DIR/output.pdf"

echo "=== SlimLO Integration Test ==="
echo ""

# --- Step 1: Build runtime image ---
echo "[Step 1] Building runtime Docker image..."
DOCKER_BUILDKIT=1 docker build \
    -f "$PROJECT_DIR/docker/Dockerfile.linux-x64" \
    --target runtime \
    -t slimlo-runtime \
    "$PROJECT_DIR"

echo ""

# --- Step 2: Generate test.docx if missing ---
if [ ! -f "$SCRIPT_DIR/test.docx" ]; then
    echo "[Step 2] Generating test.docx..."
    python3 "$SCRIPT_DIR/generate_test_docx.py"
else
    echo "[Step 2] test.docx already exists ($(stat -f%z "$SCRIPT_DIR/test.docx" 2>/dev/null || stat -c%s "$SCRIPT_DIR/test.docx" 2>/dev/null) bytes)"
fi

echo ""

# --- Step 3: Run conversion test in Docker ---
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
        for rc in sofficerc fundamentalrc unorc bootstraprc lounorc; do
            if [ -f "/opt/slimlo/program/$rc" ]; then
                echo "  $rc: OK"
            else
                echo "  $rc: MISSING"
            fi
        done
        echo "  services/ dir: $(ls /opt/slimlo/program/services/ 2>/dev/null | wc -l) files"
        echo "  types/ dir: $(ls /opt/slimlo/program/types/ 2>/dev/null | wc -l) files"
        echo "  presets/ dir: $(test -d /opt/slimlo/presets && echo OK || echo MISSING)"
        echo ""

        echo "--- Running conversion test ---"
        /tmp/test_convert /input/test.docx /tmp/output.pdf /opt/slimlo

        echo ""
        echo "--- Copying output PDF ---"
        cp /tmp/output.pdf /output/output.pdf
        echo "PDF saved to tests/output.pdf"
    '

echo ""

# --- Step 4: Verify output on host ---
if [ -f "$OUTPUT_PDF" ]; then
    SIZE=$(stat -f%z "$OUTPUT_PDF" 2>/dev/null || stat -c%s "$OUTPUT_PDF" 2>/dev/null)
    echo "=== SUCCESS ==="
    echo "Output PDF: $OUTPUT_PDF ($SIZE bytes)"

    # Check PDF magic on host side too
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
