#!/bin/bash
# run-gate.sh — Deterministic DOCX gate with hard timeouts and worker cleanup.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ARTIFACT_DIR="${1:-}"
if [ -z "$ARTIFACT_DIR" ]; then
    case "$(uname -s)" in
        Darwin) ARTIFACT_DIR="$PROJECT_DIR/output-macos" ;;
        *)      ARTIFACT_DIR="$PROJECT_DIR/output" ;;
    esac
fi

if [ ! -d "$ARTIFACT_DIR/program" ]; then
    echo "ERROR: artifact dir must contain program/: $ARTIFACT_DIR"
    exit 1
fi

GATE_TIMEOUT_C="${GATE_TIMEOUT_C:-240}"
GATE_TIMEOUT_DOTNET="${GATE_TIMEOUT_DOTNET:-480}"
GATE_ENABLE_DOTNET="${GATE_ENABLE_DOTNET:-auto}"   # auto|0|1
GATE_DOTNET_FRAMEWORK="${GATE_DOTNET_FRAMEWORK:-net8.0}"
GATE_DOTNET_FILTER="${GATE_DOTNET_FILTER:-FullyQualifiedName~PdfConverterIntegrationTests.ConvertAsync_ValidDocx_ProducesPdf|FullyQualifiedName~PdfConverterIntegrationTests.ConvertAsync_BufferValidDocx_ReturnsPdfBytes|FullyQualifiedName~PdfConverterStreamIntegrationTests.ConvertAsync_StreamToStream_ValidDocx_ProducesPdf|FullyQualifiedName~PdfConverterStreamIntegrationTests.ConvertAsync_ConcurrentStreamToStream_AllSucceed|FullyQualifiedName~PdfConverterIntegrationTests.ConvertAsync_BufferUnsupportedFormat_ReturnsFailure|FullyQualifiedName~PdfConverterStreamValidationTests.ConvertAsync_StreamToStream_UnsupportedFormat_ReturnsFailure|FullyQualifiedName~PdfConverterStreamValidationTests.ConvertAsync_StreamToFile_UnsupportedFormat_ReturnsFailure}"
GATE_STRICT_WARNINGS="${GATE_STRICT_WARNINGS:-1}"   # 0|1
GATE_STRICT_WARNING_PATTERNS="${GATE_STRICT_WARNING_PATTERNS:-language-subtag-registry.xml}"

run_with_timeout() {
    local seconds="$1"
    shift
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$seconds" "$@" <<'PY'
import os
import signal
import subprocess
import sys
import time

timeout = int(sys.argv[1])
cmd = sys.argv[2:]

proc = subprocess.Popen(cmd, preexec_fn=os.setsid)
deadline = time.monotonic() + timeout

while True:
    rc = proc.poll()
    if rc is not None:
        sys.exit(rc)

    if time.monotonic() >= deadline:
        # Best effort process-group termination. If a child is in uninterruptible
        # state, do not block forever waiting for it.
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        time.sleep(1.0)
        if proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        sys.exit(124)

    time.sleep(0.2)
PY
        return $?
    fi

    # Fallback for environments without python3.
    local rc=0
    perl -e 'alarm shift; exec @ARGV' "$seconds" "$@" || rc=$?
    if [ "$rc" -eq 142 ]; then
        return 124
    fi
    return "$rc"
}

cleanup_orphans() {
    pkill -f '/slimlo-prune-probe\..*/program/slimlo_worker' 2>/dev/null || true
    pkill -f '/slimlo-gate\..*/program/slimlo_worker' 2>/dev/null || true
    pkill -f '/program/slimlo_worker(\.exe)?$' 2>/dev/null || true
    pkill -f '/tmp/slimlo_test_convert' 2>/dev/null || true
}

check_strict_warnings() {
    local log_path="$1"
    local context="$2"
    local hit=0

    if [ "$GATE_STRICT_WARNINGS" = "0" ]; then
        return 0
    fi

    local old_ifs="$IFS"
    IFS=';'
    for pattern in $GATE_STRICT_WARNING_PATTERNS; do
        [ -z "$pattern" ] && continue
        if grep -Fq "$pattern" "$log_path"; then
            if [ "$hit" -eq 0 ]; then
                echo "FAIL: strict warning gate matched in $context"
            fi
            echo "  pattern: $pattern"
            grep -Fn "$pattern" "$log_path" | head -n 5 | sed 's/^/  /'
            hit=1
        fi
    done
    IFS="$old_ifs"

    if [ "$hit" -ne 0 ]; then
        return 1
    fi
    return 0
}

TMP_C_LOG=""
TMP_DOTNET_LOG=""
cleanup_all() {
    cleanup_orphans
    [ -n "$TMP_C_LOG" ] && rm -f "$TMP_C_LOG" || true
    [ -n "$TMP_DOTNET_LOG" ] && rm -f "$TMP_DOTNET_LOG" || true
}

trap cleanup_all EXIT

echo "=== SlimLO Gate ==="
echo "Artifact: $ARTIFACT_DIR"
echo "C timeout: ${GATE_TIMEOUT_C}s"
echo "Dotnet timeout: ${GATE_TIMEOUT_DOTNET}s"
echo "Strict warnings: ${GATE_STRICT_WARNINGS} (${GATE_STRICT_WARNING_PATTERNS})"

# Best-effort cleanup from previous interrupted probes before starting.
cleanup_orphans

echo "[1/2] C smoke gate (tests/test.sh)"
TMP_C_LOG="$(mktemp "${TMPDIR:-/tmp}/slimlo-gate-c.XXXXXX.log")"
set +e
run_with_timeout "$GATE_TIMEOUT_C" env SLIMLO_DIR="$ARTIFACT_DIR" "$PROJECT_DIR/tests/test.sh" 2>&1 | tee "$TMP_C_LOG"
RC_C=${PIPESTATUS[0]}
set -e
if [ "$RC_C" -eq 124 ]; then
    echo "FAIL: C smoke gate timed out after ${GATE_TIMEOUT_C}s"
    exit 124
fi
if [ "$RC_C" -ne 0 ]; then
    echo "FAIL: C smoke gate failed (exit $RC_C)"
    exit "$RC_C"
fi
if ! check_strict_warnings "$TMP_C_LOG" "C smoke gate"; then
    exit 1
fi
echo "PASS: C smoke gate"

DOTNET_AVAILABLE=0
if command -v dotnet >/dev/null 2>&1 && [ -d "$PROJECT_DIR/dotnet/SlimLO.Tests" ]; then
    DOTNET_AVAILABLE=1
fi

ENABLE_DOTNET=0
case "$GATE_ENABLE_DOTNET" in
    1) ENABLE_DOTNET=1 ;;
    0) ENABLE_DOTNET=0 ;;
    auto)
        if [ "$DOTNET_AVAILABLE" -eq 1 ]; then
            ENABLE_DOTNET=1
        fi
        ;;
    *)
        echo "ERROR: GATE_ENABLE_DOTNET must be auto, 0, or 1 (got '$GATE_ENABLE_DOTNET')"
        exit 1
        ;;
esac

if [ "$ENABLE_DOTNET" -eq 1 ]; then
    WORKER="$ARTIFACT_DIR/program/slimlo_worker"
    if [ ! -x "$WORKER" ] && [ -x "$ARTIFACT_DIR/program/slimlo_worker.exe" ]; then
        WORKER="$ARTIFACT_DIR/program/slimlo_worker.exe"
    fi
    if [ ! -x "$WORKER" ]; then
        echo "FAIL: .NET gate requested but worker missing in artifact"
        exit 1
    fi

    EXPECTED_DOTNET_MAJOR="$(echo "$GATE_DOTNET_FRAMEWORK" | sed -E 's/^net([0-9]+).*/\1/')"
    if ! dotnet --list-runtimes 2>/dev/null | awk '/Microsoft.NETCore.App/ {print $2}' | cut -d. -f1 | grep -qx "$EXPECTED_DOTNET_MAJOR"; then
        if [ "$GATE_ENABLE_DOTNET" = "1" ]; then
            echo "FAIL: requested .NET gate but runtime $GATE_DOTNET_FRAMEWORK is unavailable"
            exit 1
        fi
        echo "WARN: runtime $GATE_DOTNET_FRAMEWORK unavailable, skipping .NET gate"
        echo "=== Gate PASSED (C only) ==="
        exit 0
    fi

    echo "[2/2] .NET gate ($GATE_DOTNET_FRAMEWORK)"
    TMP_DOTNET_LOG="$(mktemp "${TMPDIR:-/tmp}/slimlo-gate-dotnet.XXXXXX.log")"
    set +e
    (
        cd "$PROJECT_DIR/dotnet"
        run_with_timeout "$GATE_TIMEOUT_DOTNET" \
            env \
                SLIMLO_RESOURCE_PATH="$ARTIFACT_DIR" \
                SLIMLO_WORKER_PATH="$WORKER" \
                dotnet test SlimLO.Tests/SlimLO.Tests.csproj \
                    --nologo \
                    --verbosity quiet \
                    -f "$GATE_DOTNET_FRAMEWORK" \
                    --filter "$GATE_DOTNET_FILTER"
    ) 2>&1 | tee "$TMP_DOTNET_LOG"
    RC_DOTNET=${PIPESTATUS[0]}
    set -e
    if [ "$RC_DOTNET" -eq 124 ]; then
        echo "FAIL: .NET gate timed out after ${GATE_TIMEOUT_DOTNET}s"
        exit 124
    fi
    if [ "$RC_DOTNET" -ne 0 ]; then
        echo "FAIL: .NET gate failed (exit $RC_DOTNET)"
        exit "$RC_DOTNET"
    fi
    if ! check_strict_warnings "$TMP_DOTNET_LOG" ".NET gate"; then
        exit 1
    fi
    echo "PASS: .NET gate"
else
    echo "[2/2] .NET gate skipped (GATE_ENABLE_DOTNET=$GATE_ENABLE_DOTNET)"
fi

echo "=== Gate PASSED ==="
