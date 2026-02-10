# SlimLO

Minimal LibreOffice build for OOXML-to-PDF conversion, with C and .NET APIs.

SlimLO is **not a fork**. It applies idempotent patch scripts to vanilla LibreOffice source, making it trivial to track upstream releases. The result is a single `libmergedlo.so` (~100 MB stripped) plus a thin `libslimlo.so` C wrapper, packaged as a ~300 MB self-contained artifact.

## What works today

- DOCX, XLSX, PPTX to PDF conversion via LibreOfficeKit
- File-to-file and buffer-to-buffer APIs
- PDF options: version (1.7 / PDF/A-1,2,3), JPEG quality, DPI, tagged PDF, page ranges, password-protected documents
- Docker-based build with BuildKit cache mounts for incremental rebuilds (~50 min full, ~21s incremental)
- Integration test: 1,754-byte `.docx` produces a valid 28,795-byte PDF 1.7
- .NET 8 managed wrapper (`PdfConverter`) with cross-platform native library resolution

**Current artifact size:** 301 MB (261 MB `program/` + 40 MB `share/`)
**Platform:** linux-arm64 (Docker on Apple Silicon). The Dockerfile is named `linux-x64` but currently builds for the host architecture.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  .NET Application                               │
│  using var c = PdfConverter.Create();            │
│  c.ConvertToPdf("in.docx", "out.pdf");          │
└──────────────────┬──────────────────────────────┘
                   │ P/Invoke
┌──────────────────▼──────────────────────────────┐
│  libslimlo.so  (C API — slimlo.h)               │
│  slimlo_init / slimlo_convert_file / _buffer    │
└──────────────────┬──────────────────────────────┘
                   │ LibreOfficeKit
┌──────────────────▼──────────────────────────────┐
│  libmergedlo.so  (~100 MB stripped)              │
│  All of Writer, Calc, Impress merged into one   │
│  shared library with --enable-mergelibs          │
└─────────────────────────────────────────────────┘
```

## Quick start

### Build

```bash
# Full build (Docker — ~50 min first time, ~21s incremental)
DOCKER_BUILDKIT=1 docker build -f docker/Dockerfile.linux-x64 -t slimlo-build .

# Extract artifacts to ./output/
docker run --rm -v $(pwd)/output:/output slimlo-build
```

### Test

```bash
./tests/test.sh
```

This builds the runtime image, compiles the C test program inside Docker, converts `tests/test.docx` to PDF, and validates the output.

### Use from C

```c
#include "slimlo.h"

SlimLOHandle h = slimlo_init("/opt/slimlo");
SlimLOError err = slimlo_convert_file(h, "input.docx", "output.pdf",
                                       SLIMLO_FORMAT_UNKNOWN, NULL);
if (err != SLIMLO_OK)
    fprintf(stderr, "Error: %s\n", slimlo_get_error_message(h));
slimlo_destroy(h);
```

### Use from .NET

```csharp
using SlimLO;

using var converter = PdfConverter.Create("/opt/slimlo");
converter.ConvertToPdf("input.docx", "output.pdf");

// With options
converter.ConvertToPdf("input.docx", "output.pdf", new PdfOptions
{
    Version = PdfVersion.PdfA2,
    JpegQuality = 85,
    Dpi = 150,
    TaggedPdf = true,
    PageRange = "1-3"
});

// Buffer-to-buffer
byte[] docxBytes = File.ReadAllBytes("input.docx");
byte[] pdfBytes = converter.ConvertToPdf(docxBytes, DocumentFormat.Docx);
```

### Deploy with Docker

```bash
# Build the minimal runtime image (~300 MB + Ubuntu base)
docker build -f docker/Dockerfile.linux-x64 --target runtime -t slimlo-runtime .

# Run (seccomp=unconfined required for LibreOffice's clone3 syscall)
docker run --rm \
    --security-opt seccomp=unconfined \
    -v /path/to/files:/data \
    slimlo-runtime \
    /opt/slimlo/your-app /data/input.docx /data/output.pdf
```

## Project structure

```
.
├── LO_VERSION                     # Pinned LibreOffice version (libreoffice-25.8.5.1)
├── distro-configs/
│   └── SlimLO.conf                # Configure flags for minimal LO build
├── docker/
│   └── Dockerfile.linux-x64       # Multi-stage: deps → builder → runtime → extractor
├── patches/                       # Idempotent .sh scripts (not .patch files)
│   ├── 001-add-slimlo-configure-flag.sh
│   ├── 002-strip-modules.sh
│   ├── 003-slimlo-distro-config.sh
│   ├── 004-strip-filters.sh
│   ├── 005-strip-ui-libraries.sh
│   ├── 006-fix-mergelibs-conditionals.sh
│   ├── 007-fix-swui-db-conditionals.sh
│   └── 008-mergedlibs-export-constructors.sh
├── scripts/
│   ├── apply-patches.sh           # Runs all patches in order
│   ├── build.sh                   # Full build pipeline (non-Docker)
│   ├── extract-artifacts.sh       # Extracts minimal runtime from instdir
│   ├── docker-build.sh            # Docker build orchestrator
│   ├── pack-nuget.sh              # NuGet packaging
│   └── bump-lo-version.sh         # Version update helper
├── slimlo-api/                    # C API wrapper (libslimlo.so)
│   ├── CMakeLists.txt
│   ├── include/slimlo.h           # Public C header
│   └── src/slimlo.cxx             # Implementation over LibreOfficeKit
├── dotnet/
│   ├── SlimLO/                    # .NET 8 managed wrapper
│   │   ├── PdfConverter.cs        # High-level API
│   │   └── NativeMethods.cs       # P/Invoke bindings
│   ├── SlimLO.Native/             # Per-platform NuGet packages
│   └── SlimLO.Tests/              # xUnit tests
└── tests/
    ├── test.sh                    # Docker-based integration test
    ├── test_convert.c             # C test program
    └── generate_test_docx.py      # Test fixture generator
```

## How patching works

SlimLO uses **shell scripts** instead of `git .patch` files. Each script is idempotent (safe to re-run) and more resilient to upstream changes than line-number-dependent patches.

The `ENABLE_SLIMLO` flag flows through the build system:

```
configure.ac (--enable-slimlo)
  → config_host.mk.in (ENABLE_SLIMLO=TRUE)
    → makefiles use $(if $(ENABLE_SLIMLO),,target) to exclude modules
```

**What the patches strip:**

| Patch | What it does |
|-------|-------------|
| 001 | Adds `--enable-slimlo` flag to `configure.ac` |
| 002 | Conditionally excludes 41 non-essential modules (dbaccess, wizards, extras, ...) |
| 003 | Copies `SlimLO.conf` distro config into LO source tree |
| 004 | Strips 11 export filter targets (SVG, DocBook, XHTML, T602, ...) |
| 005 | Removes desktop deployment GUI and UIConfig targets |
| 006 | Fixes unconditional entries in `pre_MergedLibsList.mk` that conflict with disabled features |
| 007 | Moves DB-dependent code in `Library_swui.mk` behind `DBCONNECTIVITY` guard |
| 008 | Creates linker version script to export UNO constructor symbols from `libmergedlo.so` |

## Build configuration

Key configure flags in [SlimLO.conf](distro-configs/SlimLO.conf):

| Flag | Purpose |
|------|---------|
| `--enable-slimlo` | Activates all SlimLO makefile conditionals |
| `--disable-gui` | No desktop UI (implies `--enable-headless` with SVP backend) |
| `--enable-mergelibs` | Merges ~150 libraries into single `libmergedlo.so` |
| `--with-java=no` | No JVM dependency |
| `--disable-database-connectivity` | No database drivers (Firebird, MariaDB, PostgreSQL, LDAP) |
| `--disable-python` | No Python scripting |
| `--disable-scripting-beanshell` | No BeanShell (keep base scripting runtime — required) |
| `--without-galleries/templates/help/fonts` | No bundled data files |

## Docker caching

The build uses BuildKit cache mounts for fast incremental rebuilds:

- **`lo-src` cache**: Persists cloned LO source + compiled objects (`workdir/`). On rebuild, `make` only recompiles affected files.
- **`ccache`**: Compiler cache for even faster recompilation.
- **Config hash**: SHA-256 of `SlimLO.conf` + `patches/*.sh`. If unchanged, skips `autogen.sh` entirely (avoids timestamp cascade that triggers full recompile).

```bash
# Force full rebuild (clear caches)
docker builder prune --filter type=exec.cachemount
```

## Runtime requirements

- **Docker**: `--security-opt seccomp=unconfined` — LibreOffice uses `clone3()` for thread creation, which Docker's default seccomp profile blocks.
- **Memory**: 16 GB+ recommended for Docker Desktop. Large LO source files need ~3 GB per compiler process.
- **Bootstrap RC files**: The full chain `sofficerc → fundamentalrc → lounorc → unorc` must be present in `program/`. Missing any link breaks UNO service loading.
- **Presets directory**: Must exist at `<install_root>/presets/` (not `share/presets/`). Can be empty.

## C API reference

```c
// Initialize (once per process)
SlimLOHandle slimlo_init(const char* resource_path);
void slimlo_destroy(SlimLOHandle handle);

// Convert
SlimLOError slimlo_convert_file(handle, input_path, output_path, format_hint, options);
SlimLOError slimlo_convert_buffer(handle, input_data, input_size, format_hint, options,
                                   &output_data, &output_size);
void slimlo_free_buffer(uint8_t* buffer);

// Error handling
const char* slimlo_get_error_message(SlimLOHandle handle);  // NULL handle for init errors
const char* slimlo_version(void);
```

**Formats:** `SLIMLO_FORMAT_UNKNOWN` (auto-detect), `SLIMLO_FORMAT_DOCX`, `SLIMLO_FORMAT_XLSX`, `SLIMLO_FORMAT_PPTX`

**PDF options:** version (PDF 1.7 / PDF/A-1,2,3), JPEG quality, DPI, tagged PDF, page range, password

**Thread safety:** All conversions are serialized via internal mutex. For concurrency, use multiple processes.

## Roadmap

### Size reduction (301 MB target: ~100-150 MB)

- [ ] Analyze which of the 187 `.so` files are actually loaded at runtime (`LD_DEBUG=libs` / `strace`)
- [ ] Remove unused libraries from `extract-artifacts.sh`
- [ ] Re-enable LTO (`--enable-lto`) — dead code elimination at link time, significant `libmergedlo.so` reduction
- [ ] Prune XCD files in `share/registry/` — remove config for unused modules (Math, Base, Draw)
- [ ] Reduce ICU data to only required locales

### Multi-platform

- [ ] True linux-x64 build (currently builds for host architecture)
- [ ] linux-arm64 Dockerfile
- [ ] macOS build (native, without Docker)
- [ ] Windows build

### .NET integration testing

- [ ] End-to-end test with `SlimLO.Tests` (xUnit) inside Docker
- [ ] NuGet package generation (`dotnet pack`) with per-RID native packages
- [ ] CI pipeline for build + test + publish

### CI/CD

- [ ] GitHub Actions workflow for automated builds
- [ ] Multi-arch Docker image publishing
- [ ] NuGet package publishing to nuget.org or GitHub Packages

### Future optimizations

- [ ] Resource compression (`.tar.zst` with lazy decompression)
- [ ] Custom seccomp profile (allow `clone3` only, instead of `unconfined`)
- [ ] Font subset embedding for smaller PDFs
- [ ] Benchmark conversion performance and memory usage

## License

MPL-2.0 (matching LibreOffice's license). Built with `--enable-mpl-subset` to exclude GPL/LGPL components.
