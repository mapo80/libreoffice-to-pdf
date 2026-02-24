# SlimLO.NativeAssets.Linux

**Native Linux runtime for the SlimLO DOCX-to-PDF converter.**

This package contains the pre-built native binaries for Linux x64 and arm64:

- **libmergedlo.so** — Minimal, LTO-optimized LibreOffice engine (~98 MB) containing only the Writer engine, UNO framework, and DOCX/PDF conversion path
- **libslimlo.so** — SlimLO C API layer
- **slimlo_worker** — Process-isolated worker binary for crash-resilient conversion
- Supporting libraries, UNO registries, and configuration files

Built from vanilla LibreOffice source with 30 idempotent patch scripts — not a fork.

## Installation

This package is consumed automatically by the [SlimLO](https://www.nuget.org/packages/SlimLO) managed package. Add both to your project:

```xml
<PackageReference Include="SlimLO" Version="0.1.0" />
<PackageReference Include="SlimLO.NativeAssets.Linux" Version="0.1.0"
    Condition="$([MSBuild]::IsOSPlatform('Linux'))" />
```

## System Dependencies

The host Linux system must have these libraries installed:

```bash
# Ubuntu 24.04 (Noble)
sudo apt-get install -y --no-install-recommends \
    libfontconfig1 libfreetype6 libexpat1 libcairo2 libpng16-16 \
    libjpeg-turbo8 libxml2 libxslt1.1 libicu74 libnss3 libnspr4
```

## Docker

```dockerfile
FROM mcr.microsoft.com/dotnet/runtime:8.0-noble

RUN apt-get update && apt-get install -y --no-install-recommends \
    libfontconfig1 libfreetype6 libexpat1 libcairo2 libpng16-16 \
    libjpeg-turbo8 libxml2 libxslt1.1 libicu74 libnss3 libnspr4 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /app/publish /app
WORKDIR /app
ENTRYPOINT ["dotnet", "YourApp.dll"]
```

Use the `-noble` (Ubuntu 24.04) base image. Default Debian-based images use different package names.

## Architectures

| Runtime Identifier | Architecture |
|---|---|
| `linux-x64` | x86_64 (Intel/AMD) |
| `linux-arm64` | AArch64 (AWS Graviton, Ampere, Raspberry Pi 4+) |

## License

MPL-2.0. See [GitHub repository](https://github.com/mapo80/libreoffice-to-pdf) for full details.
