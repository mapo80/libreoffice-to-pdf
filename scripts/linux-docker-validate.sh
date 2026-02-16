#!/bin/bash
# linux-docker-validate.sh — Build and validate Linux SlimLO artifacts via Docker.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

IMAGE_NAME="${IMAGE_NAME:-slimlo-linux-validate}"
DOCKERFILE="${DOCKERFILE:-$PROJECT_DIR/docker/Dockerfile.linux-x64}"
NPROC="${NPROC:-10}"
OUTPUT_SUBDIR="${OUTPUT_SUBDIR:-output-linux-docker}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SLIMLO_DEP_STEP="${SLIMLO_DEP_STEP:-0}"

if [[ "$OUTPUT_SUBDIR" = /* ]]; then
    echo "ERROR: OUTPUT_SUBDIR must be project-relative (got absolute path: $OUTPUT_SUBDIR)"
    exit 1
fi
if [[ "$OUTPUT_SUBDIR" == *".."* ]]; then
    echo "ERROR: OUTPUT_SUBDIR must not contain '..' (got: $OUTPUT_SUBDIR)"
    exit 1
fi

OUTPUT_DIR="$PROJECT_DIR/$OUTPUT_SUBDIR"

case "$SLIMLO_DEP_STEP" in
    ''|*[!0-9]*)
        echo "ERROR: SLIMLO_DEP_STEP must be an integer >= 0 (got '$SLIMLO_DEP_STEP')"
        exit 1
        ;;
esac

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker is required."
    exit 1
fi

if [ ! -f "$DOCKERFILE" ]; then
    echo "ERROR: Dockerfile not found: $DOCKERFILE"
    exit 1
fi

echo "=== SlimLO Linux Docker Validation ==="
echo "Image:      $IMAGE_NAME"
echo "Dockerfile: $DOCKERFILE"
echo "NPROC:      $NPROC"
echo "Output:     $OUTPUT_DIR"
echo "Dep step:   $SLIMLO_DEP_STEP"
echo ""

if [ "$SKIP_BUILD" != "1" ]; then
    echo ">>> [1/3] Building Linux Docker image"
    DOCKER_BUILDKIT=1 docker build \
        -f "$DOCKERFILE" \
        --build-arg NPROC="$NPROC" \
        --build-arg SLIMLO_DEP_STEP="$SLIMLO_DEP_STEP" \
        -t "$IMAGE_NAME" \
        "$PROJECT_DIR"
else
    echo ">>> [1/3] Skipping build (SKIP_BUILD=1)"
fi

echo ""
echo ">>> [2/3] Running Linux validation gates in container"
docker run --rm \
    -v "$PROJECT_DIR:/workspace" \
    -w /workspace \
    -e OUTPUT_SUBDIR="$OUTPUT_SUBDIR" \
    -e SLIMLO_DEP_STEP="$SLIMLO_DEP_STEP" \
    "$IMAGE_NAME" \
    bash -lc '
set -euo pipefail

OUT="/workspace/$OUTPUT_SUBDIR"
rm -rf "$OUT"
mkdir -p "$OUT"
cp -a /artifacts/. "$OUT/"

chmod +x /workspace/scripts/*.sh || true
chmod +x /workspace/tests/test.sh || true

echo "  - assert configured feature set"
SLIMLO_DEP_STEP="${SLIMLO_DEP_STEP:-0}" /workspace/scripts/assert-config-features.sh /build/lo-src/config_host.mk linux

echo "  - run C/.NET gate"
GATE_ENABLE_DOTNET=0 /workspace/scripts/run-gate.sh "$OUT" \
    | tee "$OUT/gate-linux.log"

echo "  - dependency allowlist gate"
/workspace/scripts/check-deps-allowlist.sh \
    "$OUT" \
    /workspace/artifacts/deps-allowlist-linux.txt \
    | tee "$OUT/deps-gate-linux.log"

echo "  - write metadata + size reports"
/workspace/scripts/write-build-metadata.sh "$OUT" "$OUT/build-metadata.json"
/workspace/scripts/measure-artifact.sh "$OUT" "$OUT/size-report.json" "$OUT/size-report.txt"
'

echo ""
echo ">>> [3/3] Validation summary"
sed -n '1,80p' "$OUTPUT_DIR/size-report.txt"
echo ""
echo "Generated files:"
ls -1 "$OUTPUT_DIR" | sed 's/^/  - /'
echo ""
echo "PASS: Linux Docker validation completed"
