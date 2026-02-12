# SlimLO

Minimal LibreOffice build for OOXML-to-PDF conversion, with C and .NET APIs.

SlimLO is **not a fork**. It applies idempotent patch scripts to vanilla LibreOffice source, making it trivial to track upstream releases. The result is a single merged library (~98 MB stripped, LTO-optimized) plus a thin C wrapper, packaged as a **186 MB** self-contained artifact.

**Supported platforms:** Linux x64/arm64, macOS arm64, Windows x64.

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
         +--------- libslimlo.{so,dylib,dll} --------+
                         |
                   LibreOfficeKit
                         |
              libmergedlo.{so,dylib,dll}
                  (~98 MB, LTO, stripped)
                  Writer + UNO + filters
                  merged into one library
```

## Getting the shared libraries

### Option 1: Docker build (Linux)

**Prerequisites:** Docker with BuildKit support, 16 GB+ RAM allocated to Docker Desktop.

```bash
# Build everything (~50 min first time, ~30s incremental)
DOCKER_BUILDKIT=1 docker build \
  -f docker/Dockerfile.linux-x64 \
  --build-arg SCRIPTS_HASH=$(cat scripts/*.sh patches/*.sh patches/*.postautogen | sha256sum | cut -d' ' -f1) \
  -t slimlo-build .

# Extract artifacts to ./output/
docker run --rm -v $(pwd)/output:/output slimlo-build
```

### Option 2: Native build (Linux, macOS, Windows)

The `build.sh` script handles all platforms natively. It clones LibreOffice source, applies patches, configures, builds, and extracts artifacts.

```bash
./scripts/build.sh
```

**Environment variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `LO_SRC_DIR` | `./lo-src` | Where to clone/find LO source (~2.5 GB) |
| `OUTPUT_DIR` | `./output` | Where to write artifacts |
| `NPROC` | auto-detected | Build parallelism (`-jN`) |
| `ICU_DATA_FILTER_FILE` | — | Path to `icu-filter.json` for locale filtering |

#### Linux prerequisites

```bash
# Ubuntu 24.04
sudo apt build-dep libreoffice
```

#### macOS prerequisites

```bash
brew install autoconf automake libtool pkg-config ccache \
             nasm flex bison gperf zip unzip make
```

**Important macOS notes:**
- GNU Make >= 4.0 is required (macOS ships 3.81). `brew install make` installs it to `/opt/homebrew/opt/make/libexec/gnubin/`. `build.sh` adds this to PATH automatically and checks the version before starting.
- gperf >= 3.1 is required (macOS ships 3.0.3). `brew install gperf` — `build.sh` prepends `/opt/homebrew/bin` to PATH so it takes precedence over the system version.
- `--disable-gui` is **not supported on macOS** (macOS uses Quartz VCL, not X11). A separate `SlimLO-macOS.conf` distro config omits this and other Linux-only flags. `build.sh` selects the right config automatically.
- macOS builds use `-flto=thin` (Clang) instead of `-flto=auto` (GCC). Patch 009 detects this automatically.
- The macOS .app bundle has a different directory layout — `extract-artifacts.sh` handles this transparently (see [macOS .app bundle layout](#macos-app-bundle-layout)).
- LibreOfficeKit's header has `#error "not supported on macOS"` — this is an upstream policy check, not a technical limitation. The C API wrapper bypasses it with a shim header (`lokit_macos_shim.h`).
- **Do NOT run `make` directly** — macOS system make (3.81) can't handle nested `define`/`endef` in LO makefiles. Always use `./scripts/build.sh` or invoke GNU Make 4 explicitly.

#### Windows prerequisites

Build requires Cygwin (bash/make/autoconf) + MSVC (cl.exe). The GitHub Actions workflow uses:
- `egor-tensin/setup-cygwin@v4` for Cygwin + build tools
- `ilammy/msvc-dev-cmd@v1` for MSVC environment
- `choco install nasm` for NASM assembler

### Output layout

```
output/
├── program/           # ~178 MB — all shared libraries
│   ├── libmergedlo.{so,dylib,dll}  # ~98 MB — core LO engine (LTO-optimized)
│   ├── libslimlo.{so,dylib,dll}    # C API wrapper
│   ├── libswlo.{so,dylib}          # Writer module
│   ├── lib*.{so,dylib}             # 134 other libraries (UNO, ICU, externals, stubs)
│   ├── sofficerc                    # Bootstrap RC chain (→ fundamentalrc → lounorc → unorc)
│   └── types/offapi.rdb            # UNO type registry
├── share/             # ~7.6 MB — runtime config
│   ├── registry/*.xcd       # XCD config (main, writer, graphicfilter, ctl, en-US)
│   ├── config/soffice.cfg/  # UI config needed by LOKit framework init
│   └── filter/              # Filter definitions
├── presets/            # Empty dir (required by LOKit)
└── include/
    └── slimlo.h             # C API header
```

### Test the conversion

```bash
# macOS (uses output-macos/ by default)
./tests/test.sh

# Linux with local build (uses output/ by default)
./tests/test.sh

# Custom artifact directory
SLIMLO_DIR=/path/to/artifacts ./tests/test.sh

# Force Docker mode (Linux only)
SLIMLO_TEST_MODE=docker ./tests/test.sh
```

The test script auto-detects the platform, compiles [test_convert.c](tests/test_convert.c) against the C API, runs a DOCX→PDF conversion, and validates the output has PDF magic bytes.

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

### Docker pipeline (Linux)

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

### Native pipeline (all platforms)

`build.sh` runs the same 7 steps on any platform:

1. **Clone** — shallow `git clone` of pinned LO tag (~2.5 GB)
2. **Patch** — `apply-patches.sh` runs all `patches/*.sh` scripts (idempotent)
3. **Config** — copies the platform-appropriate distro config (`SlimLO.conf` or `SlimLO-macOS.conf`)
4. **Configure** — `autogen.sh --with-distro=SlimLO[-macOS]`
5. **Post-autogen** — runs `patches/*.postautogen` scripts (LTO flags, etc.)
6. **Build** — `make -j$NPROC`
7. **Extract** — `extract-artifacts.sh` prunes `instdir/` to the minimal artifact set

### GitHub Actions CI

| Workflow | Runner | Config | Notes |
|----------|--------|--------|-------|
| `build-macos.yml` | `macos-14` (M1) | `SlimLO-macOS.conf` | Homebrew deps, ccache, 12h timeout |
| `build-windows.yml` | `windows-latest` | `SlimLO.conf` | Cygwin + MSVC, NPROC=4, 12h timeout |

Both workflows cache ccache and upload artifacts. Triggered on push to `main` (excluding `.md` and `dotnet/`).

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
| 008 | Adds `--export-dynamic` to `libmergedlo.so` to preserve UNO constructor symbols (Linux only; macOS ld64 exports default-visibility symbols automatically) |
| 009 | *(post-autogen)* Restricts LTO to merged lib only, preventing link failures in non-merged libs. Uses `-flto=thin` on macOS (Clang), `-flto=auto` on Linux (GCC). |
| 010 | Enables ICU data filtering for minimal locale data (en-US only). Patches ICU build to use `ICU_DATA_FILTER_FILE` instead of pre-built 30 MB data archive. |

## Cross-platform details

### Distro configs

| Config | Platform | Key differences |
|--------|----------|----------------|
| `SlimLO.conf` | Linux, Windows | `--disable-gui` (headless, SVP backend), `--disable-gtk3/4/qt5/qt6`, `--disable-dbus/gio/gstreamer/evolution2/cups/dconf/randr` |
| `SlimLO-macOS.conf` | macOS | No `--disable-gui` (macOS uses Quartz VCL, not X11), no Linux-specific flags, `--enable-bogus-pkg-config` (Homebrew workaround) |

Both share the same core flags: `--enable-slimlo`, `--enable-mergelibs`, `--enable-lto`, `--with-java=no`, `--disable-python`, etc.

On Windows, MSVC ignores GCC-style flags (`-Os`, `-ffunction-sections`) with warnings — they don't cause build failures. `--enable-lto` maps to `/GL` + `/LTCG` on MSVC automatically.

### macOS .app bundle layout

macOS uses a different directory structure inside the `.app` bundle. `build.sh` and `extract-artifacts.sh` handle this transparently:

| Content | Linux path | macOS path (inside `.app/Contents/`) |
|---------|-----------|--------------------------------------|
| Libraries | `program/` | `Frameworks/` |
| RC files, registries | `program/` | `Resources/` |
| Share data | `share/` | `Resources/` |
| Presets | `presets/` | `Resources/presets/` |
| Executables | `program/` | `MacOS/` |

The output directory always normalizes to `program/` and `share/` for consistency across platforms.

### Platform-specific behavior

- **Patch 008** (`--export-dynamic`): Skipped on macOS — ld64 exports default-visibility symbols automatically. On Linux, GNU ld requires this flag to preserve UNO constructor symbols in the merged lib.
- **Patch 009** (LTO): Uses `-flto=thin` on macOS (Clang) vs `-flto=auto` on Linux (GCC). Thin LTO is faster and uses less memory.
- **Patch 010** (ICU): BSD sed compatibility — uses `awk` and multi-line sed syntax for portable operation on macOS.
- **Patch 002** (module stripping): `apple_remote` is kept on all platforms — it's needed by `vclplug_osx` on macOS.
- **C API wrapper** (`slimlo-api/`): On macOS, `LibreOfficeKitInit.h` has `#error "not supported on macOS"`. The CMake build bypasses this with a shim header (`lokit_macos_shim.h`) that overrides `TARGET_OS_IPHONE`/`TARGET_OS_OSX` macros.
- **`extract-artifacts.sh`**: External library names differ on macOS (e.g., `libmwaw-0.3.3.dylib` vs `libmwaw-0.3-lo.so`). Glob patterns (`libmwaw-0.3*`) match both naming conventions.

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
| Bootstrap RC chain (Linux: `sofficerc` → `fundamentalrc` → `unorc` + `lounorc`; macOS: `sofficerc` → `fundamentalrc` → `lounorc`) | Missing any link breaks UNO service loading |
| `presets/` directory | Must exist (can be empty), or LOKit throws "User installation could not be completed" |

## Current status

| Metric | Linux arm64 | macOS arm64 |
|--------|-------------|-------------|
| Artifact size | **186 MB** | **108 MB** |
| Merged lib | 98 MB `.so` | 91 MB `.dylib` |
| Libraries | 137 | 140 |
| Constructor symbols | 557 | 560 |
| Zip size | 70 MB | 40 MB |

| | |
|---|---|
| LO version | `libreoffice-25.8.5.1` |
| Test result | `test.docx` (1,754 B) → valid PDF (26 KB) |

## Roadmap

### Further size reduction (186 MB → ~155 MB)

- [x] ICU data filter: custom ICU build with only required locales (patch 010)
- [ ] Measure actual savings from ICU filtering

### Multi-platform

- [ ] True linux-x64 build (Dockerfile currently builds for host arch)
- [ ] linux-arm64 dedicated Dockerfile
- [x] macOS native build (distro config, patch portability, `build.sh` support)
- [x] Windows build support (`build.sh` + `extract-artifacts.sh` Cygwin/MSVC support)

### CI/CD

- [x] GitHub Actions: macOS arm64 build (`build-macos.yml`)
- [x] GitHub Actions: Windows x64 build (`build-windows.yml`)
- [ ] GitHub Actions: Linux Docker build + integration test
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
├── icu-filter.json                     # ICU data filter (en-US only)
├── distro-configs/
│   ├── SlimLO.conf                     # Linux/Windows configure flags
│   └── SlimLO-macOS.conf               # macOS configure flags (no --disable-gui)
├── docker/
│   └── Dockerfile.linux-x64            # Multi-stage: deps → builder → runtime → extractor
├── .github/workflows/
│   ├── build-macos.yml                 # GitHub Actions: macOS arm64 build
│   └── build-windows.yml               # GitHub Actions: Windows x64 build
├── patches/                            # 10 idempotent .sh scripts (not .patch files)
│   ├── 001..008-*.sh                   # Pre-autogen patches
│   ├── 009-*.postautogen               # Post-autogen patch (LTO flags)
│   └── 010-icu-data-filter.sh          # ICU locale filtering
├── scripts/
│   ├── build.sh                        # Cross-platform build pipeline
│   ├── apply-patches.sh                # Runs all patches in order
│   ├── extract-artifacts.sh            # Cross-platform artifact extraction
│   ├── docker-build.sh                 # Docker build orchestrator
│   ├── pack-nuget.sh                   # NuGet packaging
│   ├── bump-lo-version.sh              # Update pinned LO version
│   └── test-patches.sh                 # Patch validation
├── slimlo-api/                         # C API wrapper
│   ├── CMakeLists.txt                  # Cross-platform CMake (so/dylib/dll)
│   ├── include/slimlo.h                # Public header
│   └── src/
│       ├── slimlo.cxx                  # LOKit-based implementation
│       └── lokit_macos_shim.h          # macOS LOKit #error bypass
├── dotnet/
│   ├── SlimLO/                         # .NET 8 managed wrapper (PdfConverter)
│   ├── SlimLO.Native/                  # Per-platform native NuGet package
│   └── SlimLO.Tests/                   # xUnit tests
└── tests/
    ├── test.sh                         # Cross-platform integration test (native + Docker)
    ├── test_convert.c                  # C test program
    └── test.docx                       # Test fixture (1,754 bytes)
```

## Runtime requirements

- **Docker seccomp** (Linux): `--security-opt seccomp=unconfined` required. LibreOffice uses `clone3()` for thread creation, blocked by Docker's default seccomp profile.
- **Build memory**: 16 GB+ for Docker Desktop. Large LO source files (`docxattributeoutput.cxx`, `DocumentContentOperationsManager.cxx`) need ~3 GB per compiler process.
- **Runtime memory**: ~200 MB per process.
- **Linux dependencies** (runtime): `libfontconfig1`, `libfreetype6`, `libcairo2`, `libxml2`, `libxslt1.1`, `libicu74`, `libnss3`, `fonts-liberation`.
- **macOS**: No additional runtime dependencies needed (system frameworks suffice).

## License

MPL-2.0 (matching LibreOffice). Built with `--enable-mpl-subset` to exclude GPL/LGPL components.
