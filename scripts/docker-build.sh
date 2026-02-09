#!/bin/bash
# docker-build.sh — Build SlimLO using Docker and extract artifacts
#
# Usage:
#   ./scripts/docker-build.sh                    # Build + extract to output/
#   ./scripts/docker-build.sh --runtime           # Also build runtime image
#   ./scripts/docker-build.sh --pack linux-x64   # Build + extract + pack NuGet
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/output"
IMAGE_NAME="slimlo-build"
RUNTIME_IMAGE="slimlo"
BUILD_RUNTIME=false
PACK_RID=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --runtime)
            BUILD_RUNTIME=true
            shift
            ;;
        --pack)
            PACK_RID="${2:?--pack requires a runtime identifier (e.g., linux-x64)}"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: docker-build.sh [--runtime] [--pack <rid>]"
            exit 1
            ;;
    esac
done

echo "============================================"
echo " SlimLO Docker Build"
echo " Output:    $OUTPUT_DIR"
echo "============================================"
echo ""

# Step 1: Build the Docker image (includes full LO build + artifact extraction)
echo ">>> Building Docker image..."
DOCKER_BUILDKIT=1 docker build \
    -f "$PROJECT_DIR/docker/Dockerfile.linux-x64" \
    -t "$IMAGE_NAME" \
    "$PROJECT_DIR"

# Step 2: Extract artifacts from Docker image to host
echo ""
echo ">>> Extracting artifacts to $OUTPUT_DIR..."
mkdir -p "$OUTPUT_DIR"
docker run --rm \
    -v "$OUTPUT_DIR:/output" \
    "$IMAGE_NAME"

echo ""
echo ">>> Artifacts extracted:"
du -sh "$OUTPUT_DIR"

# Step 3: Optionally build runtime image
if [ "$BUILD_RUNTIME" = true ]; then
    echo ""
    echo ">>> Building runtime image..."
    DOCKER_BUILDKIT=1 docker build \
        -f "$PROJECT_DIR/docker/Dockerfile.linux-x64" \
        --target runtime \
        -t "$RUNTIME_IMAGE" \
        "$PROJECT_DIR"
    echo "    Runtime image: $RUNTIME_IMAGE"
    docker images "$RUNTIME_IMAGE" --format "    Size: {{.Size}}"
fi

# Step 4: Optionally pack NuGet packages
if [ -n "$PACK_RID" ]; then
    echo ""
    echo ">>> Packing NuGet packages for $PACK_RID..."
    "$SCRIPT_DIR/pack-nuget.sh" "$PACK_RID" "$OUTPUT_DIR"
fi

echo ""
echo "============================================"
echo " Build complete!"
echo "============================================"
