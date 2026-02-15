#!/bin/bash
# measure-artifact.sh — Measure extracted artifact size and dependency graph.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_DIR="${1:-$PROJECT_DIR/output}"
OUTPUT_JSON="${2:-$ARTIFACT_DIR/size-report.json}"
OUTPUT_TXT="${3:-$ARTIFACT_DIR/size-report.txt}"

if [ ! -d "$ARTIFACT_DIR" ]; then
    echo "ERROR: artifact dir not found: $ARTIFACT_DIR"
    exit 1
fi

python3 - "$ARTIFACT_DIR" "$OUTPUT_JSON" "$OUTPUT_TXT" <<'PY'
import datetime as dt
import json
import os
import platform
import subprocess
import sys
from collections import Counter
from typing import Dict, List

artifact_dir = os.path.abspath(sys.argv[1])
output_json = os.path.abspath(sys.argv[2])
output_txt = os.path.abspath(sys.argv[3])


def run(cmd: List[str]) -> str:
    try:
        return subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True)
    except Exception:
        return ""


def dir_size_bytes(path: str) -> int:
    total = 0
    if not os.path.isdir(path):
        return 0
    for root, _, files in os.walk(path):
        for f in files:
            fp = os.path.join(root, f)
            try:
                total += os.path.getsize(fp)
            except OSError:
                pass
    return total


def human_mb(bytes_count: int) -> str:
    return f"{bytes_count / (1024 * 1024):.2f} MB"


subdirs = ["program", "share", "presets", "include"]
subdir_bytes = {name: dir_size_bytes(os.path.join(artifact_dir, name)) for name in subdirs}
total_bytes = sum(subdir_bytes.values())
total_kb = total_bytes // 1024

program_dir = os.path.join(artifact_dir, "program")
all_program_files: List[str] = []
if os.path.isdir(program_dir):
    for name in os.listdir(program_dir):
        full = os.path.join(program_dir, name)
        if os.path.isfile(full):
            all_program_files.append(full)

top_files = []
for fp in sorted(all_program_files, key=lambda p: os.path.getsize(p), reverse=True)[:40]:
    top_files.append(
        {
            "path": os.path.relpath(fp, artifact_dir).replace(os.sep, "/"),
            "bytes": os.path.getsize(fp),
            "size_mb": round(os.path.getsize(fp) / (1024 * 1024), 3),
        }
    )

system = platform.system()
scan_files: List[str] = []
if system == "Darwin":
    for fp in all_program_files:
        bn = os.path.basename(fp).lower()
        if bn.endswith(".dylib") or ".dylib." in bn or os.access(fp, os.X_OK):
            scan_files.append(fp)
elif system == "Linux":
    for fp in all_program_files:
        bn = os.path.basename(fp).lower()
        if bn.endswith(".so") or ".so." in bn or os.access(fp, os.X_OK):
            scan_files.append(fp)
else:
    for fp in all_program_files:
        bn = os.path.basename(fp).lower()
        if bn.endswith(".dll") or bn.endswith(".exe"):
            scan_files.append(fp)

file_dependencies: Dict[str, List[str]] = {}
dependency_counter: Counter = Counter()
tool = ""

if system == "Darwin":
    tool = "otool -L"
    for fp in sorted(scan_files):
        out = run(["otool", "-L", fp])
        deps = []
        lines = out.splitlines()[1:]
        for line in lines:
            s = line.strip()
            if not s:
                continue
            dep = s.split(" (compatibility version")[0].strip()
            if dep:
                deps.append(dep)
                dependency_counter[dep] += 1
        file_dependencies[os.path.relpath(fp, artifact_dir).replace(os.sep, "/")] = deps
elif system == "Linux":
    tool = "ldd"
    for fp in sorted(scan_files):
        out = run(["ldd", fp])
        deps = []
        for line in out.splitlines():
            s = line.strip()
            if not s:
                continue
            if "=>" in s:
                left, right = s.split("=>", 1)
                dep = left.strip()
                if dep:
                    deps.append(dep)
                    dependency_counter[dep] += 1
            elif "ld-linux" in s or "linux-vdso" in s:
                dep = s.split()[0]
                deps.append(dep)
                dependency_counter[dep] += 1
        file_dependencies[os.path.relpath(fp, artifact_dir).replace(os.sep, "/")] = deps
else:
    tool = "dumpbin /dependents (if available)"
    dumpbin = run(["bash", "-lc", "command -v dumpbin.exe || true"]).strip()
    if dumpbin:
        for fp in sorted(scan_files):
            out = run(["dumpbin.exe", "/dependents", fp])
            deps = []
            in_deps = False
            for line in out.splitlines():
                s = line.strip()
                if "Image has the following dependencies:" in s:
                    in_deps = True
                    continue
                if in_deps:
                    if not s:
                        continue
                    if s.startswith("Summary"):
                        break
                    if s.endswith(".DLL") or s.endswith(".dll"):
                        deps.append(s)
                        dependency_counter[s] += 1
            file_dependencies[os.path.relpath(fp, artifact_dir).replace(os.sep, "/")] = deps

top_dependencies = [
    {"dependency": dep, "count": count}
    for dep, count in dependency_counter.most_common(120)
]

report = {
    "profile": "docx-aggressive",
    "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
    "artifact_dir": artifact_dir,
    "platform": {
        "system": system,
        "release": platform.release(),
        "machine": platform.machine(),
    },
    "size": {
        "total_bytes": total_bytes,
        "total_kb": total_kb,
        "total_mb": round(total_bytes / (1024 * 1024), 3),
        "subdir_bytes": subdir_bytes,
    },
    "program": {
        "file_count": len(all_program_files),
        "scan_file_count": len(scan_files),
        "top_files": top_files,
    },
    "dependencies": {
        "tool": tool,
        "unique_count": len(dependency_counter),
        "top_dependencies": top_dependencies,
        "by_file": file_dependencies,
    },
}

os.makedirs(os.path.dirname(output_json), exist_ok=True)
with open(output_json, "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2, sort_keys=True)
    f.write("\n")

lines = []
lines.append("=== SlimLO Size Report ===")
lines.append(f"Artifact: {artifact_dir}")
lines.append(f"Profile:  docx-aggressive")
lines.append(f"Platform: {system} {platform.machine()} ({platform.release()})")
lines.append("")
lines.append(f"Total extracted size: {human_mb(total_bytes)} ({total_kb} KB)")
for name in subdirs:
    lines.append(f"  - {name}: {human_mb(subdir_bytes[name])} ({subdir_bytes[name] // 1024} KB)")
lines.append("")
lines.append("Top files:")
for item in top_files[:20]:
    lines.append(f"  - {item['path']}: {item['size_mb']} MB")
lines.append("")
lines.append(f"Dependency tool: {tool}")
lines.append(f"Unique dependencies: {len(dependency_counter)}")
lines.append("Top dependencies:")
for dep in top_dependencies[:30]:
    lines.append(f"  - {dep['dependency']}: {dep['count']}")
lines.append("")
lines.append(f"JSON: {output_json}")

os.makedirs(os.path.dirname(output_txt), exist_ok=True)
with open(output_txt, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
    f.write("\n")

print(f"Wrote size report: {output_json}")
print(f"Wrote size summary: {output_txt}")
PY
