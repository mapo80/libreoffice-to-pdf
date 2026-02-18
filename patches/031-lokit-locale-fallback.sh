#!/bin/bash
# 031-lokit-locale-fallback.sh
#
# When LOKit initializes on Linux/Windows (non-unipoll mode), it spawns
# lo_startmain → soffice_main() → Desktop::Main() → prepareLocale().
# prepareLocale() checks InstalledLocales from XCD registry files.
# If Langpack-en-US.xcd is missing from the artifacts, InstalledLocales
# is empty and prepareLocale() returns false → fatal exit code 77.
#
# LOKit already hardcodes "en-US" via setLanguageAndLocale() in init.cxx.
# This patch adds a fallback in prepareLocale(): if all locale resolution
# fails AND we're in LOKit mode, use "en-US" instead of crashing.
#
# Idempotent: safe to re-run.

set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"

LANGSEL="$LO_SRC/desktop/source/app/langselect.cxx"

if [ ! -f "$LANGSEL" ]; then
    echo "    ERROR: $LANGSEL not found"
    exit 1
fi

CHANGED=0

# --- Check if already patched ---
if grep -q 'LibreOfficeKit::isActive.*// SlimLO' "$LANGSEL"; then
    echo "    031: Already patched"
    exit 0
fi

# --- Part 1: Add #include <comphelper/lok.hxx> if missing ---
if ! grep -q '#include <comphelper/lok.hxx>' "$LANGSEL"; then
    echo "    031: Adding #include <comphelper/lok.hxx>..."
    # Insert after the last comphelper include
    awk '
    /^#include <comphelper\//{last_comphelper=NR; line=$0}
    {lines[NR]=$0}
    END {
        for (i=1; i<=NR; i++) {
            print lines[i]
            if (i == last_comphelper) {
                print "#include <comphelper/lok.hxx> // SlimLO: LOKit locale fallback"
            }
        }
    }
    ' "$LANGSEL" > "$LANGSEL.tmp" && mv "$LANGSEL.tmp" "$LANGSEL"
    CHANGED=1
fi

# --- Part 2: Insert LOKit fallback before "return false" in prepareLocale() ---
echo "    031: Inserting LOKit locale fallback..."
# Pattern: find the sequence:
#     if (locale.isEmpty()) {
#         return false;
#     }
# Insert a LOKit fallback block before it.
awk '
/locale\.isEmpty\(\)/ && /return false/ {
    # Single-line pattern unlikely, but handle it
    print "    if (locale.isEmpty() && comphelper::LibreOfficeKit::isActive()) { // SlimLO: LOKit locale fallback"
    print "        // LOKit always forces en-US via setLanguageAndLocale() in init.cxx."
    print "        // Fall back to en-US rather than crashing when Langpack-en-US.xcd is missing."
    print "        locale = \"en-US\";"
    print "    }"
    print
    next
}
/locale\.isEmpty\(\)/ {
    # Check if this is the "return false" block (next line has return false)
    print
    getline nextline
    if (nextline ~ /return false/) {
        # This is our target — insert fallback before this if-block
        # But we already printed the if-line, so we need to back up.
        # Instead, restructure: print this block as-is, we handle differently
        print nextline
    } else {
        print nextline
    }
    next
}
{ print }
' "$LANGSEL" > "$LANGSEL.tmp"

# The awk above is tricky because the if-block spans 3 lines. Let me use a simpler approach:
# Find "    if (locale.isEmpty()) {\n        return false;\n    }" and insert before it.
rm -f "$LANGSEL.tmp"

awk '
BEGIN { buf_if = ""; buf_ret = ""; state = 0 }
state == 0 && /^[[:space:]]*if \(locale\.isEmpty\(\)\) \{[[:space:]]*$/ {
    buf_if = $0
    state = 1
    next
}
state == 1 && /^[[:space:]]*return false;[[:space:]]*$/ {
    buf_ret = $0
    state = 2
    next
}
state == 2 && /^[[:space:]]*\}[[:space:]]*$/ {
    # Found the full 3-line block. Insert fallback before it.
    print "    if (locale.isEmpty() && comphelper::LibreOfficeKit::isActive()) { // SlimLO: LOKit locale fallback"
    print "        // LOKit always forces en-US via setLanguageAndLocale() in init.cxx."
    print "        // Fall back rather than crashing when Langpack-en-US.xcd is missing."
    print "        locale = \"en-US\";"
    print "    }"
    # Now print the original block
    print buf_if
    print buf_ret
    print $0
    state = 0
    buf_if = ""
    buf_ret = ""
    next
}
# If state machine broke (lines did not match), flush buffered lines
state > 0 {
    if (buf_if != "") print buf_if
    if (buf_ret != "") print buf_ret
    buf_if = ""
    buf_ret = ""
    state = 0
}
{ print }
END {
    if (buf_if != "") print buf_if
    if (buf_ret != "") print buf_ret
}
' "$LANGSEL" > "$LANGSEL.tmp" && mv "$LANGSEL.tmp" "$LANGSEL"
CHANGED=1

# --- Verification ---
FAIL=0

if ! grep -q 'LibreOfficeKit::isActive.*// SlimLO' "$LANGSEL"; then
    echo "    031: ERROR: LOKit fallback not found after patching"
    FAIL=1
fi

if ! grep -q '#include <comphelper/lok.hxx>' "$LANGSEL"; then
    echo "    031: ERROR: #include <comphelper/lok.hxx> not found"
    FAIL=1
fi

if [ "$FAIL" -eq 1 ]; then
    exit 1
fi

if [ "$CHANGED" -eq 1 ]; then
    echo "    031: Patch applied successfully"
else
    echo "    031: Already fully patched"
fi
