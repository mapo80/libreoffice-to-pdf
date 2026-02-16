#!/bin/bash
# 030-fix-basic-noscripting-stubs.sh
# When scripting is disabled, basic/sbx code may still reference VBA helpers.
# Provide tiny stubs so merged linking remains consistent for SlimLO.
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"
TARGET="$LO_SRC/basic/source/runtime/runtime.cxx"

if [ ! -f "$TARGET" ]; then
    echo "ERROR: missing target file: $TARGET"
    exit 1
fi

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

marker = "SLIMLO_NOSCRIPTING_STUBS"
if marker in s:
    print("    Basic no-scripting stubs already present (skipping)")
    raise SystemExit(0)

old = "#if HAVE_FEATURE_SCRIPTING\n"
new = (
    "#if !HAVE_FEATURE_SCRIPTING\n"
    "// SLIMLO_NOSCRIPTING_STUBS: keep basic/sbx linkable with --disable-scripting.\n"
    "bool SbiRuntime::isVBAEnabled()\n"
    "{\n"
    "    return false;\n"
    "}\n"
    "\n"
    "void StarBASIC::SetVBAEnabled( bool )\n"
    "{\n"
    "}\n"
    "\n"
    "bool StarBASIC::isVBAEnabled() const\n"
    "{\n"
    "    return false;\n"
    "}\n"
    "#else // HAVE_FEATURE_SCRIPTING\n"
)

if old not in s:
    print("ERROR: expected '#if HAVE_FEATURE_SCRIPTING' not found")
    sys.exit(1)

s = s.replace(old, new, 1)
p.write_text(s, encoding="utf-8")
print("    Added Basic no-scripting stubs")
PY

echo "    Patch 030 complete"
