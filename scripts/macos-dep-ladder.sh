#!/bin/bash
# macos-dep-ladder.sh — Sequential merged-dependency elimination ladder for SlimLO.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "ERROR: macos-dep-ladder.sh must run on macOS."
    exit 1
fi

LO_SRC_DIR="${LO_SRC_DIR:-$PROJECT_DIR/lo-src}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/output-dep-ladder}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-$PROJECT_DIR/artifacts/dep-ladder}"
NPROC="${NPROC:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"
RUN_LINUX_VALIDATE="${RUN_LINUX_VALIDATE:-0}"
BASELINE_STEP="${BASELINE_STEP:-2}"
LADDER_STEPS="${LADDER_STEPS:-3 4 5 6}"
REQUIRED_FINAL_STEP="${REQUIRED_FINAL_STEP:-0}"
REUSE_BASELINE="${REUSE_BASELINE:-0}"

case "$RUN_LINUX_VALIDATE" in
    0|1) ;;
    *)
        echo "ERROR: RUN_LINUX_VALIDATE must be 0 or 1 (got '$RUN_LINUX_VALIDATE')"
        exit 1
        ;;
esac

case "$REUSE_BASELINE" in
    0|1) ;;
    *)
        echo "ERROR: REUSE_BASELINE must be 0 or 1 (got '$REUSE_BASELINE')"
        exit 1
        ;;
esac

case "$REQUIRED_FINAL_STEP" in
    ''|*[!0-9]*)
        echo "ERROR: REQUIRED_FINAL_STEP must be an integer >= 0 (got '$REQUIRED_FINAL_STEP')"
        exit 1
        ;;
esac

case "$BASELINE_STEP" in
    ''|*[!0-9]*)
        echo "ERROR: BASELINE_STEP must be an integer >= 0 (got '$BASELINE_STEP')"
        exit 1
        ;;
esac

read -r -a STEPS <<< "$LADDER_STEPS"
if [ "${#STEPS[@]}" -eq 0 ]; then
    echo "ERROR: LADDER_STEPS cannot be empty"
    exit 1
fi
for s in "${STEPS[@]}"; do
    case "$s" in
        ''|*[!0-9]*)
            echo "ERROR: LADDER_STEPS must contain only integers >= 0 (got '$s')"
            exit 1
            ;;
    esac
done

step_name() {
    case "$1" in
        1) echo "apple-remote" ;;
        2) echo "epoxy-opengl" ;;
        3) echo "rdf-redland" ;;
        4) echo "xmlsecurity-layer" ;;
        5) echo "curl-nss-residual" ;;
        6) echo "lcms2" ;;
        *) echo "unknown" ;;
    esac
}

step_forbids() {
    case "$1" in
        1) echo "libAppleRemotelo*" ;;
        2) echo "libepoxy*" ;;
        3) echo "librdf-lo*" "libraptor2-lo*" "librasqal-lo*" ;;
        4) echo "libxmlsec*" ;;
        5) echo "libcurl*" "libnss3*" "libnssutil3*" "libsmime3*" "libnspr4*" "libplc4*" "libplds4*" ;;
        6) echo "liblcms2*" ;;
    esac
}

extract_total_mb() {
    local json="$1"
    python3 - "$json" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
print(data.get("size", {}).get("total_mb", 0.0))
PY
}

merged_lib_path() {
    local out="$1"
    for p in "$out/program/libmergedlo.dylib" "$out/program/libmergedlo.so" "$out/program/mergedlo.dll"; do
        if [ -f "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

merged_mb() {
    local out="$1"
    local merged
    merged="$(merged_lib_path "$out" || true)"
    if [ -z "$merged" ]; then
        echo "0.0"
        return 0
    fi
    python3 - "$merged" <<'PY'
import os, sys
size_mb = os.path.getsize(sys.argv[1]) / (1024.0 * 1024.0)
print(f"{size_mb:.3f}")
PY
}

run_step() {
    local step="$1"
    local step_dir="$2"
    local gate_log="$step_dir/gate.log"

    mkdir -p "$step_dir"

    echo ">>> Building step S$(printf '%02d' "$step"): $(step_name "$step")"
    if ! (
        cd "$PROJECT_DIR"
        NPROC="$NPROC" \
        LO_SRC_DIR="$LO_SRC_DIR" \
        OUTPUT_DIR="$OUTPUT_DIR" \
        DOCX_AGGRESSIVE=1 \
        CLEAN_BUILD=1 \
        SLIMLO_DEP_STEP="$step" \
        ./scripts/build.sh
    ); then
        return 1
    fi

    echo ">>> Running gate for S$(printf '%02d' "$step")"
    if ! (
        cd "$PROJECT_DIR"
        GATE_ENABLE_DOTNET=auto ./scripts/run-gate.sh "$OUTPUT_DIR"
    ) | tee "$gate_log"; then
        return 1
    fi

    echo ">>> Measuring artifact for S$(printf '%02d' "$step")"
    if ! "$PROJECT_DIR/scripts/measure-artifact.sh" "$OUTPUT_DIR" "$step_dir/size-report.json" "$step_dir/size-report.txt"; then
        return 1
    fi

    local -a dep_args=()
    local p
    for p in $(step_forbids "$step"); do
        dep_args+=(--forbid "$p")
    done

    echo ">>> Checking merged direct dependencies for S$(printf '%02d' "$step")"
    if ! "$PROJECT_DIR/scripts/assert-merged-deps.sh" \
        "$OUTPUT_DIR" \
        --write "$step_dir/merged-deps.txt" \
        "${dep_args[@]}"; then
        return 1
    fi

    if [ -f "$OUTPUT_DIR/build-metadata.json" ]; then
        cp "$OUTPUT_DIR/build-metadata.json" "$step_dir/build-metadata.json"
    fi

    if [ "$RUN_LINUX_VALIDATE" = "1" ]; then
        echo ">>> Linux Docker validation for S$(printf '%02d' "$step")"
        if ! (
            cd "$PROJECT_DIR"
            SLIMLO_DEP_STEP="$step" \
            OUTPUT_SUBDIR="output-linux-dep-ladder-s$(printf '%02d' "$step")" \
            ./scripts/linux-docker-validate.sh
        ) | tee "$step_dir/linux-validate.log"; then
            return 1
        fi
    fi
}

mkdir -p "$ARTIFACT_ROOT"
RESULTS_TSV="$(mktemp "${TMPDIR:-/tmp}/slimlo-dep-ladder.XXXXXX")"
trap 'rm -f "$RESULTS_TSV"' EXIT

echo "=== SlimLO macOS Dependency Ladder ==="
echo "LO_SRC_DIR:          $LO_SRC_DIR"
echo "OUTPUT_DIR:          $OUTPUT_DIR"
echo "ARTIFACT_ROOT:       $ARTIFACT_ROOT"
echo "NPROC:               $NPROC"
echo "RUN_LINUX_VALIDATE:  $RUN_LINUX_VALIDATE"
echo "BASELINE_STEP:       $BASELINE_STEP"
echo "LADDER_STEPS:        ${STEPS[*]}"
echo "REUSE_BASELINE:      $REUSE_BASELINE"
echo "REQUIRED_FINAL_STEP: $REQUIRED_FINAL_STEP"
echo ""

# Baseline (defaults to S02)
S00_DIR="$ARTIFACT_ROOT/S$(printf '%02d' "$BASELINE_STEP")-baseline"
mkdir -p "$S00_DIR"
if [ "$REUSE_BASELINE" = "1" ] && [ -f "$S00_DIR/size-report.json" ] && [ -f "$S00_DIR/gate.log" ]; then
    echo ">>> Reusing existing baseline S$(printf '%02d' "$BASELINE_STEP") from $S00_DIR"
else
    echo ">>> Building baseline S$(printf '%02d' "$BASELINE_STEP")"
    (
        cd "$PROJECT_DIR"
        NPROC="$NPROC" \
        LO_SRC_DIR="$LO_SRC_DIR" \
        OUTPUT_DIR="$OUTPUT_DIR" \
        DOCX_AGGRESSIVE=1 \
        CLEAN_BUILD=1 \
        SLIMLO_DEP_STEP="$BASELINE_STEP" \
        ./scripts/build.sh
    )
    (
        cd "$PROJECT_DIR"
        GATE_ENABLE_DOTNET=auto ./scripts/run-gate.sh "$OUTPUT_DIR"
    ) | tee "$S00_DIR/gate.log"
    "$PROJECT_DIR/scripts/measure-artifact.sh" "$OUTPUT_DIR" "$S00_DIR/size-report.json" "$S00_DIR/size-report.txt"
    "$PROJECT_DIR/scripts/assert-merged-deps.sh" "$OUTPUT_DIR" --write "$S00_DIR/merged-deps.txt"
    if [ -f "$OUTPUT_DIR/build-metadata.json" ]; then
        cp "$OUTPUT_DIR/build-metadata.json" "$S00_DIR/build-metadata.json"
    fi
fi

BASELINE_TOTAL_MB="$(extract_total_mb "$S00_DIR/size-report.json")"
BASELINE_MERGED_MB="$(merged_mb "$OUTPUT_DIR")"
printf "%s\tbaseline\taccepted\tok\t%s\t%s\t%s\n" \
    "$BASELINE_STEP" \
    "$BASELINE_TOTAL_MB" "$BASELINE_MERGED_MB" "$S00_DIR" >> "$RESULTS_TSV"

BEST_STEP="$BASELINE_STEP"
BEST_DIR="$S00_DIR"
BEST_TOTAL_MB="$BASELINE_TOTAL_MB"

for step in "${STEPS[@]}"; do
    name="$(step_name "$step")"
    step_dir="$ARTIFACT_ROOT/S$(printf '%02d' "$step")-$name"
    status="accepted"
    reason="ok"

    set +e
    run_step "$step" "$step_dir"
    rc=$?
    set -e

    if [ "$rc" -ne 0 ]; then
        status="rejected"
        reason="step_failed_rc_$rc"
        step_total="0.0"
        step_merged="0.0"
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
            "$step" "$name" "$status" "$reason" "$step_total" "$step_merged" "$step_dir" >> "$RESULTS_TSV"
        python3 - "$step_dir/decision.json" "$step" "$name" "$status" "$reason" "$BASELINE_TOTAL_MB" "$BASELINE_MERGED_MB" <<'PY'
import json, sys
out, step, name, status, reason, base_total, base_merged = sys.argv[1:]
doc = {
    "step": int(step),
    "name": name,
    "status": status,
    "reason": reason,
    "baseline_total_mb": float(base_total),
    "baseline_merged_mb": float(base_merged),
    "candidate_total_mb": None,
    "candidate_merged_mb": None,
    "delta_total_mb": None,
    "delta_merged_mb": None,
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, sort_keys=True)
    f.write("\n")
PY
        echo "REJECTED: step S$(printf '%02d' "$step") failed; continuing with next step."
        continue
    fi

    step_total="$(extract_total_mb "$step_dir/size-report.json")"
    step_merged="$(merged_mb "$OUTPUT_DIR")"
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$step" "$name" "$status" "$reason" "$step_total" "$step_merged" "$step_dir" >> "$RESULTS_TSV"
    python3 - "$step_dir/decision.json" "$step" "$name" "$status" "$reason" "$BASELINE_TOTAL_MB" "$BASELINE_MERGED_MB" "$step_total" "$step_merged" <<'PY'
import json, sys
out, step, name, status, reason, base_total, base_merged, cand_total, cand_merged = sys.argv[1:]
base_total = float(base_total)
base_merged = float(base_merged)
cand_total = float(cand_total)
cand_merged = float(cand_merged)
doc = {
    "step": int(step),
    "name": name,
    "status": status,
    "reason": reason,
    "baseline_total_mb": base_total,
    "baseline_merged_mb": base_merged,
    "candidate_total_mb": cand_total,
    "candidate_merged_mb": cand_merged,
    "delta_total_mb": round(cand_total - base_total, 3),
    "delta_merged_mb": round(cand_merged - base_merged, 3),
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, sort_keys=True)
    f.write("\n")
PY

    if python3 - "$step_total" "$BEST_TOTAL_MB" <<'PY'
import sys
step_total = float(sys.argv[1])
best_total = float(sys.argv[2])
sys.exit(0 if step_total < best_total else 1)
PY
    then
        BEST_STEP="$step"
        BEST_DIR="$step_dir"
        BEST_TOTAL_MB="$step_total"
    fi
done

python3 - "$RESULTS_TSV" "$ARTIFACT_ROOT/final-report.json" "$BEST_STEP" "$BEST_DIR" <<'PY'
import json
import sys

rows = []
with open(sys.argv[1], "r", encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        step, name, status, reason, total_mb, merged_mb, out_dir = line.split("\t")
        rows.append(
            {
                "step": int(step),
                "name": name,
                "status": status,
                "reason": reason,
                "total_mb": float(total_mb),
                "merged_mb": float(merged_mb),
                "artifact_dir": out_dir,
            }
        )

doc = {
    "best_step": int(sys.argv[3]),
    "best_artifact_dir": sys.argv[4],
    "steps": rows,
}
with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, sort_keys=True)
    f.write("\n")
PY

echo ""
echo "Wrote final report: $ARTIFACT_ROOT/final-report.json"
echo "Best accepted step: S$(printf '%02d' "$BEST_STEP")"
echo "Best artifact dir:  $BEST_DIR"
echo "Best total size MB: $BEST_TOTAL_MB"

if [ "$BEST_STEP" -lt "$REQUIRED_FINAL_STEP" ]; then
    echo "FAIL: best step S$(printf '%02d' "$BEST_STEP") is below REQUIRED_FINAL_STEP=$REQUIRED_FINAL_STEP"
    exit 1
fi
