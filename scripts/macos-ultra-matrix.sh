#!/bin/bash
# macos-ultra-matrix.sh — Fast local discovery matrix for ultra-slim DOCX runtime.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "ERROR: macos-ultra-matrix.sh must run on macOS."
    exit 1
fi

BASE_CONF="${BASE_CONF:-$PROJECT_DIR/distro-configs/SlimLO-macOS.conf}"
LO_SRC_DIR="${LO_SRC_DIR:-$PROJECT_DIR/lo-src}"
MATRIX_OUT_DIR="${MATRIX_OUT_DIR:-$PROJECT_DIR/artifacts/matrix-macos}"
MATRIX_JSON="${MATRIX_JSON:-$PROJECT_DIR/artifacts/matrix-results-macos.json}"
NPROC="${NPROC:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"

if [ ! -f "$BASE_CONF" ]; then
    echo "ERROR: base config not found: $BASE_CONF"
    exit 1
fi

mkdir -p "$MATRIX_OUT_DIR"
TMP_RESULTS="$(mktemp "${TMPDIR:-/tmp}/slimlo-matrix.XXXXXX")"
trap 'rm -f "$TMP_RESULTS"' EXIT

profiles=(P0 P1 P2 P3 P4 P5 P6)

make_profile_conf() {
    local profile="$1"
    local out_conf="$2"
    cp "$BASE_CONF" "$out_conf"

    add_line() {
        local line="$1"
        if ! grep -qx "$line" "$out_conf"; then
            printf '%s\n' "$line" >> "$out_conf"
        fi
    }

    case "$profile" in
        P0)
            ;;
        P1)
            add_line "--disable-scripting"
            ;;
        P2)
            add_line "--disable-curl"
            ;;
        P3)
            add_line "--disable-nss"
            add_line "--with-tls=openssl"
            ;;
        P4)
            add_line "--disable-gui"
            ;;
        P5)
            sed -i.bak 's/^--enable-mergelibs\(=.*\)\?$/--enable-mergelibs=more/' "$out_conf"
            rm -f "$out_conf.bak"
            ;;
        P6)
            add_line "--disable-scripting"
            add_line "--disable-curl"
            add_line "--disable-nss"
            add_line "--with-tls=openssl"
            add_line "--disable-gui"
            sed -i.bak 's/^--enable-mergelibs\(=.*\)\?$/--enable-mergelibs=more/' "$out_conf"
            rm -f "$out_conf.bak"
            ;;
        *)
            echo "ERROR: unknown profile $profile"
            exit 1
            ;;
    esac
}

echo "=== SlimLO macOS ultra matrix ==="
echo "Base config: $BASE_CONF"
echo "LO_SRC_DIR:  $LO_SRC_DIR"
echo "Output dir:  $MATRIX_OUT_DIR"
echo "Profiles:    ${profiles[*]}"
echo ""

for profile in "${profiles[@]}"; do
    echo ">>> [$profile] preparing profile config"
    PROFILE_DIR="$MATRIX_OUT_DIR/$profile"
    OUTPUT_DIR="$PROFILE_DIR/output"
    CONF_FILE="$PROFILE_DIR/SlimLO-macOS.conf"
    mkdir -p "$PROFILE_DIR"
    make_profile_conf "$profile" "$CONF_FILE"

    echo ">>> [$profile] build"
    BUILD_RC=0
    (
        cd "$PROJECT_DIR"
        NPROC="$NPROC" \
        LO_SRC_DIR="$LO_SRC_DIR" \
        OUTPUT_DIR="$OUTPUT_DIR" \
        DOCX_AGGRESSIVE=1 \
        SLIMLO_DISTRO_CONFIG_PATH="$CONF_FILE" \
        ./scripts/build.sh
    ) || BUILD_RC=$?

    if [ "$BUILD_RC" -ne 0 ]; then
        echo ">>> [$profile] build failed (rc=$BUILD_RC)"
        printf '%s\t%s\t%s\t%s\t%s\n' "$profile" "build_failed" "$BUILD_RC" "0" "$OUTPUT_DIR" >> "$TMP_RESULTS"
        continue
    fi

    echo ">>> [$profile] gate"
    GATE_RC=0
    "$PROJECT_DIR/scripts/run-gate.sh" "$OUTPUT_DIR" || GATE_RC=$?
    if [ "$GATE_RC" -ne 0 ]; then
        echo ">>> [$profile] gate failed (rc=$GATE_RC)"
        printf '%s\t%s\t%s\t%s\t%s\n' "$profile" "gate_failed" "$GATE_RC" "0" "$OUTPUT_DIR" >> "$TMP_RESULTS"
        continue
    fi

    echo ">>> [$profile] measure"
    "$PROJECT_DIR/scripts/measure-artifact.sh" "$OUTPUT_DIR" >/dev/null
    SIZE_KB="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["size"]["total_kb"])' "$OUTPUT_DIR/size-report.json" 2>/dev/null || echo 0)"
    printf '%s\t%s\t%s\t%s\t%s\n' "$profile" "passed" "0" "$SIZE_KB" "$OUTPUT_DIR" >> "$TMP_RESULTS"
done

python3 - "$TMP_RESULTS" "$MATRIX_JSON" <<'PY'
import datetime as dt
import json
import sys

rows = []
with open(sys.argv[1], "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        profile, status, rc, size_kb, out_dir = line.split("\t")
        rows.append(
            {
                "profile": profile,
                "status": status,
                "rc": int(rc),
                "size_kb": int(size_kb),
                "size_mb": round(int(size_kb) / 1024.0, 3) if int(size_kb) > 0 else 0.0,
                "output_dir": out_dir,
            }
        )

passed = [r for r in rows if r["status"] == "passed"]
best = None
if passed:
    best = sorted(passed, key=lambda r: (r["size_kb"], r["profile"]))[0]

result = {
    "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
    "platform": "macos",
    "profiles": rows,
    "best_profile": best,
    "selection_rule": "minimum size_kb among profiles with status=passed",
}

with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump(result, f, indent=2, sort_keys=True)
    f.write("\n")

print(f"Wrote matrix results: {sys.argv[2]}")
if best:
    print(f"Best profile: {best['profile']} ({best['size_mb']} MB)")
else:
    print("No passing profile.")
PY
