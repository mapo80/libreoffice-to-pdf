#!/bin/bash
# prune-probe.sh — Probe aggressive runtime pruning candidates with an automated test gate.
#
# Usage:
#   ./scripts/prune-probe.sh <artifact-dir> [gate-command]
#
# Environment:
#   PRUNE_GATE_CMD        Gate command override (if not passed as argv[2])
#   PRUNE_CANDIDATES_FILE Optional newline-delimited candidate list (overrides defaults)
#   PRUNE_MANIFEST        Output manifest path
#   PRUNE_OUTPUT_DIR      Optional final pruned artifact output dir
#   PRUNE_WORKDIR         Optional workdir (default: mktemp)
#   PRUNE_DOTNET_GATE     1 to enable extra .NET stream/buffer gate (default: 0)
#   PRUNE_GATE_TIMEOUT_C      Timeout seconds for C gate when using run-gate.sh
#   PRUNE_GATE_TIMEOUT_DOTNET Timeout seconds for .NET gate when using run-gate.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ARTIFACT_DIR="${1:?Usage: prune-probe.sh <artifact-dir> [gate-command]}"
shift || true

if [ ! -d "$ARTIFACT_DIR/program" ]; then
    echo "ERROR: artifact dir must contain program/: $ARTIFACT_DIR"
    exit 1
fi

PRUNE_GATE_CMD="${PRUNE_GATE_CMD:-${1:-}}"
PRUNE_MANIFEST="${PRUNE_MANIFEST:-$PROJECT_DIR/artifacts/prune-manifest-docx-aggressive.txt}"
PRUNE_OUTPUT_DIR="${PRUNE_OUTPUT_DIR:-}"
PRUNE_WORKDIR="${PRUNE_WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/slimlo-prune-probe.XXXXXX")}"
PRUNE_DOTNET_GATE="${PRUNE_DOTNET_GATE:-0}"
PRUNE_GATE_TIMEOUT_C="${PRUNE_GATE_TIMEOUT_C:-240}"
PRUNE_GATE_TIMEOUT_DOTNET="${PRUNE_GATE_TIMEOUT_DOTNET:-480}"

cleanup() {
    rm -rf "$PRUNE_WORKDIR"
}
trap cleanup EXIT

copy_tree() {
    local src="$1"
    local dst="$2"

    rm -rf "$dst"
    mkdir -p "$dst"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete "$src"/ "$dst"/
    else
        cp -a "$src"/. "$dst"/
    fi
}

artifact_size_kb() {
    local root="$1"
    local total=0
    local sub
    for sub in program share presets include; do
        if [ -e "$root/$sub" ]; then
            local sz
            sz="$(du -sk "$root/$sub" | awk '{print $1}')"
            total=$((total + sz))
        fi
    done
    echo "$total"
}

normalize_lib_name() {
    local raw="$1"
    local n="${raw##*/}"
    n="${n%% *}"
    n="${n%%,*}"

    case "$n" in
        *.DLL) n="${n%.DLL}" ;;
        *.dll) n="${n%.dll}" ;;
    esac

    case "$n" in
        *.dylib.*) n="$(echo "$n" | sed -E 's/\.dylib\..*$//')" ;;
        *.dylib) n="${n%.dylib}" ;;
    esac

    case "$n" in
        *.so.*) n="$(echo "$n" | sed -E 's/\.so\././')" ;;
        *.so) n="${n%.so}" ;;
    esac

    echo "$n"
}

collect_direct_needed() {
    local root="$1"
    local out_file="$2"
    local merged=""
    : > "$out_file"

    for cand in \
        "$root/program/libmergedlo.dylib" \
        "$root/program/libmergedlo.so" \
        "$root/program/mergedlo.dll"; do
        if [ -f "$cand" ]; then
            merged="$cand"
            break
        fi
    done

    [ -z "$merged" ] && return 0

    case "$(uname -s)" in
        Darwin)
            if command -v otool >/dev/null 2>&1; then
                otool -L "$merged" 2>/dev/null | tail -n +2 | awk '{print $1}' | while IFS= read -r dep; do
                    [ -z "$dep" ] && continue
                    normalize_lib_name "$dep"
                done | sort -u > "$out_file"
            fi
            ;;
        Linux)
            if command -v readelf >/dev/null 2>&1; then
                readelf -d "$merged" 2>/dev/null | awk '/NEEDED/ {gsub(/\[|\]/, "", $5); print $5}' | while IFS= read -r dep; do
                    [ -z "$dep" ] && continue
                    normalize_lib_name "$dep"
                done | sort -u > "$out_file"
            fi
            ;;
        CYGWIN*|MINGW*|MSYS*)
            if command -v dumpbin.exe >/dev/null 2>&1; then
                dumpbin.exe /dependents "$merged" 2>/dev/null | awk '
                    /Image has the following dependencies:/ {in_block=1; next}
                    in_block && /^[[:space:]]+[^[:space:]]+\.DLL$/ {print $1}
                    in_block && /^[[:space:]]+Summary/ {in_block=0}
                ' | while IFS= read -r dep; do
                    [ -z "$dep" ] && continue
                    normalize_lib_name "$dep"
                done | sort -u > "$out_file"
            fi
            ;;
    esac
}

is_direct_needed_candidate() {
    local candidate="$1"
    local direct_needed_file="$2"

    [ -f "$direct_needed_file" ] || return 1
    [ -s "$direct_needed_file" ] || return 1

    grep -Fxq "$candidate" "$direct_needed_file"
}

remove_candidate() {
    local root="$1"
    local candidate="$2"

    case "$candidate" in
        share/*|program/*)
            rm -rf "$root/$candidate"
            return 0
            ;;
    esac

    rm -f "$root/program/${candidate}.so"
    rm -f "$root/program/${candidate}.so."*
    rm -f "$root/program/${candidate}.dylib"
    rm -f "$root/program/${candidate}.dylib."*
    rm -f "$root/program/${candidate}.dll"
}

run_gate() {
    local artifact="$1"

    if [ -n "$PRUNE_GATE_CMD" ]; then
        (
            cd "$PROJECT_DIR"
            SLIMLO_DIR="$artifact" \
            SLIMLO_RESOURCE_PATH="$artifact" \
            eval "$PRUNE_GATE_CMD"
        )
        return $?
    fi

    (
        cd "$PROJECT_DIR"
        GATE_ENABLE_DOTNET="$([ "$PRUNE_DOTNET_GATE" = "1" ] && echo "1" || echo "0")" \
        GATE_TIMEOUT_C="$PRUNE_GATE_TIMEOUT_C" \
        GATE_TIMEOUT_DOTNET="$PRUNE_GATE_TIMEOUT_DOTNET" \
        ./scripts/run-gate.sh "$artifact" >/dev/null
    )
}

declare -a CANDIDATES=()
if [ -n "${PRUNE_CANDIDATES_FILE:-}" ]; then
    if [ ! -f "$PRUNE_CANDIDATES_FILE" ]; then
        echo "ERROR: PRUNE_CANDIDATES_FILE not found: $PRUNE_CANDIDATES_FILE"
        exit 1
    fi
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        CANDIDATES+=("$line")
    done < "$PRUNE_CANDIDATES_FILE"
else
    CANDIDATES=(
        libmswordlo
        libcached1
        libgraphicfilterlo
        libfps_aqualo
        libnssckbi
        libnssdbm3
        libsoftokn3
        libfreebl3
        libssl3
        libnet_uno
        libmacbe1lo
        libintrospectionlo
        libinvocationlo
        libinvocadaptlo
        libreflectionlo
        libunsafe_uno_uno
        libaffine_uno_uno
        libbinaryurplo
        libbootstraplo
        libiolo
        libloglo
        libstoragefdlo
        libtllo
        libucbhelper
        libucppkg1
        libsal_textenc
        libsal_textenclo
        libcurl.4
        libepoxy
        libAppleRemotelo
        liblcms2.2
        librdf-lo.0
        libraptor2-lo.0
        librasqal-lo.3
        libnss3
        libnssutil3
        libsmime3
        libnspr4
        libplc4
        libplds4
        share/config/soffice.cfg/svx
        share/config/soffice.cfg/sfx
        share/config/soffice.cfg/vcl
        share/config/soffice.cfg/fps
        share/config/soffice.cfg/formula
        share/config/soffice.cfg/uui
        share/config/soffice.cfg/xmlsec
        share/filter
        share/palette
        share/registry/Langpack-en-US.xcd
        share/registry/ctl.xcd
        share/registry/graphicfilter.xcd
        share/registry/math.xcd
    )
fi

mkdir -p "$PRUNE_WORKDIR"
CURRENT_DIR="$PRUNE_WORKDIR/current"
TRIAL_DIR="$PRUNE_WORKDIR/trial"
DIRECT_NEEDED_FILE="$PRUNE_WORKDIR/direct-needed.txt"

copy_tree "$ARTIFACT_DIR" "$CURRENT_DIR"
collect_direct_needed "$CURRENT_DIR" "$DIRECT_NEEDED_FILE"
if [ -s "$DIRECT_NEEDED_FILE" ]; then
    echo "Detected direct NEEDED dependencies from merged lib:"
    sed 's/^/  - /' "$DIRECT_NEEDED_FILE"
fi

BASELINE_KB="$(artifact_size_kb "$CURRENT_DIR")"
echo "Baseline size: $((BASELINE_KB / 1024)) MB ($BASELINE_KB KB)"
echo "Running baseline gate..."
set +e
run_gate "$CURRENT_DIR"
BASE_RC=$?
set -e
if [ "$BASE_RC" -ne 0 ]; then
    if [ "$BASE_RC" -eq 124 ]; then
        echo "ERROR: baseline gate timed out. Refusing to probe candidates."
    else
        echo "ERROR: baseline gate failed. Refusing to probe candidates."
    fi
    exit 1
fi
echo "Baseline gate: PASS"

declare -a ACCEPTED=()
declare -a REJECTED=()
declare -a REJECTED_TIMEOUT=()
declare -a REJECTED_HARD_NEEDED=()

for candidate in "${CANDIDATES[@]}"; do
    echo "Probing candidate: $candidate"

    case "$candidate" in
        share/*|program/*)
            ;;
        *)
            if is_direct_needed_candidate "$candidate" "$DIRECT_NEEDED_FILE"; then
                echo "  HARD-NEEDED by merged lib -> rejected"
                REJECTED+=("$candidate")
                REJECTED_HARD_NEEDED+=("$candidate")
                continue
            fi
            ;;
    esac

    copy_tree "$CURRENT_DIR" "$TRIAL_DIR"
    remove_candidate "$TRIAL_DIR" "$candidate"

    set +e
    run_gate "$TRIAL_DIR"
    RC=$?
    set -e
    if [ "$RC" -eq 0 ]; then
        echo "  PASS -> accepted"
        ACCEPTED+=("$candidate")
        rm -rf "$CURRENT_DIR"
        mv "$TRIAL_DIR" "$CURRENT_DIR"
    else
        if [ "$RC" -eq 124 ]; then
            echo "  TIMEOUT -> rejected"
            REJECTED_TIMEOUT+=("$candidate")
        else
            echo "  FAIL -> rejected"
        fi
        REJECTED+=("$candidate")
        rm -rf "$TRIAL_DIR"
    fi
done

FINAL_KB="$(artifact_size_kb "$CURRENT_DIR")"
SAVED_KB=$((BASELINE_KB - FINAL_KB))

mkdir -p "$(dirname "$PRUNE_MANIFEST")"
set +u
{
    echo "# SlimLO DOCX aggressive prune manifest"
    echo "# generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# artifact_source=$ARTIFACT_DIR"
    echo "# baseline_kb=$BASELINE_KB"
    echo "# final_kb=$FINAL_KB"
    echo "# saved_kb=$SAVED_KB"
    echo
    echo "[accepted]"
    for candidate in "${ACCEPTED[@]-}"; do
        echo "$candidate"
    done
    echo
    echo "[rejected]"
    for candidate in "${REJECTED[@]-}"; do
        echo "$candidate"
    done
    echo
    echo "[rejected_timeout]"
    for candidate in "${REJECTED_TIMEOUT[@]-}"; do
        echo "$candidate"
    done
    echo
    echo "[rejected_hard_needed]"
    for candidate in "${REJECTED_HARD_NEEDED[@]-}"; do
        echo "$candidate"
    done
} > "$PRUNE_MANIFEST"
ACCEPTED_COUNT="${#ACCEPTED[@]}"
REJECTED_COUNT="${#REJECTED[@]}"
set -u

if [ -n "$PRUNE_OUTPUT_DIR" ]; then
    copy_tree "$CURRENT_DIR" "$PRUNE_OUTPUT_DIR"
    echo "Final pruned artifact copied to: $PRUNE_OUTPUT_DIR"
fi

echo "Manifest written to: $PRUNE_MANIFEST"
echo "Accepted: ${ACCEPTED_COUNT}  Rejected: ${REJECTED_COUNT}"
echo "Size delta: $((SAVED_KB / 1024)) MB ($SAVED_KB KB)"
