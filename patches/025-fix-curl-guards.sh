#!/bin/bash
# 025-fix-curl-guards.sh
# Ensure curl external is only referenced when ENABLE_CURL is active.
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"

python3 - "$LO_SRC" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])

changes = [
    (
        "svl/Library_svl.mk",
        """$(eval $(call gb_Library_use_externals,svl,\\
    boost_headers \\
    $(if $(filter LINUX MACOSX ANDROID iOS %BSD SOLARIS HAIKU,$(OS)), \\
        curl) \\
    dtoa \\
""",
        """$(eval $(call gb_Library_use_externals,svl,\\
    boost_headers \\
    $(if $(and $(ENABLE_CURL),$(filter LINUX MACOSX ANDROID iOS %BSD SOLARIS HAIKU,$(OS))), \\
        curl) \\
    dtoa \\
""",
        "svl curl guard",
    ),
    (
        "lingucomponent/Library_LanguageTool.mk",
        """$(eval $(call gb_Library_use_externals,LanguageTool,\\
\tboost_headers \\
\ticuuc \\
\tcurl \\
))
""",
        """$(eval $(call gb_Library_use_externals,LanguageTool,\\
\tboost_headers \\
\ticuuc \\
\t$(if $(ENABLE_CURL),curl) \\
))
""",
        "LanguageTool curl guard",
    ),
    (
        "desktop/Library_crashreport.mk",
        """$(eval $(call gb_Library_use_externals,crashreport,\\
    breakpad \\
    curl \\
))
""",
        """$(eval $(call gb_Library_use_externals,crashreport,\\
    breakpad \\
    $(if $(ENABLE_CURL),curl) \\
))
""",
        "crashreport curl guard",
    ),
]

for rel, old, new, label in changes:
    path = root / rel
    if not path.exists():
        print(f"ERROR: file not found: {rel}")
        sys.exit(1)
    content = path.read_text(encoding="utf-8")
    if new in content:
        print(f"    {label} already patched (skipping)")
        continue
    if old not in content:
        print(f"ERROR: expected block not found for {label} in {rel}")
        sys.exit(1)
    path.write_text(content.replace(old, new, 1), encoding="utf-8")
    print(f"    Patched: {label}")

print("    Patch 025 complete")
PY
