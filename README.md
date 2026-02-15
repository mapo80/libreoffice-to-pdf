# SlimLO

**Minimal LibreOffice build for DOCX-to-PDF conversion, with .NET, Java and C APIs.**

[![Build Linux x64](https://github.com/mapo80/libreoffice-to-pdf/actions/workflows/build-linux-x64.yml/badge.svg)](https://github.com/mapo80/libreoffice-to-pdf/actions/workflows/build-linux-x64.yml)
[![Build Linux arm64](https://github.com/mapo80/libreoffice-to-pdf/actions/workflows/build-linux-arm64.yml/badge.svg)](https://github.com/mapo80/libreoffice-to-pdf/actions/workflows/build-linux-arm64.yml)
[![Build macOS arm64](https://github.com/mapo80/libreoffice-to-pdf/actions/workflows/build-macos.yml/badge.svg)](https://github.com/mapo80/libreoffice-to-pdf/actions/workflows/build-macos.yml)
[![Build macOS x64](https://github.com/mapo80/libreoffice-to-pdf/actions/workflows/build-macos-x64.yml/badge.svg)](https://github.com/mapo80/libreoffice-to-pdf/actions/workflows/build-macos-x64.yml)
[![Build Windows x64](https://github.com/mapo80/libreoffice-to-pdf/actions/workflows/build-windows.yml/badge.svg)](https://github.com/mapo80/libreoffice-to-pdf/actions/workflows/build-windows.yml)

SlimLO is **not a fork**. It applies idempotent patch scripts to vanilla LibreOffice source, making it trivial to track upstream releases. The result is a single merged library (LTO-optimized) plus a thin C wrapper — a fully self-contained artifact ready for server-side document conversion.

| | |
|---|---|
| **Platforms** | Linux x64/arm64 · macOS arm64/x64 · Windows x64 |
| **Artifact size (always-aggressive)** | ~134 MB (macOS local, `2026-02-15`) |
| **Merged lib** | ~65 MB `.dylib` (macOS local, stripped) |
| **LO version** | `libreoffice-25.8.5.1` |
| **.NET tests** | 195 passing (net8.0 + net6.0) |
| **Java tests** | 38 passing |

---

## Architecture

SlimLO strips LibreOffice down to its Writer engine + UNO + DOCX/PDF conversion path, merges everything into a single shared library via `--enable-mergelibs` + LTO, and exposes it through three APIs:

```
                        ┌─────────────────────┐
                        │   Your Application   │
                        └──────────┬──────────┘
                                   │
          ┌────────────────────────┼───────────────────────┐
          │                        │                       │
  .NET SDK (async)         Java SDK (sync+async)     C API (direct)
          │                        │                       │
 ┌────────┴────────┐    ┌─────────┴────────┐    #include "slimlo.h"
 │  PdfConverter    │    │  PdfConverter     │             │
 │                  │    │                   │             │
 │  WorkerPool      │    │  WorkerPool       │             │
 │  ├─ worker[0] ───┼─┐  │  ├─ worker[0] ───┼─┐           │
 │  ├─ worker[1] ───┼─┤  │  ├─ worker[1] ───┼─┤           │
 │  └─ worker[N] ───┼─┤  │  └─ worker[N] ───┼─┤           │
 └──────────────────┘ │  └──────────────────┘ │           │
                      ▼                       ▼           ▼
                      ┌────────────────────────────────────┐
                      │     slimlo_worker (native IPC)     │
                      │    libslimlo.{so,dylib,dll}        │
                      └──────────────┬─────────────────────┘
                                     │
                             LibreOfficeKit
                                     │
                       ┌─────────────┴──────────────┐
                       │ libmergedlo.{so,dylib,dll}  │
                       │   ~65 MB · LTO · stripped   │
                       │   Writer + UNO + filters    │
                       └─────────────────────────────┘
```

**Key design decisions:**

- **Patch-based, not a fork** — 22 patch scripts (including one post-autogen patch) modify vanilla LO source. No `git .patch` files — scripts are resilient to upstream line-number changes and easy to maintain across LO upgrades.
- **Single merged library** — `--enable-mergelibs` + LTO combines hundreds of LO modules into one `libmergedlo`. Dead code elimination + aggressive stripping reduces 1.5 GB to ~134 MB extracted runtime (macOS local, always-aggressive profile).
- **Process isolation** (.NET / Java) — Each conversion runs in a separate native `slimlo_worker` process. LibreOffice crash on a malformed document kills only the worker, never the host application.
- **Same worker, multiple SDKs** — Both .NET and Java SDKs spawn the same `slimlo_worker` binary and communicate via the same length-prefixed JSON IPC protocol over stdin/stdout pipes.

---

## .NET SDK

The .NET SDK provides a thread-safe, async API with process isolation, crash recovery, and font diagnostics. Multi-targets `netstandard2.0` and `net8.0`.

| Runtime | Target consumed | Notes |
|---------|----------------|-------|
| .NET 8+ | `net8.0` | Full features: `LibraryImport`, source-generated JSON, `NativeLibrary` resolver |
| .NET 6 / 7 | `netstandard2.0` | Full features via polyfills. Classic `[DllImport]`, reflection-based JSON |
| .NET Framework 4.6.1+ | `netstandard2.0` | Fully supported. See [.NET Framework notes](#net-framework-notes) below |

> Supported input format is **DOCX only**. `DocumentFormat.Xlsx` / `DocumentFormat.Pptx` are kept for binary compatibility and return `InvalidFormat`.

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
    FontDirectories = new[] { "/app/fonts" },  // custom fonts (cross-platform)
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

**`ConversionOptions`** — Per-conversion settings.

| Property | Default | Description |
|----------|---------|-------------|
| `PdfVersion` | `Default` (1.7) | `PdfA1`, `PdfA2`, `PdfA3` for archival. |
| `JpegQuality` | 0 (= 90) | JPEG compression quality 1-100. |
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

**Test suite:** 195 tests covering all public types, IPC protocol (binary framing + JSON serialization), polyfills, diagnostic parsing, end-to-end conversion with DOCX fixtures (multi-font, Unicode, rich formatting, large documents, missing fonts, custom font loading), concurrent conversions, dispose behavior, DOCX-only enforcement, and error handling. Tests run on both `net8.0` and `net6.0` (which consumes the `netstandard2.0` build), for a total of 390 test executions.

### .NET Framework notes

The SDK fully supports .NET Framework 4.6.1+ via the `netstandard2.0` target. The API surface is identical across all runtimes. A few internal behaviors differ:

| Behavior | .NET 8 | .NET Framework 4.6.1+ |
|----------|--------|----------------------|
| P/Invoke | `LibraryImport` (source-generated) | Classic `[DllImport]` |
| JSON serialization | Source-generated (`JsonSerializerContext`) | Reflection-based (`System.Text.Json` NuGet) |
| DLL resolution | `NativeLibrary.SetDllImportResolver` (custom search) | Standard DLL search order (output directory, PATH) |
| Process cleanup | `Process.Kill(entireProcessTree: true)` | `Process.Kill()` (single process) |
| Async file I/O | `File.ReadAllBytesAsync` (native) | `Task.Run(() => File.ReadAllBytes(...))` |

**None of these differences affect the public API or conversion results.** The `SlimLO.NativeAssets.*` NuGet packages include `.targets` files that copy native assets to the output directory, so DLL resolution works out of the box.

**NuGet packages required:**

```xml
<PackageReference Include="SlimLO" Version="0.1.0" />
<!-- Plus the platform-specific native assets package -->
```

The `SlimLO` package automatically brings in these polyfill dependencies for `netstandard2.0` consumers:
- `System.Memory` (4.5.5) — `ReadOnlyMemory<byte>`, `Span<T>`
- `System.Text.Json` (8.0.5) — JSON serialization
- `System.Threading.Tasks.Extensions` (4.5.4) — `ValueTask`
- `Microsoft.Bcl.AsyncInterfaces` (8.0.0) — `IAsyncDisposable`

---

## Java SDK

The Java SDK provides the same process-isolated, thread-safe conversion as the .NET SDK, targeting **Java 8+** for maximum compatibility. It reuses the same `slimlo_worker` binary and IPC protocol — no JNI required.

> Supported input format is **DOCX only**. `DocumentFormat.XLSX` / `DocumentFormat.PPTX` are kept for API symmetry and return `INVALID_FORMAT`.

### Installation

**Maven:**

```xml
<dependency>
    <groupId>com.slimlo</groupId>
    <artifactId>slimlo</artifactId>
    <version>0.1.0</version>
</dependency>
```

**Gradle:**

```groovy
implementation 'com.slimlo:slimlo:0.1.0'
```

The API JAR (~100 KB) contains only the Java SDK. Native assets (the `slimlo_worker` binary and LibreOffice libraries) must be provided separately — either via platform-specific native JARs, a tarball from GitHub Releases, or by setting the `SLIMLO_RESOURCE_PATH` environment variable.

> On Linux, the host must have system libraries installed. See [Linux system dependencies](#linux-system-dependencies).

### Quick start

```java
import com.slimlo.*;

try (PdfConverter converter = PdfConverter.create()) {
    ConversionResult result = converter.convert("input.docx", "output.pdf");
    result.throwIfFailed();

    System.out.println("PDF size: " + new java.io.File("output.pdf").length() + " bytes");
}
```

### Full API examples

```java
import com.slimlo.*;
import java.io.*;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Arrays;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;

// ── Create with options ──────────────────────────────────────────
PdfConverterOptions options = PdfConverterOptions.builder()
        .resourcePath("/opt/slimlo")                // auto-detected if not set
        .fontDirectories(Arrays.asList("/app/fonts"))  // custom fonts (cross-platform)
        .maxWorkers(2)                              // parallel worker processes
        .maxConversionsPerWorker(100)               // recycle after N conversions
        .conversionTimeout(5, TimeUnit.MINUTES)     // per-conversion timeout
        .warmUp(true)                               // pre-start workers
        .build();

try (PdfConverter converter = PdfConverter.create(options)) {

    // ── File to file ─────────────────────────────────────────────
    ConversionResult result = converter.convert("input.docx", "output.pdf");
    if (!result.isSuccess())
        System.err.println("Failed: " + result.getErrorMessage()
                + " (" + result.getErrorCode() + ")");

    // ── Buffer conversion ────────────────────────────────────────
    byte[] docxBytes = Files.readAllBytes(Paths.get("input.docx"));
    ConversionResult bufResult = converter.convert(docxBytes, DocumentFormat.DOCX);
    bufResult.throwIfFailed();
    Files.write(Paths.get("output.pdf"), bufResult.getData());

    // ── Stream to stream (Servlet / Spring) ──────────────────────
    InputStream inputStream = new FileInputStream("input.docx");
    ByteArrayOutputStream outputStream = new ByteArrayOutputStream();
    ConversionResult streamResult = converter.convert(
            inputStream, outputStream, DocumentFormat.DOCX);

    // ── PDF options ──────────────────────────────────────────────
    ConversionOptions pdfOptions = ConversionOptions.builder()
            .pdfVersion(PdfVersion.PDF_A2)
            .jpegQuality(85)
            .dpi(150)
            .taggedPdf(true)
            .pageRange("1-5")
            .build();

    ConversionResult result2 = converter.convert(
            "input.docx", "output.pdf", pdfOptions);

    // ── Async (CompletableFuture) ────────────────────────────────
    CompletableFuture<ConversionResult> future =
            converter.convertAsync("input.docx", "output.pdf");
    ConversionResult asyncResult = future.get(5, TimeUnit.MINUTES);

    // ── Font warnings ────────────────────────────────────────────
    if (result.hasFontWarnings()) {
        for (ConversionDiagnostic d : result.getDiagnostics()) {
            System.out.println("  " + d.getSeverity() + ": " + d.getMessage());
        }
    }
}
```

### How it works

```
┌─ JVM Process ───────────────────────────────────────────────────┐
│                                                                  │
│  PdfConverter.convert(...)  /  convertAsync(...)                 │
│       │                                                          │
│       ▼                                                          │
│  WorkerPool  (thread-safe, Semaphore + round-robin)              │
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

- **Process isolation**: A crash in LibreOffice kills only the worker. The JVM gets a failure result and the worker is auto-replaced.
- **Two IPC modes**: File-path mode sends only paths (zero-copy); buffer mode sends raw bytes over pipes (zero disk I/O).
- **Thread safety**: `WorkerPool` uses `java.util.concurrent.Semaphore` and `ReentrantLock` for thread-safe access. With `maxWorkers > 1`, conversions run in parallel across separate OS processes.
- **Font diagnostics**: The worker captures LOKit stderr and parses font substitution warnings into `ConversionDiagnostic` objects.
- **No JNI**: Pure Java — all communication with the native worker is via OS pipes and length-prefixed JSON frames.

### Conversion modes

| Method | IPC mode | Memory behavior |
|--------|----------|-----------------|
| `convert(String, String, ...)` | File-path | Worker handles all I/O. Minimal JVM memory. Format auto-detected from extension. |
| `convert(byte[], DocumentFormat, ...)` | Buffer | Input + PDF bytes in JVM memory. Zero disk I/O. PDF bytes in `result.getData()`. |
| `convert(InputStream, OutputStream, DocumentFormat, ...)` | Buffer | Stream read into memory, converted, PDF written to output stream. No temp files. |

All sync methods have `convertAsync(...)` variants returning `CompletableFuture<ConversionResult>`.

**When to use which:**

- **Batch processing / large files** — `convert(inputPath, outputPath)`. Most memory-efficient: the JVM never touches document bytes.
- **Servlet / Spring / web servers** — `convert(inputStream, outputStream, format)` to pipe request body to response. No temp files.
- **In-memory pipelines** — `convert(byte[], format)` when you already have bytes from a database, queue, or blob storage.

### API reference

**`PdfConverter`** — Main entry point. Implements `Closeable`.

| Method | Description |
|--------|-------------|
| `create()` | Create converter with default options. |
| `create(PdfConverterOptions)` | Create converter with custom options. Workers start lazily (or eagerly with `warmUp(true)`). |
| `convert(in, out)` | File-to-file via file-path IPC. Returns `ConversionResult`. |
| `convert(in, out, ConversionOptions)` | File-to-file with PDF options. |
| `convert(byte[], DocumentFormat)` | Bytes-to-PDF via buffer IPC. PDF in `result.getData()`. |
| `convert(byte[], DocumentFormat, ConversionOptions)` | Bytes-to-PDF with PDF options. |
| `convert(InputStream, OutputStream, DocumentFormat)` | Stream-to-stream via buffer IPC. |
| `convert(InputStream, OutputStream, DocumentFormat, ConversionOptions)` | Stream-to-stream with PDF options. |
| `convertAsync(...)` | Async variants of all above — returns `CompletableFuture<ConversionResult>`. |
| `close()` | Gracefully shut down all workers (sends quit, waits 5s, then kills). |

**`PdfConverterOptions.Builder`** — Converter-level configuration (builder pattern).

| Method | Default | Description |
|--------|---------|-------------|
| `resourcePath(String)` | auto-detect | Path to SlimLO resources (containing `program/`). |
| `fontDirectories(List<String>)` | `null` | Custom font directories. Linux: fontconfig. macOS: CoreText registration. |
| `maxWorkers(int)` | 1 | Parallel worker processes. |
| `maxConversionsPerWorker(int)` | 0 (unlimited) | Recycle worker after N conversions. |
| `conversionTimeout(long, TimeUnit)` | 5 min | Per-conversion timeout. Worker killed on timeout. |
| `warmUp(boolean)` | `false` | Pre-start all workers during `create()`. |

**`ConversionOptions.Builder`** — Per-conversion settings (builder pattern).

| Method | Default | Description |
|--------|---------|-------------|
| `pdfVersion(PdfVersion)` | `DEFAULT` (1.7) | `PDF_A1`, `PDF_A2`, `PDF_A3` for archival. |
| `jpegQuality(int)` | 0 (= 90) | JPEG compression quality 1-100. |
| `dpi(int)` | 0 (= 300) | Maximum image resolution. |
| `taggedPdf(boolean)` | `false` | Tagged PDF for accessibility. |
| `pageRange(String)` | `null` (all) | e.g., `"1-5"` or `"1,3,5-7"`. |
| `password(String)` | `null` | Password for protected documents. |

**`ConversionResult`** — Conversion outcome with diagnostics.

| Method | Description |
|--------|-------------|
| `isSuccess()` | `true` if conversion succeeded. |
| `getErrorMessage()` | Error description (null on success). |
| `getErrorCode()` | `SlimLOErrorCode` enum (null on success). |
| `getDiagnostics()` | `List<ConversionDiagnostic>` — may be non-empty even on success. |
| `hasFontWarnings()` | `true` if any diagnostic has `category == FONT`. |
| `getData()` | PDF bytes (buffer conversions only). Null for file-path mode or on failure. |
| `throwIfFailed()` | Throws `SlimLOException` on failure, returns `this` on success. |

**`ConversionDiagnostic`** — A single diagnostic entry.

| Method | Description |
|--------|-------------|
| `getSeverity()` | `DiagnosticSeverity.INFO` or `WARNING` |
| `getCategory()` | `DiagnosticCategory.GENERAL`, `FONT`, or `LAYOUT` |
| `getMessage()` | Human-readable message |
| `getFontName()` | Font name (if font-related, null otherwise) |
| `getSubstitutedWith()` | Substitute font name (if substitution occurred, null otherwise) |

**Enums:**

| Enum | Values |
|------|--------|
| `DocumentFormat` | `UNKNOWN(0)`, `DOCX(1)`, `XLSX(2)`, `PPTX(3)` |
| `PdfVersion` | `DEFAULT(0)`, `PDF_A1(1)`, `PDF_A2(2)`, `PDF_A3(3)` |
| `SlimLOErrorCode` | `OK(0)`, `INIT_FAILED(1)`, `LOAD_FAILED(2)`, `CONVERT_FAILED(3)`, `FILE_NOT_FOUND(4)`, `INVALID_FORMAT(5)`, `INVALID_ARGUMENT(6)`, `NOT_INITIALIZED(7)`, `UNKNOWN(99)` |

### Deploying to Linux (Java)

**Docker (recommended):**

```dockerfile
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /src
COPY . .
RUN mvn clean package -pl myapp -am -DskipTests

FROM eclipse-temurin:17-jre-noble
RUN apt-get update && apt-get install -y --no-install-recommends \
    libfontconfig1 libfreetype6 libexpat1 libcairo2 libpng16-16 \
    libjpeg-turbo8 libxml2 libxslt1.1 libicu74 libnss3 libnspr4 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /src/myapp/target/myapp.jar .
COPY slimlo-resources/ /opt/slimlo/
ENV SLIMLO_RESOURCE_PATH=/opt/slimlo
ENTRYPOINT ["java", "-jar", "myapp.jar"]
```

**Bare-metal / VM:** Install the [system dependencies](#linux-system-dependencies), extract the SlimLO tarball, and set `SLIMLO_RESOURCE_PATH`.

### Deploying to macOS (Java)

No additional system dependencies needed — macOS system frameworks suffice. Set `SLIMLO_RESOURCE_PATH` to point to the extracted native assets.

### Environment variables

| Variable | Description |
|----------|-------------|
| `SLIMLO_RESOURCE_PATH` | Override auto-detected resource directory. The SDK searches for `program/libmergedlo.{so,dylib,dll}` or `program/sofficerc` inside this directory. |
| `SLIMLO_WORKER_PATH` | Override auto-detected `slimlo_worker` executable path. |

### Worker locator search order

The Java SDK searches for the `slimlo_worker` executable in this order:

1. Same directory as the SDK JAR
2. `native/` subdirectory of the JAR location
3. `program/` subdirectory of the JAR location
4. `SLIMLO_WORKER_PATH` environment variable
5. `SLIMLO_RESOURCE_PATH/program/` environment variable

The resource directory is searched in this order:

1. Same directory as the JAR (checks for `program/` subdirectory)
2. `slimlo-resources/` subdirectory of the JAR location
3. Parent directory
4. `SLIMLO_RESOURCE_PATH` environment variable

### Running tests

```bash
cd java

# Unit tests only (no native dependencies)
mvn test -pl slimlo

# All tests including integration (requires native artifacts)
SLIMLO_RESOURCE_PATH=/path/to/slimlo-output mvn test -pl slimlo
```

**Test suite:** 38 tests covering IPC protocol framing, result model, diagnostics, end-to-end file-to-file conversion, buffer conversion (byte[]), stream conversion (InputStream/OutputStream), PDF options, DOCX-only enforcement, and error handling.

### Building the JAR

```bash
# Build and run tests
./scripts/pack-maven.sh

# Output: java/slimlo/target/slimlo-0.1.0.jar
```

### Dependencies

| Dependency | Version | Scope | Size |
|------------|---------|-------|------|
| [Gson](https://github.com/google/gson) | 2.11.0 | compile | ~280 KB |
| [JUnit 5](https://junit.org/junit5/) | 5.10.3 | test | — |

Gson is the only runtime dependency (zero transitive dependencies, Java 8+).

---

## .NET vs Java SDK comparison

Both SDKs share the same architecture (process-isolated worker pool) and IPC protocol. Key differences:

| Feature | .NET SDK | Java SDK |
|---------|----------|----------|
| **Minimum version** | .NET Framework 4.6.1 / .NET 6+ | Java 8 |
| **API style** | Async-first (`async`/`await`) | Sync-first + `CompletableFuture` async |
| **Lifecycle** | `IAsyncDisposable` + `IDisposable` | `Closeable` (`try-with-resources`) |
| **Options** | Object initializers (`init` setters) | Builder pattern |
| **Cancellation** | `CancellationToken` on every method | Timeout only (via `Future.get(timeout)`) |
| **Buffer input** | `ReadOnlyMemory<byte>` (zero-copy) | `byte[]` |
| **Result pattern** | `if (result)` (implicit bool) | `result.isSuccess()` |
| **Typed buffer result** | `ConversionResult<byte[]>` | `result.getData()` on same `ConversionResult` |
| **Packaging** | NuGet (managed + native asset packages) | Maven (API JAR + separate native tarball) |
| **JSON library** | System.Text.Json (built-in, AOT) | Gson (~280 KB, zero deps) |
| **Test count** | 195 tests (x2 TFMs = 390) | 38 tests |
| **Stream overloads** | 5 overloads (Stream, file, mixed) | 3 overloads (file, buffer, stream) |

---

## C API

For direct native integration without process isolation overhead.

> Supported input format is **DOCX only**. `SLIMLO_FORMAT_XLSX` / `SLIMLO_FORMAT_PPTX` are retained for ABI compatibility and return `SLIMLO_ERROR_INVALID_FORMAT`.

```c
#include "slimlo.h"

int main() {
    SlimLOHandle h = slimlo_init("/path/to/slimlo");
    if (!h) return 1;

    SlimLOError err = slimlo_convert_file(
        h, "input.docx", "output.pdf",
        SLIMLO_FORMAT_UNKNOWN,  // auto-detect (.docx only)
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

**Thread safety:** Conversions serialized via internal mutex. For concurrency, use multiple processes (or the .NET/Java SDK).

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
| `DOCX_AGGRESSIVE` | `1` | Always-aggressive profile (`1` only; `0` is rejected) |

### Build profile

```bash
# Always-aggressive DOCX-only profile
DOCX_AGGRESSIVE=1 ./scripts/build.sh

# Equivalent (default)
./scripts/build.sh
```

### Probe aggressive candidates

```bash
# C gate (file-path conversion smoke)
./scripts/prune-probe.sh ./output

# Optional extra gate (enable .NET stream/buffer checks)
PRUNE_DOTNET_GATE=1 ./scripts/prune-probe.sh ./output
```

### Build metadata and size reports

Each build writes reproducibility and size artifacts into the output directory:

- `output/build-metadata.json` — source/config/patch hashes + toolchain versions
- `output/size-report.json` — extracted size, top files, dependency scan
- `output/size-report.txt` — human-readable summary

Related scripts:

- `scripts/write-build-metadata.sh`
- `scripts/measure-artifact.sh`
- `scripts/check-deps-allowlist.sh`
- `scripts/run-gate.sh`
- `scripts/macos-ultra-matrix.sh`

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

**Windows prerequisites:** Visual Studio 2022/2026 (C++ desktop workload), Python 3.11+ (python.org), MSYS2 (`C:\msys64`). See the [Windows build scripts](#windows-build-scripts) section below for the full local build workflow.

### Windows build scripts

Local Windows builds use a set of scripts that handle MSVC toolchain discovery, MSYS2 environment setup, and architecture auto-detection. The recommended workflow is:

```powershell
# 1. Install prerequisites (Visual Studio, Python, MSYS2)
.\scripts\setup-prerequisites.ps1

# 2. Open MSYS2 MSYS shell and run the environment setup
./scripts/setup-windows-msys2.sh

# 3. Launch the build from PowerShell (loads vcvarsall then calls MSYS2)
.\scripts\Start-WindowsBuild.ps1

# Or: resume a build skipping clone/configure (incremental)
.\scripts\Start-WindowsBuild.ps1 -SkipConfigure

# Or: use the batch launcher
.\scripts\run-windows-build.bat
```

| File | Purpose | Usage |
|------|---------|-------|
| `scripts/Start-WindowsBuild.ps1` | PowerShell launcher. Loads `vcvarsall.bat x64`, then invokes MSYS2 with the build. | `.\scripts\Start-WindowsBuild.ps1 [-BuildOnly] [-SkipConfigure] [-Parallelism 8]` |
| `scripts/run-windows-build.bat` | Batch launcher. Same as above but for `cmd.exe`. | `.\scripts\run-windows-build.bat` |
| `scripts/setup-prerequisites.ps1` | Checks and installs prerequisites (VS, Python, MSYS2) via `winget`. | `.\scripts\setup-prerequisites.ps1` |
| `scripts/setup-windows-msys2.sh` | Installs MSYS2 packages, creates `pkgconf` and `wslpath` shims. Run once inside MSYS2 MSYS shell. | `./scripts/setup-windows-msys2.sh` |
| `scripts/windows-build.sh` | Build wrapper called by the launchers. Auto-detects MSVC `cl.exe`, Windows Python, NASM, and target architecture. | Called automatically; can also run directly from MSYS2 after `vcvarsall`. |
| `scripts/windows-debug-harfbuzz.sh` | Diagnostic tool for the most common build failure (HarfBuzz Meson). Dumps compiler paths, cross-file, and environment. | `./scripts/windows-debug-harfbuzz.sh` |
| `patches/021-support-vs2026.sh` | Adds Visual Studio 2026 (v18.x, toolset v145) support to LibreOffice's `configure.ac`. | Applied automatically by `build.sh`. |
| `patches/022-fix-external-patch-line-endings.sh` | Converts CRLF patch files to LF. Required because MSVC builds use `--binary` patch mode. | Applied automatically by `build.sh`. |
| `distro-configs/SlimLO-windows.conf` | Windows-specific `configure` flags (MSVC, static externals, disabled GUI). | Selected automatically by `build.sh` on Windows. |

> **Notes:**
> - MSYS2 runs under x64 Prism emulation on ARM64 Windows, so `vcvarsall` always uses `x64`. The produced binaries are x64 and run on ARM64 via emulation.
> - `SKIP_CONFIGURE=1` (or `-SkipConfigure`) skips clone, patching, and configure steps — useful for incremental rebuilds after fixing a build error.
> - HarfBuzz Meson is the most common failure point. Use `windows-debug-harfbuzz.sh` for diagnostics.

### Output layout

```
output/
├── program/           # ~132 MB (always-aggressive, macOS local)
│   ├── libmergedlo.{so,dylib,dll}  # ~65 MB core engine (macOS local, LTO)
│   ├── libslimlo.{so,dylib,dll}    # C API wrapper
│   ├── slimlo_worker               # IPC worker process
│   ├── lib*.{so,dylib}             # UNO, ICU, externals, stubs
│   ├── sofficerc                   # Bootstrap RC chain
│   └── types/offapi.rdb            # UNO type registry
├── share/             # ~2.5 MB (always-aggressive, macOS local)
│   ├── registry/*.xcd
│   ├── config/soffice.cfg/
│   └── filter/
├── presets/            # Empty (required by LOKit)
├── build-metadata.json # Deterministic source/config/toolchain metadata
├── size-report.json    # Extracted size + dependency scan
├── size-report.txt     # Human summary
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

| Patch script | What it does |
|-------------|--------------|
| `001-add-slimlo-configure-flag.sh` | Adds `--enable-slimlo` configure flag and host config propagation. |
| `002-strip-modules.sh` | Excludes non-essential LO modules at build time. |
| `003-slimlo-distro-config.sh` | Wires SlimLO distro config into LO build flow. |
| `004-strip-filters.sh` | Removes non-Writer export filters not required for DOCX->PDF. |
| `005-strip-ui-libraries.sh` | Strips GUI/deployment/UI config targets. |
| `006-fix-mergelibs-conditionals.sh` | Fixes merge-lib conditionals for slimmed builds. |
| `007-fix-swui-db-conditionals.sh` | Guards DB-related Writer UI code paths. |
| `008-mergedlibs-export-constructors.sh` | Preserves UNO constructor symbol visibility in merged libs. |
| `009-fix-nonmerged-lto-link.postautogen` | Post-autogen fix: LTO only on merged lib link step. |
| `010-force-native-winsymlinks.sh` | Windows symlink/build-system compatibility fix. |
| `010-icu-data-filter.sh` | Applies ICU data filtering (`icu-filter.json`). |
| `011-fix-windows-midl-include.sh` | Fixes Windows MIDL include path issues. |
| `011-sfxapplication-getorcreate.sh` | Stabilizes LOKit startup path (`SfxApplication::GetOrCreate`). |
| `012-fix-lcms2-msbuild-env.sh` | Fixes lcms2 MSBuild environment handling on Windows. |
| `013-fix-libjpeg-turbo-hidden-macro.sh` | Fixes hidden macro/visibility issue in libjpeg-turbo integration. |
| `014-fix-icu-msvc-lib-env.sh` | Fixes ICU library environment handling under MSVC. |
| `015-fix-icu-autoconf-wrapper-msvc.sh` | Fixes ICU autoconf wrapper behavior on MSVC toolchains. |
| `016-fix-nss-msvc-env.sh` | Fixes NSS environment/toolchain handling on MSVC. |
| `017-lokit-buffer-api.sh` | Adds LOKit buffer API (`documentLoadFromBuffer` / `saveToBuffer`). |
| `018-fix-icu-windows-configure-flags.sh` | Fixes ICU-related Windows configure flags. |
| `019-strip-windows-atl-targets.sh` | Removes unneeded ATL-linked Windows targets. |
| `020-fix-harfbuzz-meson-msvc-path.sh` | Fixes HarfBuzz Meson MSVC path handling. |

---

## Cross-platform details

### Distro configs

| Config | Platform | Key differences |
|--------|----------|----------------|
| `SlimLO.conf` | Linux | `--disable-gui` (headless SVP backend), disables GTK/Qt/dbus/gio/gstreamer |
| `SlimLO-macOS.conf` | macOS | No `--disable-gui` (Quartz VCL), `--enable-bogus-pkg-config` for Homebrew |
| `SlimLO-windows.conf` | Windows x64 | MSVC-oriented flags, OpenSSL TLS path, no GTK/Qt integrations |

All three share the DOCX-only hard-minimal direction: `--enable-slimlo`, `--enable-mergelibs`, `--enable-lto`, `--with-java=no`, `--disable-python`, `--disable-scripting`, `--disable-curl`, `--disable-nss`, `--with-tls=openssl`.

### macOS .app bundle layout

macOS uses a different directory structure inside `.app/Contents/`. Build scripts normalize everything to `program/` and `share/` for consistency.

| Content | Linux | macOS (inside `.app/Contents/`) |
|---------|-------|--------------------------------|
| Libraries | `program/` | `Frameworks/` |
| RC files, registries | `program/` | `Resources/` |
| Share data | `share/` | `Resources/` |
| Presets | `presets/` | `Resources/presets/` |

### Custom font loading

Both `PdfConverterOptions.FontDirectories` (.NET) and `PdfConverterOptions.Builder.fontDirectories()` (Java) work cross-platform:

| Platform | Mechanism | Details |
|----------|-----------|---------|
| Linux | `SAL_FONTPATH` | Fontconfig discovers fonts in specified directories. |
| macOS | CoreText | `CTFontManagerRegisterFontsForURL` registers each `.ttf`/`.otf`/`.ttc` at process scope. No admin privileges. |
| Windows | `SAL_FONTPATH` | LibreOffice discovers fonts in specified directories. |

---

## Size reduction

Full LibreOffice `instdir/` is **~1.5 GB**. SlimLO reduces it in three stages:

### Stage 1: Build-time stripping (1.5 GB -> ~300 MB)

22 patch scripts conditionally exclude modules and fix platform-specific build edges (Linux/macOS/Windows). Disabled paths include DB tooling, Java/Python, desktop integration, and non-essential UI/runtime components. Everything merges into `libmergedlo` via `--enable-mergelibs`.

### Stage 2: Always-aggressive artifact pruning (~300 MB -> ~134 MB)

`extract-artifacts.sh` runs in always-aggressive DOCX-only mode (`DOCX_AGGRESSIVE=1`) and removes runtime files not needed for DOCX-to-PDF:

- Non-Writer modules and import backends
- UI-only libraries/config packs
- Unused XCD/runtime entries and helper executables

### Stage 3: Probe-driven dependency floor and gate enforcement

- Candidate set validated by `scripts/prune-probe.sh` + `scripts/run-gate.sh`
- Prune manifest: `artifacts/prune-manifest-docx-aggressive.txt`
- Dependency allowlists:
  - `artifacts/deps-allowlist-macos.txt`
  - `artifacts/deps-allowlist-linux.txt`
  - `artifacts/deps-allowlist-windows.txt`
- Size/dependency reports generated by:
  - `scripts/write-build-metadata.sh`
  - `scripts/measure-artifact.sh`
  - `scripts/check-deps-allowlist.sh`

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

The NuGet/Maven packages bundle the LibreOffice engine but **not** system-level shared libraries.

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

**Optional:** Install `fonts-liberation` for accurate text rendering, or use `FontDirectories` in your SDK options for custom fonts.

**Troubleshooting:** If the worker crashes at startup with `error while loading shared libraries`, install the missing library. Both the .NET and Java SDKs include the library name in the exception message.

---

## Project structure

```
.
├── LO_VERSION                     # Pinned LO tag
├── icu-filter.json                # ICU data filter (en-US only)
├── distro-configs/
│   ├── SlimLO.conf                # Linux configure flags
│   ├── SlimLO-macOS.conf          # macOS configure flags
│   └── SlimLO-windows.conf        # Windows configure flags (MSVC)
├── patches/                       # 22+ patch scripts (+ post-autogen)
│   ├── 001..008-*.sh              # Core SlimLO build pruning/fixes
│   ├── 009-*.postautogen          # Post-autogen link/LTO fix
│   ├── 010..020-*.sh              # ICU/Windows/LOKit/platform fixes
│   ├── 021-support-vs2026.sh      # Visual Studio 2026 support
│   ├── 022-fix-external-patch-line-endings.sh  # CRLF→LF for MSVC
│   └── ...                        # See patch table above
├── scripts/
│   ├── build.sh                   # Cross-platform build pipeline
│   ├── apply-patches.sh           # Runs all patches in order
│   ├── extract-artifacts.sh       # Artifact extraction + pruning
│   ├── docker-build.sh            # Docker build orchestrator
│   ├── pack-nuget.sh              # NuGet packaging
│   ├── pack-maven.sh              # Maven packaging
│   ├── Start-WindowsBuild.ps1     # Windows: PowerShell build launcher
│   ├── run-windows-build.bat      # Windows: Batch build launcher
│   ├── setup-prerequisites.ps1    # Windows: Prerequisites installer
│   ├── setup-windows-msys2.sh     # Windows: MSYS2 environment setup
│   ├── windows-build.sh           # Windows: Build wrapper (MSVC/Python auto-detect)
│   └── windows-debug-harfbuzz.sh  # Windows: HarfBuzz Meson diagnostics
├── slimlo-api/                    # C API + worker process
│   ├── CMakeLists.txt             # Cross-platform CMake
│   ├── include/slimlo.h           # Public C header
│   └── src/
│       ├── slimlo.cxx             # LOKit-based C implementation
│       ├── slimlo_worker.c        # IPC worker (stdin/stdout JSON)
│       └── cjson/                 # Vendored cJSON (MIT)
├── dotnet/
│   ├── SlimLO/                    # .NET SDK (netstandard2.0 + net8.0)
│   │   ├── PdfConverter.cs        # Public API (async/await)
│   │   ├── ConversionResult.cs    # Result with diagnostics
│   │   └── Internal/              # Worker management
│   │       ├── WorkerPool.cs      # Thread-safe pool
│   │       ├── WorkerProcess.cs   # Worker lifecycle + IPC
│   │       └── Protocol.cs        # Length-prefixed JSON framing
│   ├── SlimLO.NativeAssets.Linux/ # Native NuGet (linux-x64 + arm64)
│   ├── SlimLO.NativeAssets.macOS/ # Native NuGet (osx-arm64 + x64)
│   └── SlimLO.Tests/             # 195 xUnit tests (net8.0 + net6.0)
├── java/
│   ├── pom.xml                    # Parent POM (multi-module)
│   ├── slimlo/                    # Java SDK (Java 8+, Gson)
│   │   ├── pom.xml               # com.slimlo:slimlo:0.1.0
│   │   └── src/main/java/com/slimlo/
│   │       ├── PdfConverter.java  # Public API (sync + CompletableFuture)
│   │       ├── ConversionResult.java
│   │       └── internal/          # Worker management
│   │           ├── WorkerPool.java
│   │           ├── WorkerProcess.java
│   │           └── Protocol.java
│   └── example/                   # Example Java console app
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
Each pipeline always uploads build reports (`build-metadata.json`, `size-report.json`, `size-report.txt`) in a dedicated artifact, in addition to the runtime artifact.

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
