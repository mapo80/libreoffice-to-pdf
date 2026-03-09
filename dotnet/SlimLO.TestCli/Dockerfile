FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY SlimLO.TestCli.csproj .
RUN dotnet restore
COPY Program.cs .
RUN dotnet publish -c Release --self-contained false -o /app

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    libfontconfig1 libfreetype6 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app .
COPY test.docx .

RUN ldd program/slimlo_worker || true
RUN LD_LIBRARY_PATH=/app/program ldd program/libmergedlo.so 2>&1 | grep "not found" || echo "All deps OK"

ENTRYPOINT ["dotnet", "SlimLO.TestCli.dll", "test.docx"]
