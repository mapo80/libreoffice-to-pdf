#!/bin/bash
# 011-fix-windows-midl-include.sh
# In MSYS2, passing raw $(INCLUDE) (semicolon-separated Windows paths with spaces)
# to the shell command line can break parsing in CustomTarget_spsupp_idl.mk.
# Keep explicit -I flags from $(SOLARINC) and unset INCLUDE for this command.
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"
TARGET="$LO_SRC/shell/CustomTarget_spsupp_idl.mk"

if [ ! -f "$TARGET" ]; then
    echo "    Skip (not found): $TARGET"
    exit 0
fi

if grep -q 'unset INCLUDE && midl\.exe' "$TARGET"; then
    echo "    CustomTarget_spsupp_idl.mk already patched (skipping)"
    exit 0
fi

awk '
{
    if (index($0, "midl.exe \\") > 0) {
        print "\t\tunset INCLUDE && midl.exe \\"
        next
    }
    if (index($0, "$(INCLUDE) \\") > 0) {
        next
    }
    print
}
' "$TARGET" > "$TARGET.tmp"
mv "$TARGET.tmp" "$TARGET"

echo "    Patched: shell/CustomTarget_spsupp_idl.mk (drop \$(INCLUDE), unset INCLUDE)"
