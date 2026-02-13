#!/bin/bash
# run.sh — Build and run the SlimLO example
#
# Usage:
#   ./run.sh                    # macOS local test
#   ./run.sh docker             # Linux Docker test (x64)
#   ./run.sh docker-arm64       # Linux Docker test (arm64)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NUPKG_DIR="$ROOT_DIR/dotnet/nupkgs"
TEST_DOCX="$ROOT_DIR/tests/test.docx"
MODE="${1:-local}"

# ── Step 1: Rebuild NuGet packages ──────────────────────────────────
echo "=== Rebuilding NuGet packages ==="
rm -f "$NUPKG_DIR"/*.nupkg

# Managed package
dotnet pack "$ROOT_DIR/dotnet/SlimLO/SlimLO.csproj" -c Release -o "$NUPKG_DIR" -v quiet

# Linux native package
dotnet pack "$ROOT_DIR/dotnet/SlimLO.NativeAssets.Linux/SlimLO.NativeAssets.Linux.csproj" \
    -c Release -o "$NUPKG_DIR" -v quiet \
    -p:NativeDir_x64="$ROOT_DIR/output-linux-x64/"

# macOS native package
dotnet pack "$ROOT_DIR/dotnet/SlimLO.NativeAssets.macOS/SlimLO.NativeAssets.macOS.csproj" \
    -c Release -o "$NUPKG_DIR" -v quiet \
    -p:NativeDir_arm64="$ROOT_DIR/output-macos/"

echo "Packages:"
ls -lh "$NUPKG_DIR"/*.nupkg

# Clear NuGet cache for our packages (force re-resolve)
dotnet nuget locals http-cache --clear > /dev/null 2>&1 || true
for pkg in SlimLO SlimLO.NativeAssets.Linux SlimLO.NativeAssets.macOS; do
    local_cache="$HOME/.nuget/packages/$(echo "$pkg" | tr '[:upper:]' '[:lower:]')"
    rm -rf "$local_cache" 2>/dev/null || true
done

# ── Step 2: Run based on mode ──────────────────────────────────────
case "$MODE" in
    local)
        echo ""
        echo "=== Running on local macOS ==="
        cd "$SCRIPT_DIR"
        dotnet restore --force
        dotnet run -- "$TEST_DOCX" /tmp/slimlo-example-output.pdf
        echo "Output: /tmp/slimlo-example-output.pdf"
        file /tmp/slimlo-example-output.pdf
        ;;

    docker|docker-x64)
        echo ""
        echo "=== Publishing for linux-x64 ==="
        cd "$SCRIPT_DIR"
        dotnet restore --force
        dotnet publish -c Release -r linux-x64 -o publish/linux-x64 --self-contained false

        echo ""
        echo "=== Building Docker image (x64) ==="
        docker build -t slimlo-example "$SCRIPT_DIR"

        echo ""
        echo "=== Running in Docker ==="
        cp "$TEST_DOCX" "$SCRIPT_DIR/test-input.docx"
        docker run --rm \
            --security-opt seccomp=unconfined \
            -v "$SCRIPT_DIR:/data" \
            slimlo-example /data/test-input.docx /data/test-output.pdf
        echo "Output: $SCRIPT_DIR/test-output.pdf"
        file "$SCRIPT_DIR/test-output.pdf"
        rm -f "$SCRIPT_DIR/test-input.docx"
        ;;

    docker-arm64)
        echo ""
        echo "=== Publishing for linux-arm64 ==="
        cd "$SCRIPT_DIR"
        dotnet restore --force
        dotnet publish -c Release -r linux-arm64 -o publish/linux-arm64 --self-contained false

        echo ""
        echo "=== Building Docker image (arm64) ==="
        # Override COPY path in Dockerfile
        docker build --platform linux/arm64 \
            -f - -t slimlo-example-arm64 "$SCRIPT_DIR" <<'DOCKERFILE'
FROM mcr.microsoft.com/dotnet/runtime:8.0
RUN apt-get update && apt-get install -y --no-install-recommends \
    libfontconfig1 libfreetype6 libcairo2 libxml2 libxslt1.1 \
    libnss3 fonts-liberation \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY publish/linux-arm64/ .
RUN mkdir -p /app/presets
ENTRYPOINT ["dotnet", "Example.dll"]
DOCKERFILE

        echo ""
        echo "=== Running in Docker (arm64) ==="
        cp "$TEST_DOCX" "$SCRIPT_DIR/test-input.docx"
        docker run --rm \
            --platform linux/arm64 \
            --security-opt seccomp=unconfined \
            -v "$SCRIPT_DIR:/data" \
            slimlo-example-arm64 /data/test-input.docx /data/test-output.pdf
        echo "Output: $SCRIPT_DIR/test-output.pdf"
        file "$SCRIPT_DIR/test-output.pdf"
        rm -f "$SCRIPT_DIR/test-input.docx"
        ;;

    *)
        echo "Usage: $0 [local|docker|docker-arm64]"
        exit 1
        ;;
esac
