#!/bin/bash
# setup-windows-msys2.sh — One-time MSYS2 environment setup for SlimLO Windows builds.
# Run this inside an MSYS2 shell (MSYS, not MINGW64).
# Idempotent: safe to re-run.
set -euo pipefail

echo "============================================"
echo " SlimLO — MSYS2 Setup for Windows Build"
echo "============================================"
echo ""

HOST_ARCH="$(uname -m 2>/dev/null || echo unknown)"
echo "Host architecture: $HOST_ARCH"
echo ""

# -----------------------------------------------------------
# Step 1: Install base MSYS2 packages
# -----------------------------------------------------------
echo ">>> Step 1: Installing base MSYS2 packages..."
pacman -S --noconfirm --needed \
    autoconf automake bison flex gperf libtool make \
    patch pkg-config zip unzip wget perl python3 \
    python-setuptools findutils git
echo ""

# -----------------------------------------------------------
# Step 2: Install MinGW64 packages (architecture-dependent)
# -----------------------------------------------------------
echo ">>> Step 2: Installing MinGW64 packages..."
# pkgconf is needed by LO configure regardless of target architecture.
# On ARM64 Windows, mingw-w64-x86_64-pkgconf runs under x86 emulation.
pacman -S --noconfirm --needed mingw-w64-x86_64-pkgconf

case "$HOST_ARCH" in
    x86_64|i686)
        echo "    x86/x64 host — installing NASM"
        pacman -S --noconfirm --needed mingw-w64-x86_64-nasm
        ;;
    aarch64|arm64)
        echo "    ARM64 host — NASM not required (x86 SIMD only)"
        ;;
    *)
        echo "    Unknown architecture $HOST_ARCH — skipping NASM"
        ;;
esac
echo ""

# -----------------------------------------------------------
# Step 3: Create pkgconf-2.4.3.exe wrapper
# -----------------------------------------------------------
echo ">>> Step 3: Creating pkgconf-2.4.3.exe wrapper..."
mkdir -p /usr/local/bin

cat >/usr/local/bin/pkgconf-2.4.3.exe <<'WRAPPER'
#!/usr/bin/env bash
export PATH="/mingw64/bin:$PATH"
exec /mingw64/bin/pkgconf.exe "$@"
WRAPPER
chmod +x /usr/local/bin/pkgconf-2.4.3.exe

# LO also looks for pkg-config
ln -sf /usr/local/bin/pkgconf-2.4.3.exe /usr/local/bin/pkg-config
echo "    Created /usr/local/bin/pkgconf-2.4.3.exe"
echo "    Symlinked pkg-config → pkgconf-2.4.3.exe"
echo ""

# -----------------------------------------------------------
# Step 4: Create wslpath shim
# -----------------------------------------------------------
echo ">>> Step 4: Creating wslpath shim..."
if command -v cygpath >/dev/null 2>&1; then
    ln -sf /usr/bin/cygpath /usr/local/bin/wslpath
    echo "    Symlinked /usr/local/bin/wslpath → cygpath"
else
    echo "    WARNING: cygpath not found — wslpath shim not created"
fi
echo ""

# -----------------------------------------------------------
# Step 5: Verify tools
# -----------------------------------------------------------
echo ">>> Step 5: Verifying tools..."

# Add MinGW64 bin to PATH for NASM verification
export PATH="/mingw64/bin:$PATH"

ERRORS=0

check_tool() {
    local name="$1"
    if command -v "$name" >/dev/null 2>&1; then
        echo "    OK: $name → $(command -v "$name")"
    else
        echo "    MISSING: $name"
        ERRORS=$((ERRORS + 1))
    fi
}

check_tool autoconf
check_tool automake
check_tool bison
check_tool flex
check_tool gperf
check_tool libtool
check_tool make
check_tool perl
check_tool python3
check_tool git
check_tool pkgconf-2.4.3.exe
check_tool pkg-config
check_tool wslpath

case "$HOST_ARCH" in
    x86_64|i686)
        check_tool nasm
        ;;
esac

echo ""
echo "--- Tool versions ---"
pkgconf-2.4.3.exe --version || true
pkgconf-2.4.3.exe --atleast-pkgconfig-version 0.9.0 && echo "    pkgconf >= 0.9.0: OK" || echo "    pkgconf >= 0.9.0: FAIL"
wslpath -u "D:/test" >/dev/null 2>&1 && echo "    wslpath: OK" || echo "    wslpath: FAIL"
python3 --version 2>/dev/null || true
make --version 2>/dev/null | head -1 || true

case "$HOST_ARCH" in
    x86_64|i686)
        nasm -v 2>/dev/null || nasm.exe -v 2>/dev/null || true
        ;;
esac

echo ""
if [ "$ERRORS" -gt 0 ]; then
    echo "WARN: $ERRORS tool(s) missing — check output above"
    exit 1
fi

echo "============================================"
echo " MSYS2 setup complete!"
echo " Next: run ./scripts/windows-build.sh"
echo "============================================"
