# SlimLO

Minimal LibreOffice build for OOXML-to-PDF conversion, with C and .NET APIs.

SlimLO is **not a fork**. It applies idempotent patch scripts to vanilla LibreOffice source, making it trivial to track upstream releases. The result is a single merged library (~98 MB stripped, LTO-optimized) plus a thin C wrapper, packaged as a **186 MB** (Linux) / **108 MB** (macOS) self-contained artifact.

**Supported platforms:** Linux x64/arm64, macOS arm64/x64, Windows x64.

## Architecture

```
                    Your application
                         |
         ----------------+----------------
         |                                |
    .NET SDK (async)                 C (direct)
         |                                |
    PdfConverter                  #include "slimlo.h"
         |                                |
    WorkerPool                            |
    ├─ slimlo_worker[0] ──stdin/stdout──┐ |
    ├─ slimlo_worker[1] ──stdin/stdout──┼─+
    └─ ...                              |
                                        |
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

Build requires MSYS2 (bash/make/autoconf) + MSVC (cl.exe). The GitHub Actions workflow uses:
- `msys2/setup-msys2@v2` with MSYS subsystem for POSIX tools
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

## Using the .NET SDK

The .NET SDK provides an enterprise-grade, process-isolated API for OOXML-to-PDF conversion. Each conversion runs in a separate native worker process — a crash on a malformed document never affects the host .NET process.

### Quick start

```csharp
using SlimLO;

await using var converter = PdfConverter.Create();

// File to file
var result = await converter.ConvertAsync("input.docx", "output.pdf");
result.ThrowIfFailed();

// Check for font warnings
if (result.HasFontWarnings)
    foreach (var d in result.Diagnostics)
        Console.WriteLine($"  {d.Severity}: {d.Message}");
```

### Full API examples

```csharp
using SlimLO;

// --- Create with options ---
await using var converter = PdfConverter.Create(new PdfConverterOptions
{
    ResourcePath = "/opt/slimlo",             // auto-detected if not set
    FontDirectories = ["/app/fonts"],         // extra font directories (cross-platform)
    MaxWorkers = 2,                           // parallel worker processes
    MaxConversionsPerWorker = 100,            // recycle after N conversions
    ConversionTimeout = TimeSpan.FromMinutes(5),
    WarmUp = true                             // pre-start workers
});

// --- File conversion ---
var result = await converter.ConvertAsync("input.docx", "output.pdf");
if (!result)  // implicit bool conversion
    Console.Error.WriteLine($"Failed: {result.ErrorMessage} ({result.ErrorCode})");

// --- Buffer conversion ---
byte[] docxBytes = await File.ReadAllBytesAsync("input.docx");
var bufResult = await converter.ConvertAsync(
    docxBytes.AsMemory(), DocumentFormat.Docx);
bufResult.ThrowIfFailed();
await File.WriteAllBytesAsync("output.pdf", bufResult.Data!);

// --- With PDF options ---
var result2 = await converter.ConvertAsync("input.docx", "output.pdf",
    new ConversionOptions
    {
        PdfVersion = PdfVersion.PdfA2,
        JpegQuality = 85,
        Dpi = 150,
        TaggedPdf = true,
        PageRange = "1-5"
    });
```

### Architecture

```
.NET Application
┌─────────────────────────────────────────────────────────────────┐
│  PdfConverter                                                   │
│  ├─ ConvertAsync(path, path) ─── file-path JSON IPC ─────────> │
│  ├─ ConvertAsync(bytes/stream) ─ binary buffer IPC ──────────> │
│  │                                                              │
│  └─ WorkerPool (thread-safe, round-robin dispatch)              │
│      ├─ WorkerProcess[0] ──stdin/stdout──> slimlo_worker        │
│      ├─ WorkerProcess[1] ──stdin/stdout──> slimlo_worker        │
│      └─ ...                                                     │
└─────────────────────────────────────────────────────────────────┘
```

- **Process isolation**: Each `slimlo_worker` is a native C executable. LOKit runs in a separate OS process — a SIGSEGV on a corrupt document kills only the worker, not your app.
- **Two IPC modes**: File-path mode (JSON with paths) and buffer mode (binary frames with raw document/PDF bytes). See [Conversion modes](#conversion-modes) below.
- **Thread safety**: With `MaxWorkers > 1`, conversions run in true parallel across separate OS processes, each with its own LOKit instance.
- **Crash recovery**: Broken pipe detected → failure result returned → worker auto-replaced on next call.
- **Font diagnostics**: Worker captures LOKit stderr during each conversion. Font substitution warnings are parsed into `ConversionDiagnostic` objects.

### Conversion modes

`PdfConverter` uses two distinct IPC modes depending on the overload you call:

**File-path mode** — The `(string inputPath, string outputPath)` overload sends only file paths to the worker process. The worker reads the input file, calls LOKit with a `file://` URL, and LOKit writes the PDF to disk directly. The .NET process never loads the document or PDF bytes into memory.

**Buffer mode** — All other overloads (bytes, streams, mixed) send the document as binary frames over the IPC pipe. The worker loads it via LOKit's `private:stream` (in-memory, zero disk I/O) and sends the PDF bytes back the same way.

| Overload | IPC mode | Memory behavior |
|----------|----------|-----------------|
| `ConvertAsync(string, string, ...)` | File-path | Worker handles all I/O. Minimal .NET memory. Format auto-detected from extension. |
| `ConvertAsync(ReadOnlyMemory<byte>, format, ...)` | Buffer | Input + PDF bytes in .NET memory. Zero disk I/O. |
| `ConvertAsync(Stream, Stream, format, ...)` | Buffer | Input stream read into memory, PDF written to output stream. |
| `ConvertAsync(Stream, string, format, ...)` | Buffer | Input stream read into memory, PDF written to file from returned bytes. |
| `ConvertAsync(string, Stream, ...)` | Buffer | File read into .NET memory, PDF written to output stream. |

**When to use which:**

- **Batch processing, CLI tools, large files** — Use `ConvertAsync(inputPath, outputPath)`. Most memory-efficient: a 100 MB PPTX producing a 200 MB PDF only uses ~100 MB in the worker (LOKit's internal buffers), not in your .NET process.
- **ASP.NET / web servers** — Use `ConvertAsync(stream, stream, format)` to pipe directly from the request body to the response. No temp files needed.
- **In-memory pipelines** — Use `ConvertAsync(ReadOnlyMemory<byte>, format)` when you already have document bytes (e.g., from a database, message queue, or blob storage).

### API reference

**`PdfConverter`** — Main entry point. `IAsyncDisposable` + `IDisposable`.

| Method | Description |
|--------|-------------|
| `Create(options?)` | Create a new converter instance. Workers start lazily (or eagerly with `WarmUp = true`). |
| `ConvertAsync(inputPath, outputPath, options?, ct)` | File→PDF via file-path IPC. Returns `ConversionResult`. |
| `ConvertAsync(input, format, options?, ct)` | Bytes→PDF via buffer IPC. Returns `ConversionResult<byte[]>`. |
| `ConvertAsync(input, output, format, options?, ct)` | Stream→Stream via buffer IPC. Returns `ConversionResult`. |
| `ConvertAsync(input, outputPath, format, options?, ct)` | Stream→File via buffer IPC. Returns `ConversionResult`. |
| `ConvertAsync(inputPath, output, options?, ct)` | File→Stream via buffer IPC. Returns `ConversionResult`. |
| `Version` | Static property — SlimLO native library version string. |

**`ConversionResult`** — Conversion outcome with diagnostics.

| Member | Description |
|--------|-------------|
| `Success` | `true` if conversion succeeded. |
| `ErrorMessage` | Error description (null on success). |
| `ErrorCode` | `SlimLOErrorCode` enum value (null on success). |
| `Diagnostics` | `IReadOnlyList<ConversionDiagnostic>` — font warnings, layout issues. May be non-empty on success. |
| `HasFontWarnings` | `true` if any diagnostic has `Category == Font`. |
| `ThrowIfFailed()` | Throws `SlimLOException` on failure, returns `this` on success. |
| `implicit operator bool` | Enables `if (result)` pattern. |

**`ConversionResult<T>`** — Also carries `Data` (e.g., `byte[]` for buffer conversions).

**`ConversionOptions`** (record) — Per-conversion settings.

| Property | Default | Description |
|----------|---------|-------------|
| `PdfVersion` | `Default` (1.7) | `PdfA1`, `PdfA2`, `PdfA3` for archival. |
| `JpegQuality` | 0 (= 90) | JPEG compression quality 1–100. |
| `Dpi` | 0 (= 300) | Maximum image resolution. |
| `TaggedPdf` | `false` | Generate tagged PDF for accessibility. |
| `PageRange` | `null` (all) | Page range string, e.g., `"1-5"` or `"1,3,5-7"`. |
| `Password` | `null` | Password for protected documents. |

**`PdfConverterOptions`** — Converter-level configuration.

| Property | Default | Description |
|----------|---------|-------------|
| `ResourcePath` | auto-detect | Path to SlimLO resources (containing `program/`). |
| `FontDirectories` | `null` | Extra font directories. On Linux, set via `SAL_FONTPATH` (fontconfig). On macOS, registered via CoreText at process level (no admin required). |
| `MaxWorkers` | 1 | Number of parallel worker processes. |
| `MaxConversionsPerWorker` | 0 (no limit) | Recycle worker after N conversions. |
| `ConversionTimeout` | 5 min | Per-conversion timeout. Worker killed on timeout. |
| `WarmUp` | `false` | Pre-start all workers during `Create()`. |

**`ConversionDiagnostic`** — A single diagnostic entry.

| Property | Description |
|----------|-------------|
| `Severity` | `Info` or `Warning` |
| `Category` | `General`, `Font`, or `Layout` |
| `Message` | Human-readable message |
| `FontName` | Font name (if font-related) |
| `SubstitutedWith` | Substitute font name (if substitution occurred) |

### Environment variables

| Variable | Description |
|----------|-------------|
| `SLIMLO_RESOURCE_PATH` | SlimLO resource directory (fallback for auto-detection). |
| `SLIMLO_WORKER_PATH` | Path to `slimlo_worker` executable (fallback for auto-detection). |

### Running .NET tests

```bash
cd dotnet

# Unit tests only (no native dependencies needed)
dotnet test

# Full integration tests (requires native artifacts)
SLIMLO_RESOURCE_PATH=../output-macos \
SLIMLO_WORKER_PATH=../slimlo-api/build/slimlo_worker \
dotnet test

# With code coverage
SLIMLO_RESOURCE_PATH=../output-macos \
SLIMLO_WORKER_PATH=../slimlo-api/build/slimlo_worker \
dotnet test --collect:"XPlat Code Coverage"
```

**Test suite:** 109 tests (unit + integration), covering:
- All public types (`ConversionResult`, `ConversionDiagnostic`, `ConversionOptions`, enums, exceptions)
- IPC protocol (message framing, serialization, edge cases)
- Diagnostic parsing (all severity/category combinations, malformed input)
- End-to-end conversion with 7 DOCX fixtures (multi-font, Unicode, rich formatting, large documents, missing fonts, barcode font with/without custom `FontDirectories`)
- Custom font loading via `FontDirectories` (cross-platform: SAL_FONTPATH on Linux, CoreText on macOS)
- Concurrent conversions, dispose behavior, error handling

### Deploying to Linux

The `SlimLO.NativeAssets.Linux` NuGet package bundles the LibreOffice engine and SlimLO worker, but the host must have system libraries installed (see [Linux system dependencies](#linux-system-dependencies)).

**Docker (recommended):**

```dockerfile
FROM mcr.microsoft.com/dotnet/sdk:8.0-noble AS build
WORKDIR /src
COPY . .
RUN dotnet publish MyApp.csproj -c Release -r linux-x64 --no-self-contained -o /app

FROM mcr.microsoft.com/dotnet/runtime:8.0-noble
RUN apt-get update && apt-get install -y --no-install-recommends \
    libfontconfig1 libfreetype6 libexpat1 libcairo2 libpng16-16 \
    libjpeg-turbo8 libxml2 libxslt1.1 libicu74 libnss3 libnspr4 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app .
ENTRYPOINT ["dotnet", "MyApp.dll"]
```

> Use the `-noble` (Ubuntu 24.04) variant of the .NET images. The default Debian-based images use different package names.

**Bare-metal / VM:** Install the system libraries listed in [Linux system dependencies](#linux-system-dependencies), then run your published .NET app normally.

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
| `build-linux-x64.yml` | `ubuntu-latest` | `SlimLO.conf` | Docker Buildx, GHA cache, 12h timeout |
| `build-linux-arm64.yml` | `ubuntu-24.04-arm` | `SlimLO.conf` | Docker Buildx, NPROC=4, GHA cache, 12h timeout |
| `build-macos.yml` | `macos-14` (M1) | `SlimLO-macOS.conf` | Homebrew deps, ccache, 12h timeout |
| `build-macos-x64.yml` | `macos-15-intel` | `SlimLO-macOS.conf` | Homebrew deps, ccache, 12h timeout |
| `build-windows.yml` | `windows-2022` | `SlimLO.conf` | MSYS2 + MSVC, NPROC=4, 12h timeout |

All workflows cache build outputs (ccache or Docker layer cache) and upload artifacts. Triggered on `pull_request` to `main` and `workflow_dispatch` only (not on push).

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
| 011 | Makes `SfxApplication::GetOrCreate()` and `#include <sfx2/app.hxx>` unconditional in LOKit init. Required on macOS where LOKit needs SfxApplication after `InitVCL()`. |

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

### Custom font loading

`PdfConverterOptions.FontDirectories` provides cross-platform custom font support:

| Platform | Mechanism | Details |
|----------|-----------|---------|
| Linux | `SAL_FONTPATH` | Fontconfig discovers fonts in the specified directories. |
| macOS | `SAL_FONTPATH` + CoreText | `SAL_FONTPATH` is set but ignored by the macOS Quartz VCL backend. The worker calls `CTFontManagerRegisterFontsForURL` for each `.ttf`/`.otf`/`.ttc` file, registering fonts at process scope. No admin privileges required. |
| Windows | `SAL_FONTPATH` | LibreOffice discovers fonts in the specified directories. |

Implemented in `slimlo_worker.c` (`register_fonts_coretext()` on macOS), linked via `-framework CoreText -framework CoreFoundation` in `CMakeLists.txt`.

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

| Metric | Linux x64 | Linux arm64 | macOS arm64 | macOS x64 |
|--------|-----------|-------------|-------------|-----------|
| Artifact size | **186 MB** | **186 MB** | **108 MB** | **108 MB** |
| Merged lib | 98 MB `.so` | 98 MB `.so` | 91 MB `.dylib` | 91 MB `.dylib` |
| Libraries | 137 | 137 | 140 | 140 |
| Constructor symbols | 557 | 557 | 560 | 560 |
| Zip size | 70 MB | 70 MB | 40 MB | 40 MB |

| | |
|---|---|
| LO version | `libreoffice-25.8.5.1` |
| Test result | `test.docx` (1,754 B) → valid PDF (26 KB) |
| .NET SDK | 109 tests passing (unit + integration) |
| .NET coverage | 80.5% line (100% on public API types) |

## Roadmap

### Further size reduction (186 MB → ~155 MB)

- [x] ICU data filter: custom ICU build with only required locales (patch 010)
- [ ] Measure actual savings from ICU filtering

### Multi-platform

- [x] True linux-x64 build (`build-linux-x64.yml` on ubuntu-latest)
- [x] linux-arm64 dedicated build (`build-linux-arm64.yml` on ubuntu-24.04-arm)
- [x] macOS arm64 native build (distro config, patch portability, `build.sh` support)
- [x] macOS x64 build (`build-macos-x64.yml` on macos-15-intel)
- [x] Windows build support (`build.sh` + `extract-artifacts.sh` MSYS2/MSVC support)

### CI/CD

- [x] GitHub Actions: Linux x64 Docker build (`build-linux-x64.yml`)
- [x] GitHub Actions: Linux arm64 Docker build (`build-linux-arm64.yml`)
- [x] GitHub Actions: macOS arm64 build (`build-macos.yml`)
- [x] GitHub Actions: macOS x64 build (`build-macos-x64.yml`)
- [x] GitHub Actions: Windows x64 build (`build-windows.yml`)
- [ ] Multi-arch Docker image publishing
- [ ] NuGet package publishing to nuget.org

### .NET SDK

- [x] Process-isolated worker architecture (crash resilience)
- [x] Thread-safe concurrent conversions via WorkerPool
- [x] Font diagnostics (ConversionDiagnostic with severity/category)
- [x] Async API with ConversionResult pattern (no exceptions for conversion failures)
- [x] Buffer and file conversion overloads
- [x] PDF/A, tagged PDF, page range, password options
- [x] Cross-platform custom font loading (SAL_FONTPATH + CoreText on macOS)
- [x] 109 unit + integration tests
- [x] NuGet packaging: `SlimLO` (managed) + `SlimLO.NativeAssets.Linux` + `SlimLO.NativeAssets.macOS`
- [ ] NuGet packaging: `SlimLO.NativeAssets.Win32`
- [ ] NuGet package publishing to nuget.org

### Quality

- [ ] Custom seccomp profile (allow only `clone3`, instead of `seccomp=unconfined`)
- [x] End-to-end .NET tests with complex DOCX fixtures
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
│   ├── build-linux-x64.yml             # GitHub Actions: Linux x64 Docker build
│   ├── build-linux-arm64.yml           # GitHub Actions: Linux arm64 Docker build
│   ├── build-macos.yml                 # GitHub Actions: macOS arm64 build
│   ├── build-macos-x64.yml            # GitHub Actions: macOS x64 build
│   └── build-windows.yml               # GitHub Actions: Windows x64 build
├── patches/                            # 11 idempotent .sh scripts (not .patch files)
│   ├── 001..008-*.sh                   # Pre-autogen patches
│   ├── 009-*.postautogen               # Post-autogen patch (LTO flags)
│   ├── 010-icu-data-filter.sh          # ICU locale filtering
│   └── 011-sfxapplication-getorcreate.sh  # macOS LOKit init fix
├── scripts/
│   ├── build.sh                        # Cross-platform build pipeline
│   ├── apply-patches.sh                # Runs all patches in order
│   ├── extract-artifacts.sh            # Cross-platform artifact extraction
│   ├── docker-build.sh                 # Docker build orchestrator
│   ├── pack-nuget.sh                   # NuGet packaging
│   ├── bump-lo-version.sh              # Update pinned LO version
│   └── test-patches.sh                 # Patch validation
├── slimlo-api/                         # C API + worker process
│   ├── CMakeLists.txt                  # Cross-platform CMake (so/dylib/dll + worker)
│   ├── include/slimlo.h                # Public C header
│   └── src/
│       ├── slimlo.cxx                  # LOKit-based C API implementation
│       ├── slimlo_worker.c             # IPC worker process (stdin/stdout JSON)
│       ├── lokit_macos_shim.h          # macOS LOKit #error bypass
│       └── cjson/                      # Vendored cJSON (MIT license)
├── dotnet/
│   ├── SlimLO/                         # .NET 8 SDK (enterprise-grade)
│   │   ├── PdfConverter.cs             # Public API (IAsyncDisposable)
│   │   ├── PdfConverterOptions.cs      # Converter-level configuration
│   │   ├── ConversionOptions.cs        # Per-conversion settings (record)
│   │   ├── ConversionResult.cs         # Result with diagnostics
│   │   ├── ConversionDiagnostic.cs     # Font/layout diagnostic entry
│   │   ├── Enums.cs                    # DocumentFormat, PdfVersion, SlimLOErrorCode, etc.
│   │   ├── SlimLOException.cs          # Typed exception with error code
│   │   └── Internal/                   # Process-isolated worker management
│   │       ├── WorkerPool.cs           # Thread-safe pool with round-robin dispatch
│   │       ├── WorkerProcess.cs        # Single worker lifecycle + IPC
│   │       ├── Protocol.cs             # Length-prefixed JSON framing
│   │       ├── StderrDiagnosticParser.cs  # Parse font/layout warnings
│   │       └── WorkerLocator.cs        # Auto-detect worker + resource paths
│   ├── SlimLO.NativeAssets.Linux/       # Native NuGet package (linux-x64 + linux-arm64)
│   ├── SlimLO.NativeAssets.macOS/       # Native NuGet package (osx-arm64 + osx-x64)
│   └── SlimLO.Tests/                   # 109 xUnit tests (unit + integration)
└── tests/
    ├── test.sh                         # Cross-platform integration test (native + Docker)
    ├── test_convert.c                  # C test program
    ├── test.docx                       # Test fixture (1,754 bytes)
    ├── generate_complex_docx.py        # Generate complex DOCX fixtures
    ├── fixtures/                       # Complex DOCX fixtures (multi-font, unicode, etc.)
    │   ├── barcode_font.docx           # Barcode font test (Libre Barcode 128)
    │   └── fonts/
    │       └── LibreBarcode128-Regular.ttf  # Custom font for testing FontDirectories
    └── ...
```

## Runtime requirements

### Build requirements

- **Docker Desktop memory**: 16 GB+ recommended. Large LO source files (`docxattributeoutput.cxx`, `DocumentContentOperationsManager.cxx`) need ~3 GB per compiler process.

### Runtime requirements

- **Runtime memory**: ~200 MB per worker process.
- **Docker seccomp** (Linux): `--security-opt seccomp=unconfined` required. LibreOffice uses `clone3()` for thread creation, blocked by Docker's default seccomp profile.
- **macOS**: No additional runtime dependencies needed (system frameworks suffice).

### Linux system dependencies

The SlimLO NuGet package bundles the LibreOffice engine and C API, but **not** the system-level shared libraries it links against. These must be installed on the host system.

**Ubuntu / Debian:**

```bash
apt-get install -y --no-install-recommends \
    libfontconfig1 libfreetype6 libexpat1 libcairo2 libpng16-16 \
    libjpeg-turbo8 libxml2 libxslt1.1 libicu74 libnss3 libnspr4
```

> On Ubuntu 22.04 (Jammy), use `libicu70` instead of `libicu74`.

**Fedora / RHEL / Amazon Linux:**

```bash
dnf install -y \
    fontconfig freetype expat cairo libpng libjpeg-turbo \
    libxml2 libxslt libicu nss nspr
```

**Alpine:**

```bash
apk add --no-cache \
    fontconfig freetype expat cairo libpng libjpeg-turbo \
    libxml2 libxslt icu-libs nss nspr
```

**Optional — fonts:** Install `fonts-liberation` (or your preferred font package) for accurate text rendering. Alternatively, use `PdfConverterOptions.FontDirectories` to load custom fonts at runtime.

**Troubleshooting:** If the worker process crashes at startup with `error while loading shared libraries: libfoo.so`, install the missing library with your package manager. The .NET SDK will include the library name in the exception message.

## License

MPL-2.0 (matching LibreOffice). Built with `--enable-mpl-subset` to exclude GPL/LGPL components.
