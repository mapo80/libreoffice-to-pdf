# SlimLO

**Managed .NET library for high-fidelity DOCX-to-PDF conversion.**

SlimLO provides a thread-safe, async API backed by a minimal, purpose-built LibreOffice engine. Each conversion runs in an isolated native worker process — if LibreOffice crashes on a malformed document, only the worker is killed; your .NET process is never affected.

## Features

- **Process isolation** — crash-resilient, no shared state between conversions
- **Thread-safe** — `MaxWorkers > 1` enables true parallel conversion across separate OS processes
- **Multiple conversion modes** — file-path (zero-copy), byte buffer (zero disk I/O), and stream-to-stream
- **Font diagnostics** — font substitution warnings surfaced as structured `ConversionDiagnostic` objects
- **PDF options** — PDF/A (1a, 2a, 3a), tagged PDF, JPEG quality, DPI, page ranges
- **Cross-platform** — Linux x64/arm64, macOS arm64/x64, Windows x64/ARM64
- **Wide .NET support** — targets `netstandard2.0` (.NET Framework 4.6.1+) and `net8.0`

## Installation

Install the managed SDK and the native assets package for your target platform:

```xml
<PackageReference Include="SlimLO" Version="0.1.0" />

<!-- Add the native assets package for your target platform -->
<PackageReference Include="SlimLO.NativeAssets.Linux" Version="0.1.0"
    Condition="$([MSBuild]::IsOSPlatform('Linux'))" />
<PackageReference Include="SlimLO.NativeAssets.macOS" Version="0.1.0"
    Condition="$([MSBuild]::IsOSPlatform('OSX'))" />
<PackageReference Include="SlimLO.NativeAssets.Windows" Version="0.1.0"
    Condition="$([MSBuild]::IsOSPlatform('Windows'))" />
```

## Quick Start

```csharp
using SlimLO;

await using var converter = PdfConverter.Create();

var result = await converter.ConvertAsync("input.docx", "output.pdf");
result.ThrowIfFailed();
```

## Advanced Usage

```csharp
await using var converter = PdfConverter.Create(new PdfConverterOptions
{
    FontDirectories = new[] { "/app/fonts" },
    MaxWorkers = 2,
    MaxConversionsPerWorker = 100,
    ConversionTimeout = TimeSpan.FromMinutes(5),
    WarmUp = true
});

// File to file
var result = await converter.ConvertAsync("input.docx", "output.pdf");

// Byte buffer (zero disk I/O)
byte[] docxBytes = await File.ReadAllBytesAsync("input.docx");
var bufResult = await converter.ConvertAsync(docxBytes.AsMemory(), DocumentFormat.Docx);
await File.WriteAllBytesAsync("output.pdf", bufResult.Data!);

// Stream to stream (ideal for ASP.NET)
var streamResult = await converter.ConvertAsync(
    Request.Body, Response.Body, DocumentFormat.Docx);

// PDF/A output with tagged PDF
var result2 = await converter.ConvertAsync("input.docx", "output.pdf",
    new ConversionOptions { PdfVersion = PdfVersion.PdfA2, TaggedPdf = true });
```

## Platform Requirements

| Platform | Requirements |
|----------|-------------|
| Linux    | System libraries: libfontconfig1, libfreetype6, libcairo2, libxml2, libxslt1.1, libicu, libnss3 |
| macOS    | No additional dependencies |
| Windows  | Visual C++ Redistributable 2022 |

## Architecture

Each conversion runs in a separate `slimlo_worker` native process that hosts a minimal LibreOffice engine (`libmergedlo`). The managed SDK communicates with workers via length-prefixed JSON over stdin/stdout pipes. A `WorkerPool` manages worker lifecycle, round-robin dispatch, and automatic crash recovery.

## License

MPL-2.0. See [GitHub repository](https://github.com/mapo80/libreoffice-to-pdf) for full details.
