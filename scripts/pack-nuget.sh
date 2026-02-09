#!/bin/bash
# pack-nuget.sh — Build NuGet packages from SlimLO build output
#
# Usage:
#   ./scripts/pack-nuget.sh linux-x64 output/
#   ./scripts/pack-nuget.sh osx-arm64 output/
#
# Produces:
#   dotnet/nupkgs/SlimLO.0.1.0.nupkg
#   dotnet/nupkgs/SlimLO.Native.linux-x64.0.1.0.nupkg
set -euo pipefail

RID="${1:?Usage: pack-nuget.sh <runtime-identifier> <native-output-dir>}"
NATIVE_DIR="${2:?Usage: pack-nuget.sh <runtime-identifier> <native-output-dir>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NUPKG_DIR="$ROOT_DIR/dotnet/nupkgs"

mkdir -p "$NUPKG_DIR"

echo "=== Packing SlimLO managed package ==="
dotnet pack "$ROOT_DIR/dotnet/SlimLO/SlimLO.csproj" \
    -c Release \
    -o "$NUPKG_DIR"

echo ""
echo "=== Packing SlimLO.Native.$RID ==="
dotnet pack "$ROOT_DIR/dotnet/SlimLO.Native/SlimLO.Native.csproj" \
    -c Release \
    -o "$NUPKG_DIR" \
    -p:RuntimeIdentifier="$RID" \
    -p:NativeDir="$NATIVE_DIR/"

echo ""
echo "=== Packages created ==="
ls -la "$NUPKG_DIR"/*.nupkg 2>/dev/null || echo "No .nupkg files found"
