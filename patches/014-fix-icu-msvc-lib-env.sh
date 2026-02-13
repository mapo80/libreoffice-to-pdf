#!/bin/bash
# 014-fix-icu-msvc-lib-env.sh
# In MSYS2+MSVC builds, ICU configure may fail linking test executables if
# LIB is overwritten with an empty/partial ILIB.
# Keep existing LIB as fallback (and append it when ILIB is present).
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"
TARGET="$LO_SRC/external/icu/ExternalProject_icu.mk"

if [ ! -f "$TARGET" ]; then
    echo "    Skip (not found): $TARGET"
    exit 0
fi

if grep -Fq 'export LIB="$(if $(strip $(ILIB)),$(ILIB)$${LIB:+;$${LIB}},$${LIB})" PYTHONWARNINGS="default"' "$TARGET"; then
    echo "    ExternalProject_icu.mk already patched (skipping)"
    exit 0
fi

sed 's/export LIB="$(ILIB)" PYTHONWARNINGS="default"/export LIB="$(if $(strip $(ILIB)),$(ILIB)$${LIB:+;$${LIB}},$${LIB})" PYTHONWARNINGS="default"/' \
    "$TARGET" > "$TARGET.tmp"
mv "$TARGET.tmp" "$TARGET"

echo "    Patched: external/icu/ExternalProject_icu.mk (keep/fallback LIB env for MSVC)"
