#!/bin/bash
# 028-guard-xmlsec-uiconfig.sh
# Build xmlsecurity UI config only when NSS or OpenSSL is enabled.
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"
TARGET="$LO_SRC/xmlsecurity/UIConfig_xmlsec.mk"

if [ ! -f "$TARGET" ]; then
    echo "ERROR: file not found: $TARGET"
    exit 1
fi

if grep -Fq 'ifneq ($(ENABLE_NSS)$(ENABLE_OPENSSL),)' "$TARGET"; then
    echo "    UIConfig_xmlsec guard already patched (skipping)"
    exit 0
fi

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

start = '$(eval $(call gb_UIConfig_UIConfig,xmlsec))'
add_start = '$(eval $(call gb_UIConfig_add_uifiles,xmlsec,\\'
end = '))'

if start not in text or add_start not in text:
    print(f"ERROR: expected xmlsec UIConfig block not found in {path}")
    sys.exit(1)

block_start = text.index(start)
add_pos = text.index(add_start, block_start)
end_pos = text.index(end, add_pos) + len(end)
block = text[block_start:end_pos]

wrapped = "ifneq ($(ENABLE_NSS)$(ENABLE_OPENSSL),)\n" + block + "\nendif"
text = text[:block_start] + wrapped + text[end_pos:]

path.write_text(text, encoding="utf-8")
print("    Patched xmlsecurity/UIConfig_xmlsec.mk with NSS/OpenSSL guard")
PY

