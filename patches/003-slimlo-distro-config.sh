#!/bin/bash
# 003-slimlo-distro-config.sh
# Copies the SlimLO.conf distro config into the LO source tree.
# This is NOT a source modification — it just places our config file
# where autogen.sh expects distro configs to be.
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DISTRO_DIR="$LO_SRC/distro-configs"
SLIMLO_CONF="$PROJECT_DIR/distro-configs/SlimLO.conf"

if [ ! -f "$SLIMLO_CONF" ]; then
    echo "    ERROR: SlimLO.conf not found at $SLIMLO_CONF"
    exit 1
fi

# Prepend --enable-slimlo to our config if not already present
if ! grep -q 'enable-slimlo' "$SLIMLO_CONF"; then
    echo "    WARNING: --enable-slimlo not found in SlimLO.conf"
fi

mkdir -p "$DISTRO_DIR"
cp "$SLIMLO_CONF" "$DISTRO_DIR/SlimLO.conf"

echo "    Installed SlimLO.conf to $DISTRO_DIR/"
echo "    Patch 003 complete"
