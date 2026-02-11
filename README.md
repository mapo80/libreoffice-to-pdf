# SlimLO

Minimal LibreOffice build for OOXML-to-PDF conversion, with C and .NET APIs.

SlimLO is **not a fork**. It applies idempotent patch scripts to vanilla LibreOffice source, making it trivial to track upstream releases. The result is a single `libmergedlo.so` (~98 MB stripped, LTO-optimized) plus a thin `libslimlo.so` C wrapper, packaged as a **186 MB** self-contained artifact.

## Architecture

```
                    Your application
                         |
         ----------------+----------------
         |                                |
    .NET (P/Invoke)                  C (direct)
         |                                |
    PdfConverter.cs               #include "slimlo.h"
         |                                |
         +---------- libslimlo.so --------+
                         |
                   LibreOfficeKit
                         |
                   libmergedlo.so
                  (~98 MB, LTO, stripped)
                  Writer + UNO + filters
                  merged into one .so
```

## Getting the shared libraries

### Prerequisites

- Docker with BuildKit support
- 16 GB+ RAM allocated to Docker Desktop (large LO source files need ~3 GB per compiler process)

### Build

```bash
# Build everything (~50 min first time, ~30s incremental)
DOCKER_BUILDKIT=1 docker build \
  -f docker/Dockerfile.linux-x64 \
  --build-arg SCRIPTS_HASH=$(cat scripts/*.sh patches/*.sh patches/*.postautogen | sha256sum | cut -d' ' -f1) \
  -t slimlo-build .

# Extract artifacts to ./output/
docker run --rm -v $(pwd)/output:/output slimlo-build
```

The `output/` directory will contain:

```
output/
├── program/           # 178 MB — all shared libraries
│   ├── libmergedlo.so       # 98 MB  — core LO engine (LTO-optimized)
│   ├── libslimlo.so         # C API wrapper (+ .so.0, .so.0.1.0 symlinks)
│   ├── libswlo.so           # Writer module
│   ├── lib*.so              # 134 other .so files (UNO, ICU, externals, stubs)
│   ├── sofficerc            # Bootstrap RC chain (→ fundamentalrc → lounorc → unorc)
│   └── types/offapi.rdb     # UNO type registry
├── share/             # 7.6 MB — runtime config
│   ├── registry/*.xcd       # XCD config (main, writer, graphicfilter, ctl, en-US)
│   ├── config/soffice.cfg/  # UI config needed by LOKit framework init
│   └── filter/              # Filter definitions
├── presets/            # Empty dir (required by LOKit)
└── include/
    └── slimlo.h             # C API header
```

### Test the conversion

```bash
# Build the runtime image
docker build -f docker/Dockerfile.linux-x64 --target runtime -t slimlo-runtime .

# Convert a DOCX file (seccomp=unconfined required for LO's clone3 syscall)
docker run --rm --security-opt seccomp=unconfined \
  -v $(pwd)/tests:/data \
  slimlo-runtime \
  sh -c 'cd /tmp && your-app /data/test.docx /data/output.pdf'
```

Or use the included integration test:

```bash
./tests/test.sh
```

### Local build (without Docker)

```bash
# Requires: apt build-dep libreoffice (Ubuntu 24.04)
./scripts/build.sh
```

## Using the C API

```c
#include "slimlo.h"

int main() {
    SlimLOHandle h = slimlo_init("/path/to/slimlo");
    if (!h) return 1;

    SlimLOError err = slimlo_convert_file(
        h, "input.docx", "output.pdf",
        SLIMLO_FORMAT_UNKNOWN,  // auto-detect from extension
        NULL                    // default PDF options
    );

    if (err != SLIMLO_OK)
        fprintf(stderr, "Error: %s\n", slimlo_get_error_message(h));

    slimlo_destroy(h);
    return err;
}
```

**API surface:**

| Function | Description |
|----------|-------------|
| `slimlo_init(resource_path)` | Initialize (once per process). Returns opaque handle. |
| `slimlo_destroy(handle)` | Free all resources. |
| `slimlo_convert_file(h, in, out, fmt, opts)` | Convert file to PDF. |
| `slimlo_convert_buffer(h, data, size, fmt, opts, &out, &outsize)` | Convert in-memory buffer to PDF. |
| `slimlo_free_buffer(buf)` | Free buffer from `convert_buffer`. |
| `slimlo_get_error_message(h)` | Last error (pass NULL for init errors). |

**PDF options (`SlimLOPdfOptions`):** version (1.7 / PDF/A-1,2,3), JPEG quality, DPI, tagged PDF, page range, password.

**Thread safety:** Conversions are serialized via internal mutex. For concurrency, use multiple processes.

## Using the .NET wrapper

```csharp
using SlimLO;

using var converter = PdfConverter.Create("/opt/slimlo");

// File to file
converter.ConvertToPdf("input.docx", "output.pdf");

// With options
converter.ConvertToPdf("input.docx", "output.pdf", new PdfOptions
{
    Version = PdfVersion.PdfA2,
    JpegQuality = 85,
    Dpi = 150
});

// Buffer to buffer
byte[] pdfBytes = converter.ConvertToPdf(
    File.ReadAllBytes("input.docx"), DocumentFormat.Docx);
```

## Build pipeline

The Docker build is fully reproducible and uses aggressive caching:

```
┌─ Stage 1: deps ─────────────────────────────────────┐
│  Ubuntu 24.04 + apt build-dep libreoffice            │
│  (stable layer, rarely changes)                      │
└──────────────────────────────────────────────────────┘
                        |
┌─ Stage 2: builder ───────────────────────────────────┐
│  Single RUN with two cache mounts:                   │
│                                                      │
│  /build/lo-src (cache) ── clone + patch + build      │
│  /ccache       (cache) ── compiler cache             │
│                                                      │
│  1. Clone LO source (skip if cached)                 │
│  2. Hash config+patches → skip autogen if unchanged  │
│  3. Apply patches (idempotent .sh scripts)           │
│  4. autogen.sh --with-distro=SlimLO                  │
│  5. Post-autogen patches (LTO flags)                 │
│  6. make -j10 (incremental via cache)                │
│  7. extract-artifacts.sh → /artifacts                │
│  8. Build libslimlo.so (CMake)                       │
└──────────────────────────────────────────────────────┘
                        |
┌─ Stage 3: runtime ───────────────────────────────────┐
│  Minimal Ubuntu + runtime deps only                  │
│  COPY --from=builder /artifacts → /opt/slimlo        │
└──────────────────────────────────────────────────────┘
```

**Incremental rebuilds:** When only patches or config change, the cached `lo-src` has all compiled objects. `make` detects what changed and only recompiles affected files (~30s for a patch change vs ~50 min full build).

**Config hash caching:** `SHA-256(SlimLO.conf + patches/*.sh + patches/*.postautogen)` is compared against the cached hash. If unchanged, `autogen.sh` is skipped entirely, preventing timestamp cascades that trigger unnecessary full recompilation.

## How patching works

SlimLO uses **shell scripts** instead of `git .patch` files. Each script is idempotent (safe to re-run) and resilient to upstream line-number changes.

The `ENABLE_SLIMLO` flag flows through the LO build system:

```
configure.ac  →  --enable-slimlo
config_host.mk.in  →  ENABLE_SLIMLO=TRUE
makefiles  →  $(if $(ENABLE_SLIMLO),,target)  to exclude targets
```

| Patch | What it does |
|-------|-------------|
| 001 | Adds `--enable-slimlo` flag to `configure.ac` and `config_host.mk.in` |
| 002 | Conditionally excludes 41 non-essential modules (dbaccess, wizards, extras, ...) |
| 003 | Copies `SlimLO.conf` distro config into the LO source tree |
| 004 | Strips 11 non-Writer export filter targets (SVG, DocBook, XHTML, T602, ...) |
| 005 | Removes desktop deployment GUI and UIConfig targets |
| 006 | Fixes unconditional entries in `pre_MergedLibsList.mk` that conflict with disabled features |
| 007 | Moves DB-dependent code in `Library_swui.mk` behind `DBCONNECTIVITY` guard |
| 008 | Adds `--export-dynamic` to `libmergedlo.so` to preserve UNO constructor symbols |
| 009 | *(post-autogen)* Restricts LTO to merged lib only, preventing link failures in non-merged libs |

## Size reduction journey

Full LibreOffice `instdir/` is **~1.5 GB**. SlimLO reduces it in three stages:

### Stage 1: Build-time stripping (1.5 GB → 300 MB)

9 patch scripts conditionally exclude 41+ modules at compile time. Disabled: database connectivity, Java, Python, GUI backends (GTK/Qt), desktop integration, galleries, templates, help, fonts. All code merges into `libmergedlo.so` via `--enable-mergelibs`.

### Stage 2: Artifact pruning (300 MB → 214 MB)

`extract-artifacts.sh` removes runtime files not needed for DOCX→PDF:

- Non-Writer modules: Calc (23 MB), Impress (10 MB), Math (1.8 MB)
- External import libraries: mwaw, etonyek, wps, orcus, odfgen, wpd, wpg (20 MB)
- VBA macros, CUI dialogs, form controls, UI-only libraries (11 MB)
- XCD config for Calc/Impress/Math/Base/Draw/xsltfilter
- Extra locale data (keep only `liblocaledata_en.so`)

### Stage 3: LTO + deep pruning (214 MB → 186 MB)

- **LTO** (`--enable-lto`): Link-time optimization on `libmergedlo.so` with dead code elimination. Applied only to merged lib (patch 009 prevents LTO on non-merged libs that would fail).
- **patchelf**: `patchelf --remove-needed libcurl.so.4` removes unused dynamic dependency (~4.6 MB saved)
- **Config pruning**: Removed `oovbaapi.rdb`, `lingucomponent.xcd`, signature SVGs

### What cannot be removed (tested and confirmed)

| Item | Why it must stay |
|------|-----------------|
| `.ui` files in `soffice.cfg/` | LOKit loads dialog files even in headless mode |
| RDF stack (`librdf`, `libraptor2`, `librasqal`) | `librdf_new_world` called at runtime for DOCX→PDF |
| Stub `.so` files (21 bytes each) | UNO checks file existence before falling back to merged lib |
| Bootstrap RC chain (`sofficerc` → `fundamentalrc` → `lounorc` → `unorc`) | Missing any link breaks UNO service loading |
| `presets/` directory | Must exist (can be empty), or LOKit throws "User installation could not be completed" |

## Current status

| Metric | Value |
|--------|-------|
| Artifact size | **186 MB** (178 MB `program/` + 7.6 MB `share/`) |
| `libmergedlo.so` | 98 MB (stripped, LTO) |
| Libraries | 137 (82 stubs + 55 real) |
| Constructor symbols | 557 exported |
| Test result | `test.docx` (1,754 B) → valid PDF (26 KB) |
| LO version | `libreoffice-25.8.5.1` |
| Platform | linux-arm64 (Docker on Apple Silicon) |

## Roadmap

### Further size reduction (186 MB → ~155 MB)

- [ ] ICU data filter: custom ICU build with only required locales. ICU libs are 36 MB; filtering could save ~25-28 MB.

### Multi-platform

- [ ] True linux-x64 build (Dockerfile currently builds for host arch)
- [ ] linux-arm64 dedicated Dockerfile
- [ ] macOS native build (without Docker)
- [ ] Windows build

### CI/CD

- [ ] GitHub Actions: automated Docker build + integration test
- [ ] Multi-arch Docker image publishing
- [ ] NuGet package generation and publishing

### Quality

- [ ] Custom seccomp profile (allow only `clone3`, instead of `seccomp=unconfined`)
- [ ] End-to-end .NET tests inside Docker
- [ ] Benchmark: conversion performance and memory usage

## Project structure

```
.
├── LO_VERSION                          # Pinned LO tag (libreoffice-25.8.5.1)
├── distro-configs/
│   └── SlimLO.conf                     # 54 configure flags for minimal build
├── docker/
│   └── Dockerfile.linux-x64            # Multi-stage: deps → builder → runtime → extractor
├── patches/                            # 9 idempotent .sh scripts (not .patch files)
│   ├── 001..008-*.sh                   # Pre-autogen patches
│   └── 009-*.postautogen               # Post-autogen patch (LTO flags)
├── scripts/
│   ├── build.sh                        # Full local build pipeline
│   ├── apply-patches.sh                # Runs all patches in order
│   ├── extract-artifacts.sh            # Prunes instdir → minimal artifact set
│   ├── docker-build.sh                 # Docker build orchestrator
│   ├── pack-nuget.sh                   # NuGet packaging
│   ├── bump-lo-version.sh              # Update pinned LO version
│   └── test-patches.sh                 # Patch validation
├── slimlo-api/                         # C API wrapper
│   ├── CMakeLists.txt
│   ├── include/slimlo.h                # Public header
│   └── src/slimlo.cxx                  # LOKit-based implementation
├── dotnet/
│   ├── SlimLO/                         # .NET 8 managed wrapper (PdfConverter)
│   ├── SlimLO.Native/                  # Per-platform native NuGet package
│   └── SlimLO.Tests/                   # xUnit tests
└── tests/
    ├── test.sh                         # Integration test (Docker-based)
    ├── test_convert.c                  # C test program
    └── test.docx                       # Test fixture (1,754 bytes)
```

## Runtime requirements

- **Docker seccomp**: `--security-opt seccomp=unconfined` required. LibreOffice uses `clone3()` for thread creation, blocked by Docker's default seccomp profile.
- **Memory**: 16 GB+ for Docker Desktop during build. Runtime needs ~200 MB.
- **Dependencies** (runtime image): `libfontconfig1`, `libfreetype6`, `libcairo2`, `libxml2`, `libxslt1.1`, `libicu74`, `libnss3`, `fonts-liberation`.

## License

MPL-2.0 (matching LibreOffice). Built with `--enable-mpl-subset` to exclude GPL/LGPL components.
