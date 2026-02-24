# SlimLO.NativeAssets.macOS

**Native macOS runtime for the SlimLO DOCX-to-PDF converter.**

This package contains the pre-built native binaries for macOS arm64 (Apple Silicon) and x64 (Intel):

- **libmergedlo.dylib** — Minimal, LTO-optimized LibreOffice engine (~62 MB) containing only the Writer engine, UNO framework, and DOCX/PDF conversion path
- **libslimlo.dylib** — SlimLO C API layer
- **slimlo_worker** — Process-isolated worker binary for crash-resilient conversion
- Supporting libraries, UNO registries, and configuration files

Uses the Quartz VCL backend and CoreText for font rendering. Built from vanilla LibreOffice source with 30 idempotent patch scripts — not a fork.

## Installation

This package is consumed automatically by the [SlimLO](https://www.nuget.org/packages/SlimLO) managed package. Add both to your project:

```xml
<PackageReference Include="SlimLO" Version="0.1.0" />
<PackageReference Include="SlimLO.NativeAssets.macOS" Version="0.1.0"
    Condition="$([MSBuild]::IsOSPlatform('OSX'))" />
```

## System Dependencies

No additional system dependencies required. macOS system frameworks provide everything needed.

## Architectures

| Runtime Identifier | Architecture |
|---|---|
| `osx-arm64` | Apple Silicon (M1, M2, M3, M4) |
| `osx-x64` | Intel Mac |

## License

MPL-2.0. See [GitHub repository](https://github.com/mapo80/libreoffice-to-pdf) for full details.
