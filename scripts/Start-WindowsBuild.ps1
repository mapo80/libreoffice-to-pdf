# SlimLO Windows Build Launcher (PowerShell)
# Launches MSYS2 MSYS shell and executes the build pipeline

param(
    [switch]$SetupOnly,
    [switch]$BuildOnly,
    [switch]$SkipConfigure,
    [int]$Parallelism = 0,
    [switch]$Aggressive
)

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " SlimLO - Windows Build Launcher" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Detect architecture and find MSYS2
$nativeArch = $env:PROCESSOR_ARCHITECTURE
$isArm64 = $nativeArch -eq "ARM64"

# Search for MSYS2 in order of preference
$msys2Shell = $null
$msys2Paths = @()

if ($isArm64) {
    # ARM64: prefer native ARM64 MSYS2, fallback to x64
    $msys2Paths = @("C:\msys-arm64\msys2_shell.cmd", "C:\msys64\msys2_shell.cmd")
} else {
    $msys2Paths = @("C:\msys64\msys2_shell.cmd")
}

foreach ($path in $msys2Paths) {
    if (Test-Path $path) {
        $msys2Shell = $path
        break
    }
}

if (-not $msys2Shell) {
    Write-Host "ERROR: MSYS2 not found" -ForegroundColor Red
    if ($isArm64) {
        Write-Host "Searched: C:\msys-arm64, C:\msys64" -ForegroundColor Yellow
        Write-Host "Install ARM64 native: https://github.com/msys2/msys2-installer/releases" -ForegroundColor Yellow
    } else {
        Write-Host "Install: winget install --id=MSYS2.MSYS2 -e" -ForegroundColor Yellow
    }
    exit 1
}

$msys2Root = Split-Path -Parent $msys2Shell
Write-Host "OK: MSYS2 found at $msys2Root ($nativeArch)" -ForegroundColor Green
Write-Host ""

# Build command based on parameters
$commands = @()

if (-not $BuildOnly) {
    $commands += "./scripts/setup-windows-msys2.sh"
}

if (-not $SetupOnly) {
    $buildCmd = "./scripts/windows-build.sh"

    if ($Parallelism -gt 0) {
        $buildCmd = "NPROC=$Parallelism $buildCmd"
    }

    if ($Aggressive) {
        $buildCmd = "DOCX_AGGRESSIVE=1 $buildCmd"
    }

    if ($SkipConfigure) {
        $buildCmd = "SKIP_CONFIGURE=1 $buildCmd"
    }

    $commands += $buildCmd
}

$commandStr = $commands -join " && "

Write-Host "Commands to execute:" -ForegroundColor Cyan
foreach ($cmd in $commands) {
    Write-Host "  - $cmd" -ForegroundColor White
}
Write-Host ""

if (-not $SetupOnly) {
    Write-Host "Estimated time:" -ForegroundColor Yellow
    Write-Host "  - Setup: 10-15 minutes" -ForegroundColor Gray
    Write-Host "  - Build: 2-4 hours (x64), 3-5 hours (ARM64)" -ForegroundColor Gray
    Write-Host "  - Total: 3-6 hours" -ForegroundColor Gray
    Write-Host ""
}

$response = Read-Host "Continue? (y/n)"
if ($response -ne 'y') {
    Write-Host "Cancelled by user" -ForegroundColor Yellow
    exit 0
}

Write-Host ""

# Load MSVC environment BEFORE launching MSYS2
# (vcvarsall.bat cannot be reliably called from inside MSYS2 bash)
if (-not $SetupOnly -and -not $env:INCLUDE) {
    Write-Host "Loading MSVC environment..." -ForegroundColor Cyan
    $vswhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
    $vsPath = & $vswhere -products * -latest -property installationPath 2>$null
    if ($vsPath) {
        # MSYS2 (even on ARM64 Windows) runs under x64 emulation,
        # so uname -m reports x86_64 and LO configure detects x86_64.
        # We must use vcvarsall x64 to match, producing an x64 build
        # that runs on ARM64 via Windows Prism emulation.
        $vcvarsArch = "x64"
        $vcvarsall = Join-Path $vsPath "VC\Auxiliary\Build\vcvarsall.bat"
        if (Test-Path $vcvarsall) {
            # Run vcvarsall.bat and capture env vars
            $envBefore = @{}
            cmd /c "`"$vcvarsall`" $vcvarsArch >nul 2>&1 && set" | ForEach-Object {
                if ($_ -match '^([^=]+)=(.*)$') {
                    $envBefore[$matches[1]] = $matches[2]
                }
            }
            # Export key MSVC variables
            $msvcVars = @('INCLUDE', 'LIB', 'LIBPATH', 'WindowsSdkDir', 'WindowsSdkVersion',
                          'UCRTVersion', 'VCTOOLSINSTALLDIR', 'UniversalCRTSdkDir',
                          'VisualStudioVersion', 'VSCMD_ARG_TGT_ARCH', 'Path')
            foreach ($var in $msvcVars) {
                if ($envBefore.ContainsKey($var)) {
                    [Environment]::SetEnvironmentVariable($var, $envBefore[$var], 'Process')
                }
            }
            Write-Host "OK: MSVC $vcvarsArch environment loaded" -ForegroundColor Green
            Write-Host "  INCLUDE=$($env:INCLUDE.Substring(0, [Math]::Min(80, $env:INCLUDE.Length)))..." -ForegroundColor Gray
            Write-Host "  WindowsSdkVersion=$env:WindowsSdkVersion" -ForegroundColor Gray
        } else {
            Write-Host "WARNING: vcvarsall.bat not found at $vcvarsall" -ForegroundColor Yellow
        }
    } else {
        Write-Host "WARNING: Visual Studio not found via vswhere" -ForegroundColor Yellow
    }
    Write-Host ""
}

Write-Host "Launching MSYS2 MSYS shell..." -ForegroundColor Cyan
Write-Host ""

# Launch MSYS2 MSYS shell (inherits INCLUDE, LIB, etc. from this process)
$currentDir = Get-Location
& $msys2Shell -msys -defterm -no-start -here -c "cd '$currentDir' && $commandStr"

$exitCode = $LASTEXITCODE

Write-Host ""
if ($exitCode -eq 0) {
    Write-Host "============================================" -ForegroundColor Green
    Write-Host " Build completed successfully!" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Output artifacts: .\output\" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "  1. Verify build: ls -lh output/program/" -ForegroundColor White
    Write-Host "  2. Check architecture: dumpbin /headers output\program\mergedlo.dll | findstr machine" -ForegroundColor White
    Write-Host "  3. Run tests: See WINDOWS-BUILD-QUICKSTART.md" -ForegroundColor White
} else {
    Write-Host "============================================" -ForegroundColor Red
    Write-Host " Build failed with exit code: $exitCode" -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "Troubleshooting:" -ForegroundColor Yellow
    Write-Host "  - Check errors above" -ForegroundColor White
    Write-Host "  - See WINDOWS-BUILD-QUICKSTART.md for common issues" -ForegroundColor White
    Write-Host "  - Run debug script: ./scripts/windows-debug-harfbuzz.sh" -ForegroundColor White
}

Write-Host ""
exit $exitCode
