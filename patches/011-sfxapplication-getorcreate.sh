#!/bin/bash
# 011-sfxapplication-getorcreate.sh
#
# Three fixes for non-iOS LOKit platforms (macOS, etc.) in
# desktop/source/lib/init.cxx:
#
# 1. #include <sfx2/app.hxx> is inside #ifdef IOS — make it unconditional
#    so SfxApplication class declaration is available on all platforms.
#
# 2. SfxApplication::GetOrCreate() is only called inside #ifdef IOS —
#    we need it on all LOKit platforms. But it MUST be called AFTER InitVCL()
#    because SfxApplication's constructor needs SalInstance (created by InitVCL).
#
#    There are two non-iOS InitVCL() call sites:
#    a) PRE_INIT path:  InitVCL();  → add GetOrCreate() after it
#    b) unipoll path:   InitVCL();  → add GetOrCreate() after it
#    (The !bUnipoll path uses lo_startmain → soffice_main → Desktop::Main
#     which calls GetOrCreate() internally)
#
# Idempotent: safe to re-run.

set -euo pipefail

LO_SRC="${1:?Missing LO source dir}"

INIT_CXX="$LO_SRC/desktop/source/lib/init.cxx"

if [ ! -f "$INIT_CXX" ]; then
    echo "    ERROR: $INIT_CXX not found"
    exit 1
fi

CHANGED=0

# --- Part 1: Make #include <sfx2/app.hxx> unconditional ---
# Original pattern:
#   #ifdef IOS
#   #include <sfx2/app.hxx>
#   #endif
# Target: just #include <sfx2/app.hxx> (no guards)

if grep -q '^#ifdef IOS' "$INIT_CXX" && \
   awk '/#ifdef IOS/{found=1; next} found && /#include <sfx2\/app\.hxx>/{print "MATCH"; exit}' "$INIT_CXX" | grep -q MATCH; then
    echo "    011: Making #include <sfx2/app.hxx> unconditional..."
    awk '
    /^#ifdef IOS$/ && !include_fixed {
        # Buffer this line; check if next line is the include
        getline nextline
        if (nextline ~ /#include <sfx2\/app\.hxx>/) {
            # Read the #endif too
            getline endifline
            if (endifline ~ /^#endif/) {
                # Output just the include, without guards
                print nextline " // SlimLO: was inside #ifdef IOS"
                include_fixed = 1
            } else {
                # Not the pattern we expected — output all three
                print "#ifdef IOS"
                print nextline
                print endifline
            }
        } else {
            # Not the include — output both lines
            print "#ifdef IOS"
            print nextline
        }
        next
    }
    { print }
    ' "$INIT_CXX" > "$INIT_CXX.tmp" && mv "$INIT_CXX.tmp" "$INIT_CXX"
    CHANGED=1
else
    echo "    011: #include <sfx2/app.hxx> already unconditional (or not found)"
fi

# --- Part 2: Remove GetOrCreate() from inside #ifdef IOS if still there ---
if awk '/^#ifdef IOS$/{ios=1} ios && /SfxApplication::GetOrCreate/{print "MATCH"; exit} /^#endif$/{ios=0}' "$INIT_CXX" | grep -q MATCH; then
    echo "    011: Removing SfxApplication::GetOrCreate() from inside #ifdef IOS..."
    awk '
    /^#ifdef IOS$/ { in_ios = 1 }
    in_ios && /SfxApplication::GetOrCreate\(\)/ { next }
    /^#endif$/ && in_ios { in_ios = 0 }
    { print }
    ' "$INIT_CXX" > "$INIT_CXX.tmp" && mv "$INIT_CXX.tmp" "$INIT_CXX"
    CHANGED=1
fi

# Also remove any previously (incorrectly) placed GetOrCreate right after #endif of iOS block
if grep -q 'SfxApplication::GetOrCreate.*// SlimLO: unconditional' "$INIT_CXX"; then
    echo "    011: Removing old misplaced GetOrCreate() line..."
    awk '!/SfxApplication::GetOrCreate.*\/\/ SlimLO: unconditional/' "$INIT_CXX" > "$INIT_CXX.tmp" && mv "$INIT_CXX.tmp" "$INIT_CXX"
    CHANGED=1
fi

# --- Part 3: Add GetOrCreate() AFTER each non-iOS InitVCL() call ---
# We need to find InitVCL() calls that are NOT inside #ifdef IOS blocks
# and add GetOrCreate() right after them.
#
# Pattern 1 (PRE_INIT path):
#   InitVCL();
#   }          ← closing brace of ProfileZone scope
#   → add GetOrCreate() after the closing brace
#
# Pattern 2 (unipoll path):
#   else
#       InitVCL();
#   → add GetOrCreate() right after

if ! grep -q 'SfxApplication::GetOrCreate.*// SlimLO: after InitVCL' "$INIT_CXX"; then
    echo "    011: Adding SfxApplication::GetOrCreate() after non-iOS InitVCL() calls..."
    awk '
    BEGIN { in_ios = 0; saw_initvcl = 0 }
    /^#ifdef IOS$/ { in_ios = 1 }
    /^#endif$/ && in_ios { in_ios = 0 }

    # Track non-iOS InitVCL() calls
    !in_ios && /InitVCL\(\);/ && !/\/\/ SlimLO/ && !/^[[:space:]]*\/\// {
        print
        print "            SfxApplication::GetOrCreate(); // SlimLO: after InitVCL for non-iOS LOKit"
        next
    }
    { print }
    ' "$INIT_CXX" > "$INIT_CXX.tmp" && mv "$INIT_CXX.tmp" "$INIT_CXX"
    CHANGED=1
else
    echo "    011: GetOrCreate() already placed after InitVCL() calls"
fi

# --- Verification ---
FAIL=0

# Verify include is unconditional
if awk '/^#ifdef IOS$/{ios=1} ios && /#include <sfx2\/app\.hxx>/{print "GUARDED"; exit} /^#endif$/{ios=0}' "$INIT_CXX" | grep -q GUARDED; then
    echo "    011: ERROR: #include <sfx2/app.hxx> still inside #ifdef IOS"
    FAIL=1
fi

# Verify GetOrCreate is NOT inside #ifdef IOS
if awk '/^#ifdef IOS$/{ios=1} ios && /SfxApplication::GetOrCreate/{print "GUARDED"; exit} /^#endif$/{ios=0}' "$INIT_CXX" | grep -q GUARDED; then
    echo "    011: ERROR: SfxApplication::GetOrCreate() still inside #ifdef IOS"
    FAIL=1
fi

# Verify GetOrCreate exists somewhere (our patched lines)
if ! grep -q 'SfxApplication::GetOrCreate.*// SlimLO' "$INIT_CXX"; then
    echo "    011: ERROR: No SlimLO GetOrCreate() lines found"
    FAIL=1
fi

if [ "$FAIL" -eq 1 ]; then
    exit 1
fi

if [ "$CHANGED" -eq 1 ]; then
    echo "    011: Patch applied successfully"
else
    echo "    011: Already fully patched"
fi
