#!/bin/bash
# check-deps-allowlist.sh — Validate bundled runtime dependencies against allowlist.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ARTIFACT_DIR="${1:-$PROJECT_DIR/output}"
ALLOWLIST_FILE="${2:-}"
EXTRA_ALLOWLIST="${DEPS_ALLOWLIST_EXTRA:-}"

if [ ! -d "$ARTIFACT_DIR/program" ]; then
    echo "ERROR: artifact dir must contain program/: $ARTIFACT_DIR"
    exit 1
fi

PLATFORM="${DEPS_PLATFORM:-}"
if [ -z "$PLATFORM" ]; then
    case "$(uname -s)" in
        Darwin) PLATFORM="macos" ;;
        Linux)  PLATFORM="linux" ;;
        CYGWIN*|MINGW*|MSYS*) PLATFORM="windows" ;;
        *)      PLATFORM="unknown" ;;
    esac
fi

if [ -z "$ALLOWLIST_FILE" ]; then
    ALLOWLIST_FILE="$PROJECT_DIR/artifacts/deps-allowlist-${PLATFORM}.txt"
fi

if [ ! -f "$ALLOWLIST_FILE" ]; then
    echo "ERROR: allowlist file not found: $ALLOWLIST_FILE"
    exit 1
fi

TMP_DEPS="$(mktemp "${TMPDIR:-/tmp}/slimlo-deps.XXXXXX")"
TMP_ALLOWED="$(mktemp "${TMPDIR:-/tmp}/slimlo-allow.XXXXXX")"
cleanup() {
    rm -f "$TMP_DEPS" "$TMP_ALLOWED"
}
trap cleanup EXIT

awk '
    {
        line=$0
        sub(/#.*/, "", line)
        gsub(/^[ \t]+|[ \t]+$/, "", line)
        if (line != "") print line
    }
' "$ALLOWLIST_FILE" > "$TMP_ALLOWED"

if [ -n "$EXTRA_ALLOWLIST" ]; then
    # Accept comma/newline-separated extra patterns injected by callers.
    printf '%s\n' "$EXTRA_ALLOWLIST" \
        | tr ',' '\n' \
        | awk '{gsub(/^[ \t]+|[ \t]+$/, ""); if ($0 != "") print}' >> "$TMP_ALLOWED"
fi

gather_macos_deps() {
    local program="$1"
    find "$program" -maxdepth 1 -type f | while read -r f; do
        case "$f" in
            *.dylib|*.dylib.*) ;;
            *)
                if [ ! -x "$f" ]; then
                    continue
                fi
                ;;
        esac
        otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}' | while read -r dep; do
            [ -z "$dep" ] && continue
            case "$dep" in
                /usr/lib/*|/System/*) continue ;;
            esac
            # Normalize @loader_path/libfoo.dylib -> libfoo.dylib
            dep="${dep##*/}"
            echo "$dep"
        done
    done
}

gather_linux_deps() {
    local program="$1"
    find "$program" -maxdepth 1 -type f | while read -r f; do
        case "$f" in
            *.so|*.so.*) ;;
            *)
                if [ ! -x "$f" ]; then
                    continue
                fi
                ;;
        esac
        ldd "$f" 2>/dev/null | while read -r line; do
            case "$line" in
                *"=>"*)
                    dep="$(echo "$line" | awk -F'=> ' '{print $1}' | xargs)"
                    [ -n "$dep" ] && echo "$dep"
                    ;;
                *"ld-linux"*|*"linux-vdso"*)
                    dep="$(echo "$line" | awk '{print $1}')"
                    [ -n "$dep" ] && echo "$dep"
                    ;;
            esac
        done
    done
}

gather_windows_deps() {
    local program="$1"
    if ! command -v dumpbin.exe >/dev/null 2>&1; then
        return 0
    fi
    find "$program" -maxdepth 1 -type f \( -name "*.dll" -o -name "*.exe" \) | while read -r f; do
        dumpbin.exe /dependents "$f" 2>/dev/null | awk '
            /Image has the following dependencies:/ {in_block=1; next}
            in_block && /^ +[^ ]+\.DLL$/ {
                dep=$1
                if (dep !~ /^API-MS-WIN/i && dep !~ /^EXT-MS-WIN/i)
                    print dep
            }
            in_block && /^ +Summary/ {in_block=0}
        '
    done
}

case "$PLATFORM" in
    macos) gather_macos_deps "$ARTIFACT_DIR/program" ;;
    linux) gather_linux_deps "$ARTIFACT_DIR/program" ;;
    windows) gather_windows_deps "$ARTIFACT_DIR/program" ;;
    *)
        echo "ERROR: unsupported platform for dependency check: $PLATFORM"
        exit 1
        ;;
esac | sort -u > "$TMP_DEPS"

MISSING=0
while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    MATCH=0
    while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        case "$dep" in
            $pattern)
                MATCH=1
                break
                ;;
        esac
    done < "$TMP_ALLOWED"

    if [ "$MATCH" -eq 0 ]; then
        echo "Dependency not in allowlist: $dep"
        MISSING=1
    fi
done < "$TMP_DEPS"

if [ "$MISSING" -ne 0 ]; then
    echo "FAIL: dependency allowlist check failed ($ALLOWLIST_FILE)"
    exit 1
fi

echo "PASS: dependency allowlist check ($ALLOWLIST_FILE)"
