#!/bin/bash
# 029-strip-external-xmlsec.sh
# Do not schedule external/xmlsec in SlimLO builds.
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"
TARGET="$LO_SRC/external/Module_external.mk"

if [ ! -f "$TARGET" ]; then
    echo "ERROR: file not found: $TARGET"
    exit 1
fi

OLD=$'\t$(call gb_Helper_optional,XMLSEC,xmlsec) \\\n'
NEW=$'\t$(if $(ENABLE_SLIMLO),,$(call gb_Helper_optional,XMLSEC,xmlsec)) \\\n'

if grep -Fq '$(if $(ENABLE_SLIMLO),,$(call gb_Helper_optional,XMLSEC,xmlsec))' "$TARGET"; then
    echo "    external xmlsec guard already patched (skipping)"
    exit 0
fi

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = "\t$(call gb_Helper_optional,XMLSEC,xmlsec) \\\n"
new = "\t$(if $(ENABLE_SLIMLO),,$(call gb_Helper_optional,XMLSEC,xmlsec)) \\\n"

if old not in text:
    print(f"ERROR: expected XMLSEC module line not found in {path}")
    sys.exit(1)

text = text.replace(old, new, 1)
path.write_text(text, encoding="utf-8")
print("    Patched external/Module_external.mk (XMLSEC guard)")
PY

