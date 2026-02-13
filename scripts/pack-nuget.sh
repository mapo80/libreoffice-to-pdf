#!/bin/bash
# pack-nuget.sh — Build NuGet packages from SlimLO build output
#
# Usage:
#   ./scripts/pack-nuget.sh linux output-linux-x64/ output-linux-arm64/
#   ./scripts/pack-nuget.sh linux output-linux-x64/   # single-arch OK
#   ./scripts/pack-nuget.sh macos output-macos-arm64/ output-macos-x64/
#
# Produces:
#   dotnet/nupkgs/SlimLO.0.1.0.nupkg
#   dotnet/nupkgs/SlimLO.NativeAssets.{Linux,macOS}.0.1.0.nupkg
set -euo pipefail

PLATFORM="${1:?Usage: pack-nuget.sh <platform> <native-dir-x64> [native-dir-arm64]}"
NATIVE_DIR_1="${2:?Usage: pack-nuget.sh <platform> <native-dir-x64> [native-dir-arm64]}"
NATIVE_DIR_2="${3:-}"   # optional second arch

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NUPKG_DIR="$ROOT_DIR/dotnet/nupkgs"

mkdir -p "$NUPKG_DIR"

# ── Managed package ──────────────────────────────────────────────────
echo "=== Packing SlimLO managed package ==="
dotnet pack "$ROOT_DIR/dotnet/SlimLO/SlimLO.csproj" \
    -c Release \
    -o "$NUPKG_DIR"

# ── Native assets package ────────────────────────────────────────────
case "$PLATFORM" in
    linux)
        CSPROJ="$ROOT_DIR/dotnet/SlimLO.NativeAssets.Linux/SlimLO.NativeAssets.Linux.csproj"
        PACK_ARGS=(-p:NativeDir_x64="$NATIVE_DIR_1")
        if [ -n "$NATIVE_DIR_2" ]; then
            PACK_ARGS+=(-p:NativeDir_arm64="$NATIVE_DIR_2")
        fi
        ;;
    macos)
        CSPROJ="$ROOT_DIR/dotnet/SlimLO.NativeAssets.macOS/SlimLO.NativeAssets.macOS.csproj"
        PACK_ARGS=(-p:NativeDir_arm64="$NATIVE_DIR_1")
        if [ -n "$NATIVE_DIR_2" ]; then
            PACK_ARGS+=(-p:NativeDir_x64="$NATIVE_DIR_2")
        fi
        ;;
    *)
        echo "Error: Unknown platform '$PLATFORM'. Supported: linux, macos"
        exit 1
        ;;
esac

echo ""
echo "=== Packing SlimLO.NativeAssets.${PLATFORM^} ==="
dotnet pack "$CSPROJ" \
    -c Release \
    -o "$NUPKG_DIR" \
    "${PACK_ARGS[@]}"

echo ""
echo "=== Packages created ==="
ls -la "$NUPKG_DIR"/*.nupkg 2>/dev/null || echo "No .nupkg files found"
