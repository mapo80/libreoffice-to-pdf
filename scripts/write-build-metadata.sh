#!/bin/bash
# write-build-metadata.sh — Emit deterministic build metadata and input hashes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$PROJECT_DIR/output}"
OUTPUT_FILE="${2:-$OUTPUT_DIR/build-metadata.json}"

mkdir -p "$OUTPUT_DIR"

python3 - "$PROJECT_DIR" "$OUTPUT_FILE" <<'PY'
import datetime as dt
import glob
import hashlib
import json
import os
import platform
import subprocess
import sys
from typing import Dict, List, Tuple

project_dir = os.path.abspath(sys.argv[1])
output_file = os.path.abspath(sys.argv[2])


def rel(path: str) -> str:
    return os.path.relpath(path, project_dir).replace(os.sep, "/")


def file_sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def digest_patterns(patterns: List[str]) -> Tuple[str, Dict[str, str], List[str]]:
    files: List[str] = []
    for pattern in patterns:
        files.extend(glob.glob(os.path.join(project_dir, pattern), recursive=True))
    files = sorted({os.path.abspath(f) for f in files if os.path.isfile(f)})

    item_hashes: Dict[str, str] = {}
    combined = hashlib.sha256()
    rel_paths: List[str] = []
    for path in files:
        r = rel(path)
        d = file_sha256(path)
        item_hashes[r] = d
        rel_paths.append(r)
        combined.update(r.encode("utf-8"))
        combined.update(b"\0")
        combined.update(d.encode("utf-8"))
        combined.update(b"\n")
    return combined.hexdigest(), item_hashes, rel_paths


def cmd_version(cmd: List[str]) -> str:
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True)
        first = out.strip().splitlines()
        return first[0].strip() if first else ""
    except Exception:
        return ""


def runtime(cmd: str) -> str:
    try:
        return subprocess.check_output(["bash", "-lc", f"command -v {cmd}"], text=True).strip()
    except Exception:
        return ""


source_sets = {
    "lo_version": ["LO_VERSION"],
    "distro_configs": ["distro-configs/*.conf"],
    "patches": ["patches/*.sh", "patches/*.postautogen"],
    "icu_filter": ["icu-filter.json"],
    "build_scripts": ["scripts/*.sh"],
}

source_hashes = {}
for key, patterns in source_sets.items():
    combined, items, files = digest_patterns(patterns)
    source_hashes[key] = {
        "combined_sha256": combined,
        "files": files,
        "file_sha256": items,
    }

git_commit = cmd_version(["git", "rev-parse", "HEAD"])
git_branch = cmd_version(["git", "branch", "--show-current"])
git_dirty = cmd_version(["git", "status", "--porcelain"]) != ""

metadata = {
    "profile": "docx-aggressive",
    "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
    "project_dir": project_dir,
    "output_file": output_file,
    "git": {
        "commit": git_commit,
        "branch": git_branch,
        "dirty": git_dirty,
    },
    "platform": {
        "system": platform.system(),
        "release": platform.release(),
        "machine": platform.machine(),
        "python": platform.python_version(),
    },
    "toolchain": {
        "bash": cmd_version(["bash", "--version"]),
        "git": cmd_version(["git", "--version"]),
        "cmake": cmd_version(["cmake", "--version"]),
        "make": cmd_version(["make", "--version"]),
        "gcc": cmd_version(["gcc", "--version"]),
        "clang": cmd_version(["clang", "--version"]),
        "dotnet": cmd_version(["dotnet", "--version"]),
        "docker": cmd_version(["docker", "--version"]),
        "paths": {
            "git": runtime("git"),
            "cmake": runtime("cmake"),
            "make": runtime("make"),
            "gcc": runtime("gcc"),
            "clang": runtime("clang"),
            "dotnet": runtime("dotnet"),
            "docker": runtime("docker"),
        },
    },
    "source_hashes": source_hashes,
}

os.makedirs(os.path.dirname(output_file), exist_ok=True)
with open(output_file, "w", encoding="utf-8") as f:
    json.dump(metadata, f, indent=2, sort_keys=True)
    f.write("\n")

print(f"Wrote build metadata: {output_file}")
PY
