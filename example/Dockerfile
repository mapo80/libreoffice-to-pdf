# Minimal Linux runtime for SlimLO example.
# Usage:
#   1. Publish the app first:  dotnet publish -c Release -r linux-x64 -o publish/linux-x64
#   2. Build the image:        docker build -t slimlo-example .
#   3. Run:                    docker run --rm -v $(pwd):/data slimlo-example /data/test.docx /data/output.pdf
FROM mcr.microsoft.com/dotnet/runtime:8.0

# Runtime dependencies for LibreOffice
RUN apt-get update && apt-get install -y --no-install-recommends \
    libfontconfig1 libfreetype6 libcairo2 libxml2 libxslt1.1 \
    libnss3 fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY publish/linux-x64/ .

# Ensure presets directory exists (required by LOKit)
RUN mkdir -p /app/presets

ENTRYPOINT ["dotnet", "Example.dll"]
