#!/bin/bash
# assert-merged-deps.sh — Assert direct dependencies of merged lib against rules.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ARTIFACT_DIR="${1:-$PROJECT_DIR/output}"
shift || true

if [ ! -d "$ARTIFACT_DIR/program" ]; then
    echo "ERROR: artifact dir must contain program/: $ARTIFACT_DIR"
    exit 1
fi

WRITE_PATH=""
declare -a FORBID_PATTERNS=()
declare -a REQUIRE_PATTERNS=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --write)
            if [ "$#" -lt 2 ]; then
                echo "ERROR: --write requires a path"
                exit 1
            fi
            WRITE_PATH="$2"
            shift 2
            ;;
        --forbid)
            if [ "$#" -lt 2 ]; then
                echo "ERROR: --forbid requires a glob pattern"
                exit 1
            fi
            FORBID_PATTERNS+=("$2")
            shift 2
            ;;
        --require)
            if [ "$#" -lt 2 ]; then
                echo "ERROR: --require requires a glob pattern"
                exit 1
            fi
            REQUIRE_PATTERNS+=("$2")
            shift 2
            ;;
        *)
            echo "ERROR: unknown argument: $1"
            exit 1
            ;;
    esac
done

MERGED=""
for candidate in \
    "$ARTIFACT_DIR/program/libmergedlo.dylib" \
    "$ARTIFACT_DIR/program/libmergedlo.so" \
    "$ARTIFACT_DIR/program/mergedlo.dll"; do
    if [ -f "$candidate" ]; then
        MERGED="$candidate"
        break
    fi
done

if [ -z "$MERGED" ]; then
    echo "ERROR: merged library not found in $ARTIFACT_DIR/program"
    exit 1
fi

TMP_DEPS="$(mktemp "${TMPDIR:-/tmp}/slimlo-merged-deps.XXXXXX")"
cleanup() {
    rm -f "$TMP_DEPS"
}
trap cleanup EXIT

collect_macos() {
    local merged="$1"
    otool -L "$merged" 2>/dev/null | tail -n +2 | awk '{print $1}' | while IFS= read -r dep; do
        [ -z "$dep" ] && continue
        echo "${dep##*/}"
    done
}

collect_linux() {
    local merged="$1"
    readelf -d "$merged" 2>/dev/null | awk '/NEEDED/ {gsub(/\[|\]/, "", $5); print $5}'
}

collect_windows() {
    local merged="$1"
    if ! command -v dumpbin.exe >/dev/null 2>&1; then
        echo "ERROR: dumpbin.exe is required for Windows dependency checks"
        exit 1
    fi
    dumpbin.exe /dependents "$merged" 2>/dev/null | awk '
        /Image has the following dependencies:/ {in_block=1; next}
        in_block && /^[[:space:]]+[^[:space:]]+\.DLL$/ {print $1}
        in_block && /^[[:space:]]+Summary/ {in_block=0}
    '
}

case "$MERGED" in
    *.dylib)
        collect_macos "$MERGED" | sort -u > "$TMP_DEPS"
        ;;
    *.so)
        collect_linux "$MERGED" | sort -u > "$TMP_DEPS"
        ;;
    *.dll|*.DLL)
        collect_windows "$MERGED" | sort -u > "$TMP_DEPS"
        ;;
    *)
        echo "ERROR: unsupported merged library type: $MERGED"
        exit 1
        ;;
esac

if [ -n "$WRITE_PATH" ]; then
    mkdir -p "$(dirname "$WRITE_PATH")"
    cp "$TMP_DEPS" "$WRITE_PATH"
fi

echo "Merged library: $MERGED"
echo "Direct dependency count: $(wc -l < "$TMP_DEPS" | awk '{print $1}')"

FAILURES=0

if [ "${#FORBID_PATTERNS[@]}" -gt 0 ]; then
    for pattern in "${FORBID_PATTERNS[@]}"; do
        MATCHED=0
        while IFS= read -r dep; do
            [ -z "$dep" ] && continue
            case "$dep" in
                $pattern)
                    if [ "$MATCHED" -eq 0 ]; then
                        echo "FORBIDDEN pattern '$pattern' matched by:"
                    fi
                    echo "  - $dep"
                    MATCHED=1
                    ;;
            esac
        done < "$TMP_DEPS"
        if [ "$MATCHED" -eq 1 ]; then
            FAILURES=$((FAILURES + 1))
        fi
    done
fi

if [ "${#REQUIRE_PATTERNS[@]}" -gt 0 ]; then
    for pattern in "${REQUIRE_PATTERNS[@]}"; do
        MATCHED=0
        while IFS= read -r dep; do
            [ -z "$dep" ] && continue
            case "$dep" in
                $pattern)
                    MATCHED=1
                    break
                    ;;
            esac
        done < "$TMP_DEPS"
        if [ "$MATCHED" -eq 0 ]; then
            echo "REQUIRED pattern '$pattern' not found in direct dependencies"
            FAILURES=$((FAILURES + 1))
        fi
    done
fi

if [ "$FAILURES" -ne 0 ]; then
    echo "FAIL: merged dependency assertions failed ($FAILURES)"
    exit 1
fi

echo "PASS: merged dependency assertions"
