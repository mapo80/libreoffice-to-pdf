#!/bin/bash
# 026-slimlo-merge-install-guards.sh
#
# Baseline rule for dep-ladder: keep pre_MergedLibsList close to upstream,
# with only minimal hard removals required by always-slim profile.
# Step-specific merged pruning remains in patch 027.
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"
if [ ! -d "$LO_SRC" ]; then
    echo "ERROR: LO source dir not found: $LO_SRC"
    exit 1
fi

TARGET="solenv/gbuild/extensions/pre_MergedLibsList.mk"

if git -C "$LO_SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$LO_SRC" checkout -- "$TARGET"
    echo "    Restored $TARGET from git"
else
    echo "    WARNING: $LO_SRC is not a git worktree; cannot restore $TARGET"
fi

python3 - "$LO_SRC/$TARGET" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
if not p.exists():
    print(f"ERROR: missing file: {p}")
    sys.exit(1)

s = p.read_text(encoding="utf-8")
replacements = [
    ("\t$(call gb_Helper_optional,DESKTOP,helplinker) \\\n", ""),
    ("\t$(call gb_Helper_optionals_or,HELPTOOLS XMLHELP,helplinker) \\\n", ""),
    ("\tvbaevents \\\n", ""),
    ("\tvbahelper \\\n", ""),
    ("\t$(call gb_Helper_optional,SCRIPTING,vbaevents) \\\n", ""),
    ("\t$(call gb_Helper_optional,SCRIPTING,vbahelper) \\\n", ""),
    ("\tfrm \\\n", ""),
    ("\txsec_xmlsec \\\n", ""),
    ("\txsltdlg \\\n", ""),
    ("\txsltfilter \\\n", ""),
]

changed = 0
for old, new in replacements:
    if old in s:
        s = s.replace(old, new)
        changed += 1

p.write_text(s, encoding="utf-8")
print(f"    Applied minimal merged removals: {changed}")
PY

echo "    Patch 026 complete (baseline minimal guards; step pruning lives in patch 027)"
