# SlimLO.NativeAssets.Windows

**Native Windows runtime for the SlimLO DOCX-to-PDF converter.**

This package contains the pre-built native binaries for Windows x64 and ARM64:

- **mergedlo.dll** — Minimal LibreOffice engine containing only the Writer engine, UNO framework, and DOCX/PDF conversion path
- **slimlo.dll** — SlimLO C API layer
- **slimlo_worker.exe** — Process-isolated worker binary for crash-resilient conversion
- Supporting DLLs, UNO registries, and configuration files

Built from vanilla LibreOffice source with 30 idempotent patch scripts — not a fork.

## Installation

This package is consumed automatically by the [SlimLO](https://www.nuget.org/packages/SlimLO) managed package. Add both to your project:

```xml
<PackageReference Include="SlimLO" Version="0.1.0" />
<PackageReference Include="SlimLO.NativeAssets.Windows" Version="0.1.0"
    Condition="$([MSBuild]::IsOSPlatform('Windows'))" />
```

## System Dependencies

Requires [Visual C++ Redistributable 2022](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist) on the host machine.

## Architectures

| Runtime Identifier | Architecture |
|---|---|
| `win-x64` | x86_64 (Intel/AMD) |
| `win-arm64` | ARM64 (Snapdragon, Surface Pro X) |

## License

MPL-2.0. See [GitHub repository](https://github.com/mapo80/libreoffice-to-pdf) for full details.
