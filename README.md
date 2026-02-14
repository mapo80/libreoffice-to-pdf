# SlimLO

**Minimal LibreOffice build for OOXML-to-PDF conversion, with .NET and C APIs.**

[![Build Linux x64](https://github.com/mapo80/libreoffice-to-pdf/actions/workflows/build-linux-x64.yml/badge.svg)](https://github.com/mapo80/libreoffice-to-pdf/actions/workflows/build-linux-x64.yml)
[![Build Linux arm64](https://github.com/mapo80/libreoffice-to-pdf/actions/workflows/build-linux-arm64.yml/badge.svg)](https://github.com/mapo80/libreoffice-to-pdf/actions/workflows/build-linux-arm64.yml)
[![Build macOS arm64](https://github.com/mapo80/libreoffice-to-pdf/actions/workflows/build-macos.yml/badge.svg)](https://github.com/mapo80/libreoffice-to-pdf/actions/workflows/build-macos.yml)
[![Build macOS x64](https://github.com/mapo80/libreoffice-to-pdf/actions/workflows/build-macos-x64.yml/badge.svg)](https://github.com/mapo80/libreoffice-to-pdf/actions/workflows/build-macos-x64.yml)
[![Build Windows x64](https://github.com/mapo80/libreoffice-to-pdf/actions/workflows/build-windows.yml/badge.svg)](https://github.com/mapo80/libreoffice-to-pdf/actions/workflows/build-windows.yml)

SlimLO is **not a fork**. It applies idempotent patch scripts to vanilla LibreOffice source, making it trivial to track upstream releases. The result is a single merged library (LTO-optimized) plus a thin C wrapper — a fully self-contained artifact ready for server-side document conversion.

| | |
|---|---|
| **Platforms** | Linux x64/arm64 · macOS arm64/x64 · Windows x64 |
| **Artifact size** | 186 MB (Linux) · 108 MB (macOS) |
| **Merged lib** | ~98 MB `.so` · ~91 MB `.dylib` (LTO + stripped) |
| **LO version** | `libreoffice-25.8.5.1` |
| **.NET tests** | 109 passing (unit + integration) |

---

## Architecture

SlimLO strips LibreOffice down to its Writer engine + UNO + filters, merges everything into a single shared library via `--enable-mergelibs` + LTO, and exposes it through two APIs:

```
                        ┌─────────────────────┐
                        │   Your Application   │
                        └──────────┬──────────┘
                                   │
               ┌───────────────────┴───────────────────┐
               │                                       │
       .NET SDK (async)                          C API (direct)
               │                                       │
      ┌────────┴────────┐                    #include "slimlo.h"
      │   PdfConverter   │                             │
      │                  │                             │
      │   WorkerPool     │                             │
      │   ├─ worker[0] ──┼── stdin/stdout ──┐          │
      │   ├─ worker[1] ──┼── stdin/stdout ──┤          │
      │   └─ worker[N] ──┼── stdin/stdout ──┤          │
      └─────────────────┘                   │          │
                                            ▼          ▼
                               ┌────────────────────────────┐
                               │  libslimlo.{so,dylib,dll}  │
                               │      (C API wrapper)       │
                               └─────────────┬──────────────┘
                                             │
                                     LibreOfficeKit
                                             │
                               ┌─────────────┴──────────────┐
                               │ libmergedlo.{so,dylib,dll}  │
                               │   ~98 MB · LTO · stripped   │
                               │   Writer + UNO + filters    │
                               └─────────────────────────────┘
```

**Key design decisions:**

- **Patch-based, not a fork** — 11 idempotent shell scripts patch vanilla LO source. No `git .patch` files — scripts are resilient to upstream line-number changes and trivial to update when a new LO version drops.
- **Single merged library** — `--enable-mergelibs` + LTO combines hundreds of LO modules into one `libmergedlo`. Dead code elimination + aggressive stripping reduces 1.5 GB to 186 MB.
- **Process isolation** (.NET) — Each conversion runs in a separate native `slimlo_worker` process. LibreOffice crash on a malformed document kills only the worker, never the host application.

---

## .NET SDK

The .NET SDK is the primary way to use SlimLO. It provides a thread-safe, async API with process isolation, crash recovery, and font diagnostics.

### Installation

```xml
<PackageReference Include="SlimLO" Version="0.1.0" />
<PackageReference Include="SlimLO.NativeAssets.Linux" Version="0.1.0"
    Condition="$([MSBuild]::IsOSPlatform('Linux'))" />
<PackageReference Include="SlimLO.NativeAssets.macOS" Version="0.1.0"
    Condition="$([MSBuild]::IsOSPlatform('OSX'))" />
```

> On Linux, the host must have system libraries installed. See [Linux system dependencies](#linux-system-dependencies).

### Quick start

```csharp
using SlimLO;

await using var converter = PdfConverter.Create();

var result = await converter.ConvertAsync("input.docx", "output.pdf");
result.ThrowIfFailed();

Console.WriteLine($"PDF size: {new FileInfo("output.pdf").Length:N0} bytes");
```

### Full API examples

```csharp
using SlimLO;

// ── Create with options ──────────────────────────────────────────
await using var converter = PdfConverter.Create(new PdfConverterOptions
{
    ResourcePath = "/opt/slimlo",             // auto-detected if not set
    FontDirectories = ["/app/fonts"],         // custom fonts (cross-platform)
    MaxWorkers = 2,                           // parallel worker processes
    MaxConversionsPerWorker = 100,            // recycle after N conversions
    ConversionTimeout = TimeSpan.FromMinutes(5),
    WarmUp = true                             // pre-start workers
});

// ── File to file ─────────────────────────────────────────────────
var result = await converter.ConvertAsync("input.docx", "output.pdf");
if (!result)  // implicit bool conversion
    Console.Error.WriteLine($"Failed: {result.ErrorMessage} ({result.ErrorCode})");

// ── Buffer conversion ────────────────────────────────────────────
byte[] docxBytes = await File.ReadAllBytesAsync("input.docx");
var bufResult = await converter.ConvertAsync(docxBytes.AsMemory(), DocumentFormat.Docx);
bufResult.ThrowIfFailed();
await File.WriteAllBytesAsync("output.pdf", bufResult.Data!);

// ── Stream to stream (ASP.NET) ───────────────────────────────────
var streamResult = await converter.ConvertAsync(
    Request.Body, Response.Body, DocumentFormat.Docx);

// ── PDF options ──────────────────────────────────────────────────
var result2 = await converter.ConvertAsync("input.docx", "output.pdf",
    new ConversionOptions
    {
        PdfVersion = PdfVersion.PdfA2,
        JpegQuality = 85,
        Dpi = 150,
        TaggedPdf = true,
        PageRange = "1-5"
    });

// ── Font warnings ────────────────────────────────────────────────
if (result.HasFontWarnings)
    foreach (var d in result.Diagnostics)
        Console.WriteLine($"  {d.Severity}: {d.Message}");
```

### How it works

```
┌─ .NET Process ──────────────────────────────────────────────────┐
│                                                                  │
│  PdfConverter.ConvertAsync(...)                                  │
│       │                                                          │
│       ▼                                                          │
│  WorkerPool  (thread-safe, round-robin dispatch)                 │
│       │                                                          │
│       ├── WorkerProcess[0] ──┐                                   │
│       ├── WorkerProcess[1] ──┤── stdin/stdout pipes              │
│       └── WorkerProcess[N] ──┘                                   │
│                                                                  │
└──────────────────────────────┼───────────────────────────────────┘
                               │
                   ┌───────────┴───────────┐
                   │     slimlo_worker      │  ← separate OS process
                   │                        │
                   │  JSON IPC (file-path)  │  ← paths only, no data copied
                   │  Binary IPC (buffer)   │  ← raw bytes over pipe
                   │                        │
                   │  libslimlo → LOKit     │
                   │  → libmergedlo         │
                   └────────────────────────┘
```

- **Process isolation**: A crash in LibreOffice (corrupt document, SIGSEGV) kills only the worker. The .NET process gets a failure result and the worker is auto-replaced.
- **Two IPC modes**: File-path mode sends only paths (zero-copy); buffer mode sends raw bytes over pipes (zero disk I/O).
- **Thread safety**: With `MaxWorkers > 1`, conversions run in true parallel across separate OS processes.
- **Font diagnostics**: The worker captures LOKit stderr and parses font substitution warnings into `ConversionDiagnostic` objects.

### Conversion modes

| Overload | IPC mode | Memory behavior |
|----------|----------|-----------------|
| `ConvertAsync(string, string, ...)` | File-path | Worker handles all I/O. Minimal .NET memory. Format auto-detected from extension. |
| `ConvertAsync(ReadOnlyMemory<byte>, format, ...)` | Buffer | Input + PDF bytes in .NET memory. Zero disk I/O. |
| `ConvertAsync(Stream, Stream, format, ...)` | Buffer | Streams piped through memory. No temp files. |
| `ConvertAsync(Stream, string, format, ...)` | Buffer | Stream read into memory, PDF written to file. |
| `ConvertAsync(string, Stream, ...)` | Buffer | File read into memory, PDF written to stream. |

**When to use which:**

- **Batch processing / large files** — `ConvertAsync(inputPath, outputPath)`. Most memory-efficient: the .NET process never touches document bytes.
- **ASP.NET / web servers** — `ConvertAsync(stream, stream, format)` to pipe request body to response. No temp files.
- **In-memory pipelines** — `ConvertAsync(ReadOnlyMemory<byte>, format)` when you already have bytes from a database, queue, or blob storage.

### API reference

**`PdfConverter`** — Main entry point. `IAsyncDisposable` + `IDisposable`.

| Method | Description |
|--------|-------------|
| `Create(options?)` | Create converter. Workers start lazily (or eagerly with `WarmUp = true`). |
| `ConvertAsync(in, out, opts?, ct)` | File-to-file via file-path IPC. Returns `ConversionResult`. |
| `ConvertAsync(bytes, fmt, opts?, ct)` | Bytes-to-PDF via buffer IPC. Returns `ConversionResult<byte[]>`. |
| `ConvertAsync(stream, stream, fmt, opts?, ct)` | Stream-to-stream via buffer IPC. Returns `ConversionResult`. |
| `ConvertAsync(stream, outPath, fmt, opts?, ct)` | Stream-to-file via buffer IPC. Returns `ConversionResult`. |
| `ConvertAsync(inPath, stream, opts?, ct)` | File-to-stream via buffer IPC. Returns `ConversionResult`. |
| `Version` | Static — native library version string. |

**`PdfConverterOptions`** — Converter-level configuration.

| Property | Default | Description |
|----------|---------|-------------|
| `ResourcePath` | auto-detect | Path to SlimLO resources (containing `program/`). |
| `FontDirectories` | `null` | Custom font directories. Linux: fontconfig. macOS: CoreText registration. |
| `MaxWorkers` | 1 | Parallel worker processes. |
| `MaxConversionsPerWorker` | 0 (unlimited) | Recycle worker after N conversions. |
| `ConversionTimeout` | 5 min | Per-conversion timeout. Worker killed on timeout. |
| `WarmUp` | `false` | Pre-start all workers during `Create()`. |

**`ConversionOptions`** — Per-conversion settings (record).

| Property | Default | Description |
|----------|---------|-------------|
| `PdfVersion` | `Default` (1.7) | `PdfA1`, `PdfA2`, `PdfA3` for archival. |
| `JpegQuality` | 0 (= 90) | JPEG compression quality 1–100. |
| `Dpi` | 0 (= 300) | Maximum image resolution. |
| `TaggedPdf` | `false` | Tagged PDF for accessibility. |
| `PageRange` | `null` (all) | e.g., `"1-5"` or `"1,3,5-7"`. |
| `Password` | `null` | Password for protected documents. |

**`ConversionResult`** — Conversion outcome with diagnostics.

| Member | Description |
|--------|-------------|
| `Success` | `true` if conversion succeeded. |
| `ErrorMessage` | Error description (null on success). |
| `ErrorCode` | `SlimLOErrorCode` enum (null on success). |
| `Diagnostics` | `IReadOnlyList<ConversionDiagnostic>` — may be non-empty even on success. |
| `HasFontWarnings` | `true` if any diagnostic has `Category == Font`. |
| `ThrowIfFailed()` | Throws `SlimLOException` on failure, returns `this` on success. |
| `implicit operator bool` | Enables `if (result)` pattern. |

**`ConversionResult<T>`** — Also carries `Data` (e.g., `byte[]` for buffer conversions).

**`ConversionDiagnostic`** — A single diagnostic entry.

| Property | Description |
|----------|-------------|
| `Severity` | `Info` or `Warning` |
| `Category` | `General`, `Font`, or `Layout` |
| `Message` | Human-readable message |
| `FontName` | Font name (if font-related) |
| `SubstitutedWith` | Substitute font (if substitution occurred) |

### Deploying to Linux

The `SlimLO.NativeAssets.Linux` NuGet package bundles the LibreOffice engine and worker, but the host must have system libraries installed (see [Linux system dependencies](#linux-system-dependencies)).

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

> Use the `-noble` (Ubuntu 24.04) variant. Default Debian images use different package names.

**Bare-metal / VM:** Install the [system dependencies](#linux-system-dependencies), then run your published .NET app normally.

### Deploying to macOS

No additional system dependencies needed — macOS system frameworks suffice. The native assets NuGet package includes everything required.

### Environment variables

| Variable | Description |
|----------|-------------|
| `SLIMLO_RESOURCE_PATH` | Override auto-detected resource directory. |
| `SLIMLO_WORKER_PATH` | Override auto-detected `slimlo_worker` path. |

### Running tests

```bash
cd dotnet

# Unit tests only (no native dependencies)
dotnet test

# Integration tests (requires native artifacts)
SLIMLO_RESOURCE_PATH=../output \
SLIMLO_WORKER_PATH=../slimlo-api/build/slimlo_worker \
dotnet test
```

**Test suite:** 109 tests covering all public types, IPC protocol, diagnostic parsing, end-to-end conversion with 7 DOCX fixtures (multi-font, Unicode, rich formatting, large documents, missing fonts, custom font loading), concurrent conversions, dispose behavior, and error handling.

---

## C API

For direct native integration without process isolation overhead.

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

| Function | Description |
|----------|-------------|
| `slimlo_init(resource_path)` | Initialize (once per process). Returns opaque handle. |
| `slimlo_destroy(handle)` | Free all resources. |
| `slimlo_convert_file(h, in, out, fmt, opts)` | Convert file to PDF. |
| `slimlo_convert_buffer(h, data, size, fmt, opts, &out, &outsize)` | Convert in-memory buffer. |
| `slimlo_free_buffer(buf)` | Free buffer from `convert_buffer`. |
| `slimlo_get_error_message(h)` | Last error message. |

**PDF options (`SlimLOPdfOptions`):** version (1.7 / PDF/A-1,2,3), JPEG quality, DPI, tagged PDF, page range, password.

**Thread safety:** Conversions serialized via internal mutex. For concurrency, use multiple processes (or the .NET SDK).

---

## Building from source

### Docker build (Linux)

**Prerequisites:** Docker with BuildKit, 16 GB+ RAM allocated.

```bash
DOCKER_BUILDKIT=1 docker build \
  -f docker/Dockerfile.linux-x64 \
  --build-arg SCRIPTS_HASH=$(cat scripts/*.sh patches/*.sh patches/*.postautogen | sha256sum | cut -d' ' -f1) \
  -t slimlo-build .

# Extract artifacts
docker run --rm -v $(pwd)/output:/output slimlo-build
```

### Native build (all platforms)

```bash
./scripts/build.sh
```

| Variable | Default | Description |
|----------|---------|-------------|
| `LO_SRC_DIR` | `./lo-src` | LO source directory (~2.5 GB) |
| `OUTPUT_DIR` | `./output` | Artifact output directory |
| `NPROC` | auto-detected | Build parallelism (`-jN`) |

**Linux prerequisites:**

```bash
# Ubuntu 24.04
sudo apt build-dep libreoffice
```

**macOS prerequisites:**

```bash
brew install autoconf automake libtool pkg-config ccache \
             nasm flex bison gperf zip unzip make
```

> macOS notes: GNU Make >= 4.0 required (macOS ships 3.81). `--disable-gui` is not supported on macOS (uses Quartz VCL). `build.sh` handles all platform differences automatically — always use it instead of running `make` directly.

**Windows prerequisites:** MSYS2 (bash/make/autoconf) + MSVC (cl.exe) + `choco install nasm`. See `build-windows.yml` for the full CI setup.

### Output layout

```
output/
├── program/           # ~178 MB — all shared libraries
│   ├── libmergedlo.{so,dylib,dll}  # ~98 MB core engine (LTO)
│   ├── libslimlo.{so,dylib,dll}    # C API wrapper
│   ├── slimlo_worker               # IPC worker process
│   ├── lib*.{so,dylib}             # UNO, ICU, externals, stubs
│   ├── sofficerc                   # Bootstrap RC chain
│   └── types/offapi.rdb            # UNO type registry
├── share/             # ~7.6 MB — runtime config
│   ├── registry/*.xcd
│   ├── config/soffice.cfg/
│   └── filter/
├── presets/            # Empty (required by LOKit)
└── include/
    └── slimlo.h
```

### Testing the build

```bash
# Native test (auto-detects platform)
./tests/test.sh

# Docker mode (Linux only)
SLIMLO_TEST_MODE=docker ./tests/test.sh

# Custom artifact directory
SLIMLO_DIR=/path/to/artifacts ./tests/test.sh
```

---

## How patching works

SlimLO uses **shell scripts** instead of `git .patch` files. Each script is idempotent (safe to re-run) and resilient to upstream line-number changes.

The `ENABLE_SLIMLO` flag flows through the build system:

```
configure.ac          →  --enable-slimlo
config_host.mk.in     →  ENABLE_SLIMLO=TRUE
makefiles             →  $(if $(ENABLE_SLIMLO),,target)   # exclude targets
```

| Patch | What it does |
|-------|-------------|
| 001 | Adds `--enable-slimlo` flag to `configure.ac` and `config_host.mk.in` |
| 002 | Conditionally excludes 41 non-essential modules (dbaccess, wizards, extras, ...) |
| 003 | Copies distro config into LO source tree |
| 004 | Strips 11 non-Writer export filter targets (SVG, DocBook, XHTML, T602, ...) |
| 005 | Removes desktop deployment GUI and UIConfig targets |
| 006 | Fixes unconditional entries in `pre_MergedLibsList.mk` |
| 007 | Moves DB-dependent code behind `DBCONNECTIVITY` guard |
| 008 | Adds `--export-dynamic` to `libmergedlo.so` (Linux only; macOS exports symbols automatically) |
| 009* | Restricts LTO to merged lib only. `-flto=thin` (macOS/Clang) or `-flto=auto` (Linux/GCC). |
| 010 | Enables ICU data filtering — en-US only locale data instead of 30 MB archive |
| 011 | Makes `SfxApplication::GetOrCreate()` unconditional in LOKit init (required on macOS) |

*Post-autogen patch — runs after `autogen.sh` regenerates build files.

---

## Cross-platform details

### Distro configs

| Config | Platform | Key differences |
|--------|----------|----------------|
| `SlimLO.conf` | Linux, Windows | `--disable-gui` (headless SVP backend), disables GTK/Qt/dbus/gio/gstreamer |
| `SlimLO-macOS.conf` | macOS | No `--disable-gui` (Quartz VCL), `--enable-bogus-pkg-config` for Homebrew |

Both share: `--enable-slimlo`, `--enable-mergelibs`, `--enable-lto`, `--with-java=no`, `--disable-python`, `--enable-mpl-subset`.

### macOS .app bundle layout

macOS uses a different directory structure inside `.app/Contents/`. Build scripts normalize everything to `program/` and `share/` for consistency.

| Content | Linux | macOS (inside `.app/Contents/`) |
|---------|-------|--------------------------------|
| Libraries | `program/` | `Frameworks/` |
| RC files, registries | `program/` | `Resources/` |
| Share data | `share/` | `Resources/` |
| Presets | `presets/` | `Resources/presets/` |

### Custom font loading

`PdfConverterOptions.FontDirectories` works cross-platform:

| Platform | Mechanism | Details |
|----------|-----------|---------|
| Linux | `SAL_FONTPATH` | Fontconfig discovers fonts in specified directories. |
| macOS | CoreText | `CTFontManagerRegisterFontsForURL` registers each `.ttf`/`.otf`/`.ttc` at process scope. No admin privileges. |
| Windows | `SAL_FONTPATH` | LibreOffice discovers fonts in specified directories. |

---

## Size reduction

Full LibreOffice `instdir/` is **~1.5 GB**. SlimLO reduces it in three stages:

### Stage 1: Build-time stripping (1.5 GB → 300 MB)

11 patch scripts conditionally exclude 41+ modules at compile time. Disabled: database connectivity, Java, Python, GUI backends (GTK/Qt), desktop integration, galleries, templates, help, fonts. Everything merges into `libmergedlo` via `--enable-mergelibs`.

### Stage 2: Artifact pruning (300 MB → 214 MB)

`extract-artifacts.sh` removes runtime files not needed for DOCX-to-PDF:

- Non-Writer modules: Calc (23 MB), Impress (10 MB), Math (1.8 MB)
- External import libraries: mwaw, etonyek, wps, orcus, odfgen, wpd, wpg (20 MB)
- VBA macros, CUI dialogs, form controls, UI-only libraries (11 MB)
- XCD config for Calc/Impress/Math/Base/Draw

### Stage 3: LTO + deep pruning (214 MB → 186 MB)

- **LTO**: Link-time optimization on `libmergedlo` with dead code elimination
- **patchelf**: Remove unused `libcurl.so.4` dependency (~4.6 MB)
- **Config pruning**: Remove `oovbaapi.rdb`, `lingucomponent.xcd`, signature SVGs

### What cannot be removed

| Item | Why |
|------|-----|
| `.ui` files in `soffice.cfg/` | LOKit loads dialog definitions even in headless mode |
| RDF stack (`librdf`, `libraptor2`, `librasqal`) | Called at runtime for DOCX-to-PDF |
| Stub `.so` files (21 bytes each) | UNO checks file existence before merged lib fallback |
| Bootstrap RC chain | Missing any link breaks UNO service loading |
| `presets/` directory | Must exist (can be empty) or LOKit throws fatal error |

---

## Runtime requirements

### Build requirements

- **Docker Desktop memory**: 16 GB+ recommended for `-j8`. Large LO source files need ~3 GB per compiler process.

### Runtime requirements

- **Memory**: ~200 MB per worker process.
- **Docker seccomp** (Linux): `--security-opt seccomp=unconfined` required — LO uses `clone3()` for threads.
- **macOS**: No additional dependencies (system frameworks suffice).

### Linux system dependencies

The NuGet package bundles the LibreOffice engine but **not** system-level shared libraries.

**Ubuntu / Debian:**

```bash
apt-get install -y --no-install-recommends \
    libfontconfig1 libfreetype6 libexpat1 libcairo2 libpng16-16 \
    libjpeg-turbo8 libxml2 libxslt1.1 libicu74 libnss3 libnspr4
```

> On Ubuntu 22.04, use `libicu70` instead of `libicu74`.

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

**Optional:** Install `fonts-liberation` for accurate text rendering, or use `PdfConverterOptions.FontDirectories` for custom fonts.

**Troubleshooting:** If the worker crashes at startup with `error while loading shared libraries`, install the missing library. The .NET SDK includes the library name in the exception message.

---

## Project structure

```
.
├── LO_VERSION                     # Pinned LO tag
├── icu-filter.json                # ICU data filter (en-US only)
├── distro-configs/
│   ├── SlimLO.conf                # Linux/Windows configure flags
│   └── SlimLO-macOS.conf          # macOS configure flags
├── patches/                       # 11 idempotent .sh scripts
│   ├── 001..008-*.sh              # Pre-autogen patches
│   ├── 009-*.postautogen          # Post-autogen (LTO flags)
│   ├── 010-icu-data-filter.sh     # ICU locale filtering
│   └── 011-*.sh                   # macOS LOKit init fix
├── scripts/
│   ├── build.sh                   # Cross-platform build pipeline
│   ├── apply-patches.sh           # Runs all patches in order
│   ├── extract-artifacts.sh       # Artifact extraction + pruning
│   ├── docker-build.sh            # Docker build orchestrator
│   └── pack-nuget.sh              # NuGet packaging
├── slimlo-api/                    # C API + worker process
│   ├── CMakeLists.txt             # Cross-platform CMake
│   ├── include/slimlo.h           # Public C header
│   └── src/
│       ├── slimlo.cxx             # LOKit-based C implementation
│       ├── slimlo_worker.c        # IPC worker (stdin/stdout JSON)
│       └── cjson/                 # Vendored cJSON (MIT)
├── dotnet/
│   ├── SlimLO/                    # .NET 8 SDK
│   │   ├── PdfConverter.cs        # Public API
│   │   ├── ConversionResult.cs    # Result with diagnostics
│   │   └── Internal/              # Worker management
│   │       ├── WorkerPool.cs      # Thread-safe pool
│   │       ├── WorkerProcess.cs   # Worker lifecycle + IPC
│   │       └── Protocol.cs        # Length-prefixed JSON framing
│   ├── SlimLO.NativeAssets.Linux/ # Native NuGet (linux-x64 + arm64)
│   ├── SlimLO.NativeAssets.macOS/ # Native NuGet (osx-arm64 + x64)
│   └── SlimLO.Tests/             # 109 xUnit tests
├── docker/
│   └── Dockerfile.linux-x64      # Multi-stage Docker build
├── .github/workflows/
│   ├── build-linux-x64.yml       # CI: Linux x64 (Docker)
│   ├── build-linux-arm64.yml     # CI: Linux arm64 (Docker)
│   ├── build-macos.yml           # CI: macOS arm64
│   ├── build-macos-x64.yml      # CI: macOS x64
│   └── build-windows.yml         # CI: Windows x64 (MSYS2+MSVC)
├── example/                       # Example .NET console app
└── tests/
    ├── test.sh                    # Native integration test
    ├── test_convert.c             # C test program
    └── fixtures/                  # DOCX test fixtures
```

---

## CI pipelines

All pipelines trigger on `pull_request` to `main` and `workflow_dispatch`.

| Workflow | Runner | Build method | Timeout |
|----------|--------|-------------|---------|
| [`build-linux-x64.yml`](https://github.com/mapo80/libreoffice-to-pdf/actions/workflows/build-linux-x64.yml) | `ubuntu-latest` | Docker Buildx + GHA cache | 12h |
| [`build-linux-arm64.yml`](https://github.com/mapo80/libreoffice-to-pdf/actions/workflows/build-linux-arm64.yml) | `ubuntu-24.04-arm` | Docker Buildx + GHA cache | 12h |
| [`build-macos.yml`](https://github.com/mapo80/libreoffice-to-pdf/actions/workflows/build-macos.yml) | `macos-14` (M1) | Native + ccache | 12h |
| [`build-macos-x64.yml`](https://github.com/mapo80/libreoffice-to-pdf/actions/workflows/build-macos-x64.yml) | `macos-15-intel` | Native + ccache | 12h |
| [`build-windows.yml`](https://github.com/mapo80/libreoffice-to-pdf/actions/workflows/build-windows.yml) | `windows-2022` | MSYS2 + MSVC | 12h |

---

## License

MPL-2.0 (matching LibreOffice). Built with `--enable-mpl-subset` to exclude GPL/LGPL components.
