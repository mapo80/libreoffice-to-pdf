#!/bin/bash
# prepare-windows-handoff.sh — Generate reproducible Windows validation handoff package.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${1:-$PROJECT_DIR/artifacts/windows-handoff}"

BRANCH="$(git -C "$PROJECT_DIR" branch --show-current)"
COMMIT="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
COMMIT_SHORT="$(git -C "$PROJECT_DIR" rev-parse --short HEAD)"
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "$OUT_DIR"

cat > "$OUT_DIR/windows-handoff.json" <<EOF
{
  "generated_at_utc": "$GENERATED_AT",
  "branch": "$BRANCH",
  "commit": "$COMMIT",
  "expected_outputs": [
    "output/build-metadata.json",
    "output/size-report.json",
    "output/size-report.txt",
    "output/gate-windows.log"
  ]
}
EOF

cat > "$OUT_DIR/WINDOWS-HANDOFF.md" <<EOF
# SlimLO Windows Validation Handoff

- Generated at: \`$GENERATED_AT\`
- Branch: \`$BRANCH\`
- Commit: \`$COMMIT\`

## 1) Checkout exact code

\`\`\`powershell
git fetch origin
git checkout $BRANCH
git pull --ff-only origin $BRANCH
git rev-parse HEAD
\`\`\`

Expected HEAD: \`$COMMIT\`

## 2) Build on Windows (PowerShell launcher)

\`\`\`powershell
pwsh -ExecutionPolicy Bypass -File .\\scripts\\Start-WindowsBuild.ps1
\`\`\`

If resuming after a failed attempt:

\`\`\`powershell
pwsh -ExecutionPolicy Bypass -File .\\scripts\\Start-WindowsBuild.ps1 -SkipConfigure
\`\`\`

## 3) Run runtime gate in MSYS2

\`\`\`powershell
\$repo = (Get-Location).Path
& "C:\\msys64\\msys2_shell.cmd" -msys -defterm -no-start -here -c "cd '\$repo' && ./scripts/run-gate.sh output" | Tee-Object -FilePath output\\gate-windows.log
\`\`\`

## 4) Verify expected outputs

Required files:

- \`output/build-metadata.json\`
- \`output/size-report.json\`
- \`output/size-report.txt\`
- \`output/gate-windows.log\`

## 5) Pass/Fail checklist

- [ ] Build completed successfully.
- [ ] \`run-gate.sh\` passed for Windows artifact.
- [ ] \`output/build-metadata.json\` generated.
- [ ] \`output/size-report.json\` generated.
- [ ] \`output/size-report.txt\` generated.
- [ ] \`output/gate-windows.log\` generated.
- [ ] No unexpected dependency outside Windows allowlist.
- [ ] Share final commit SHA + checklist status.
EOF

echo "Wrote Windows handoff package:"
echo "  - $OUT_DIR/windows-handoff.json"
echo "  - $OUT_DIR/WINDOWS-HANDOFF.md"
echo "  - commit: $COMMIT_SHORT ($BRANCH)"
