#!/bin/bash
# assert-config-features.sh — Hard gate for configured SlimLO feature set.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_HOST="${1:-$PROJECT_DIR/lo-src/config_host.mk}"
PLATFORM="${2:-auto}"

if [ ! -f "$CONFIG_HOST" ]; then
    echo "ERROR: config_host.mk not found: $CONFIG_HOST"
    exit 1
fi

if [ "$PLATFORM" = "auto" ]; then
    case "$(uname -s)" in
        Darwin) PLATFORM="macos" ;;
        Linux) PLATFORM="linux" ;;
        CYGWIN*|MINGW*|MSYS*) PLATFORM="windows" ;;
        *) PLATFORM="unknown" ;;
    esac
fi

get_var() {
    local key="$1"
    awk -F= -v k="$key" '$1 == "export " k {print substr($0, index($0, "=") + 1); exit}' "$CONFIG_HOST"
}

trim() {
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

is_true() {
    local v
    v="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | trim)"
    [ "$v" = "TRUE" ] || [ "$v" = "YES" ] || [ "$v" = "1" ]
}

fail() {
    echo "ASSERT FAIL: $1"
    ASSERT_ERRORS=$((ASSERT_ERRORS + 1))
}

assert_equals() {
    local key="$1"
    local expected="$2"
    local actual="$3"
    if [ "$actual" != "$expected" ]; then
        fail "$key expected '$expected' but got '$actual'"
    fi
}

assert_not_true() {
    local key="$1"
    local actual="$2"
    if is_true "$actual"; then
        fail "$key must be disabled, got '$actual'"
    fi
}

contains_token() {
    local haystack="$1"
    local token="$2"
    printf ' %s ' "$haystack" | tr '\t' ' ' | grep -q " $token "
}

ENABLE_SLIMLO="$(get_var ENABLE_SLIMLO | trim)"
ENABLE_CURL="$(get_var ENABLE_CURL | trim)"
ENABLE_NSS="$(get_var ENABLE_NSS | trim)"
ENABLE_OPENSSL="$(get_var ENABLE_OPENSSL | trim)"
TLS_IMPL="$(get_var TLS | tr '[:lower:]' '[:upper:]' | trim)"
BUILD_TYPE="$(get_var BUILD_TYPE | trim)"
DISABLE_GUI="$(get_var DISABLE_GUI | trim)"
ENABLE_MACOSX_SANDBOX="$(get_var ENABLE_MACOSX_SANDBOX | trim)"
ENABLE_OPENGL_CANVAS="$(get_var ENABLE_OPENGL_CANVAS | trim)"
ENABLE_OPENGL_TRANSITIONS="$(get_var ENABLE_OPENGL_TRANSITIONS | trim)"

DEP_STEP="${SLIMLO_DEP_STEP:-0}"
case "$DEP_STEP" in
    ''|*[!0-9]*)
        echo "ERROR: SLIMLO_DEP_STEP must be an integer >= 0 (got '$DEP_STEP')"
        exit 1
        ;;
esac

ASSERT_ERRORS=0

echo "=== SlimLO Configure Assertions ==="
echo "Config:    $CONFIG_HOST"
echo "Platform:  $PLATFORM"
echo "ENABLE_SLIMLO=$ENABLE_SLIMLO"
echo "ENABLE_CURL=$ENABLE_CURL"
echo "ENABLE_NSS=$ENABLE_NSS"
echo "ENABLE_OPENSSL=$ENABLE_OPENSSL"
echo "TLS=$TLS_IMPL"
echo "DISABLE_GUI=$DISABLE_GUI"
echo "ENABLE_MACOSX_SANDBOX=$ENABLE_MACOSX_SANDBOX"
echo "ENABLE_OPENGL_CANVAS=$ENABLE_OPENGL_CANVAS"
echo "ENABLE_OPENGL_TRANSITIONS=$ENABLE_OPENGL_TRANSITIONS"
echo "BUILD_TYPE=$BUILD_TYPE"
echo "SLIMLO_DEP_STEP=$DEP_STEP"
echo ""

assert_equals "ENABLE_SLIMLO" "TRUE" "$ENABLE_SLIMLO"
assert_not_true "ENABLE_CURL" "$ENABLE_CURL"
assert_not_true "ENABLE_NSS" "$ENABLE_NSS"
assert_not_true "ENABLE_OPENSSL" "$ENABLE_OPENSSL"
if [ -n "$TLS_IMPL" ] && [ "$TLS_IMPL" != "NO" ]; then
    fail "TLS expected 'NO' or empty (none), got '$TLS_IMPL'"
fi

# Linux profile is explicitly headless; keep this assertion strict.
if [ "$PLATFORM" = "linux" ]; then
    assert_equals "DISABLE_GUI" "TRUE" "$DISABLE_GUI"
fi

for forbidden in CURL NSS CRYPTO_NSS OPENSSL; do
    if contains_token "$BUILD_TYPE" "$forbidden"; then
        fail "BUILD_TYPE must not contain '$forbidden' for slim profile"
    fi
done

if [ "$PLATFORM" = "macos" ] && [ "$DEP_STEP" -ge 2 ]; then
    assert_not_true "ENABLE_OPENGL_CANVAS" "$ENABLE_OPENGL_CANVAS"
    assert_not_true "ENABLE_OPENGL_TRANSITIONS" "$ENABLE_OPENGL_TRANSITIONS"
fi

if contains_token "$BUILD_TYPE" "REDLAND"; then
    echo "WARN: BUILD_TYPE contains REDLAND; dependency gate enforces runtime removal at step 3+."
fi

if [ "$ASSERT_ERRORS" -ne 0 ]; then
    echo ""
    echo "ERROR: configure feature assertions failed ($ASSERT_ERRORS error(s))."
    exit 1
fi

echo "PASS: configure feature assertions"
