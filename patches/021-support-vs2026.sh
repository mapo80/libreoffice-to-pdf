#!/bin/bash
# 021-support-vs2026.sh
# Adds Visual Studio 2026 (version 18.x) support to configure.ac
# VS 2026 uses MSVC toolset v145 and _MSC_VER >= 1950
set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"

CONFIGURE="$LO_SRC/configure.ac"

if grep -q 'vsversion=18' "$CONFIGURE"; then
    echo "    configure.ac already patched for VS 2026 (skipping)"
    exit 0
fi

echo "    Patching configure.ac for Visual Studio 2026 support..."

# 1. Add 2026 to map_vs_year_to_version()
sed -i.bak '/2022preview)/,/vsversion=17\.14/ {
    /vsversion=17\.14;;/ a\
    2026)\
        vsversion=18;;
}' "$CONFIGURE"

# 2. Add 2026 to the --with-visual-studio help string
sed -i.bak '/--with-visual-studio=<2019\/2022\/2022preview>/ s|2022preview>|2022preview/2026>|' "$CONFIGURE"

# 3. Add default version to include 18 (VS 2026) in vs_versions_to_check()
# Change default from just "16" to "18 17 16" so it checks newest first
sed -i.bak 's/vsversions="16"/vsversions="18 17 16"/' "$CONFIGURE"

# 4. Add case for version 18.0 in find_msvc()
sed -i.bak '/17\.0 | 17\.14)/,/vctoolset=v143/ {
    /vctoolset=v143/ a\
        ;;\
        18.0)\
            vcyear=2026\
            vctoolset=v145
}' "$CONFIGURE"

# 5. Add 18.0 to WINDOWS_SDK_ACCEPTABLE_VERSIONS case
# The existing case only covers "16.0 | 17.0 | 17.14" — add 18.0
sed -i.bak 's/16\.0 | 17\.0 | 17\.14)/16.0 | 17.0 | 17.14 | 18.0)/' "$CONFIGURE"

# Verify patches applied
if grep -q 'vsversion=18' "$CONFIGURE" && grep -q 'vcyear=2026' "$CONFIGURE" && grep -q '18\.0)' "$CONFIGURE"; then
    echo "    OK: VS 2026 support added"
else
    echo "    ERROR: Patch may have failed — check configure.ac manually"
    exit 1
fi

rm -f "$CONFIGURE.bak"
