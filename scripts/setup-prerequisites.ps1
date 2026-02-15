# SlimLO Windows Build - Prerequisites Setup Script
# Automates installation of MSYS2 and Python for Windows build

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " SlimLO - Windows Prerequisites Setup" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Detect native architecture
$nativeArch = $env:PROCESSOR_ARCHITECTURE
$isArm64 = $nativeArch -eq "ARM64"
Write-Host "Native architecture: $nativeArch" -ForegroundColor White
Write-Host ""

# Check if running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "WARNING: Not running as Administrator" -ForegroundColor Yellow
    Write-Host "   Some installations may require elevated privileges" -ForegroundColor Yellow
    Write-Host ""
}

# Check if winget is available
$wingetAvailable = Get-Command winget -ErrorAction SilentlyContinue
if (-not $wingetAvailable) {
    Write-Host "ERROR: winget not found. Install it from Microsoft Store: App Installer" -ForegroundColor Red
    Write-Host "   Or download packages manually:" -ForegroundColor Yellow
    Write-Host "   - MSYS2: https://github.com/msys2/msys2-installer/releases" -ForegroundColor Yellow
    Write-Host "   - Python: https://www.python.org/downloads/windows/" -ForegroundColor Yellow
    exit 1
}

Write-Host "OK: winget found" -ForegroundColor Green
Write-Host ""

# Check MSYS2
Write-Host ">>> Checking MSYS2..." -ForegroundColor Cyan

if ($isArm64) {
    # ARM64: prefer native ARM64 MSYS2 installer
    $msys2Found = $false

    # Check ARM64 path first
    if (Test-Path "C:\msys-arm64\msys2.exe") {
        Write-Host "OK: MSYS2 ARM64 (native) installed at C:\msys-arm64" -ForegroundColor Green
        $msys2Found = $true
    } elseif (Test-Path "C:\msys64\msys2.exe") {
        # Check if it's ARM64 or x64
        $msys2Exe = "C:\msys64\usr\bin\bash.exe"
        if (Test-Path $msys2Exe) {
            $peHeader = [System.IO.File]::ReadAllBytes($msys2Exe)
            $peOffset = [BitConverter]::ToInt32($peHeader, 0x3C)
            $machineType = [BitConverter]::ToUInt16($peHeader, $peOffset + 4)
            if ($machineType -eq 0xAA64) {
                Write-Host "OK: MSYS2 ARM64 (native) installed at C:\msys64" -ForegroundColor Green
                $msys2Found = $true
            } else {
                Write-Host "WARNING: MSYS2 found at C:\msys64 but it's x64 (emulated)" -ForegroundColor Yellow
                Write-Host "   For best performance, install MSYS2 ARM64 to C:\msys-arm64" -ForegroundColor Yellow
                $msys2Found = $true
            }
        } else {
            Write-Host "OK: MSYS2 found at C:\msys64" -ForegroundColor Green
            $msys2Found = $true
        }
    }

    if (-not $msys2Found) {
        Write-Host "MSYS2 not found" -ForegroundColor Red
        Write-Host ""
        Write-Host "For ARM64 Windows, download the ARM64 native installer:" -ForegroundColor Yellow
        Write-Host "   https://github.com/msys2/msys2-installer/releases" -ForegroundColor White
        Write-Host "   File: msys2-arm64-yyyymmdd.exe" -ForegroundColor White
        Write-Host "   Install to: C:\msys-arm64" -ForegroundColor White
        Write-Host ""
        $installMsys2 = Read-Host "Try installing via winget (x64 version)? (y/n)"
        if ($installMsys2 -eq 'y') {
            Write-Host "Installing MSYS2 (x64)..." -ForegroundColor Yellow
            Write-Host "NOTE: For ARM64 native, manually download from GitHub releases instead" -ForegroundColor Yellow
            winget install --id=MSYS2.MSYS2 -e --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -eq 0) {
                Write-Host "OK: MSYS2 (x64) installed successfully" -ForegroundColor Green
            } else {
                Write-Host "ERROR: MSYS2 installation failed" -ForegroundColor Red
            }
        }
    }
} else {
    # x64: standard MSYS2
    if (Test-Path "C:\msys64\msys2.exe") {
        Write-Host "OK: MSYS2 already installed at C:\msys64" -ForegroundColor Green
    } else {
        Write-Host "MSYS2 not found" -ForegroundColor Red
        $installMsys2 = Read-Host "Install MSYS2? (y/n)"
        if ($installMsys2 -eq 'y') {
            Write-Host "Installing MSYS2..." -ForegroundColor Yellow
            winget install --id=MSYS2.MSYS2 -e --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -eq 0) {
                Write-Host "OK: MSYS2 installed successfully" -ForegroundColor Green
            } else {
                Write-Host "ERROR: MSYS2 installation failed" -ForegroundColor Red
            }
        }
    }
}
Write-Host ""

# Check Python
Write-Host ">>> Checking Python..." -ForegroundColor Cyan
$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
if ($pythonCmd) {
    $pythonPath = $pythonCmd.Source
    $pythonVersion = & python --version 2>&1

    # Check if it's Microsoft Store Python (bad)
    if ($pythonPath -like "*WindowsApps*") {
        Write-Host "WARNING: Python found but it's Microsoft Store version (not compatible)" -ForegroundColor Yellow
        Write-Host "   Path: $pythonPath" -ForegroundColor Yellow
        Write-Host "   You need to install Python from python.org" -ForegroundColor Yellow
        $installPython = Read-Host "Install Python from python.org? (y/n)"
        if ($installPython -eq 'y') {
            Write-Host "Installing Python 3.12..." -ForegroundColor Yellow
            winget install --id=Python.Python.3.12 -e --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -eq 0) {
                Write-Host "OK: Python installed successfully" -ForegroundColor Green
                Write-Host "WARNING: You may need to restart your terminal for PATH changes to take effect" -ForegroundColor Yellow
            } else {
                Write-Host "ERROR: Python installation failed" -ForegroundColor Red
            }
        }
    } else {
        Write-Host "OK: Python already installed: $pythonVersion" -ForegroundColor Green
        Write-Host "  Path: $pythonPath" -ForegroundColor Gray
    }
} else {
    Write-Host "Python not found" -ForegroundColor Red
    $installPython = Read-Host "Install Python 3.12? (y/n)"
    if ($installPython -eq 'y') {
        Write-Host "Installing Python 3.12..." -ForegroundColor Yellow
        winget install --id=Python.Python.3.12 -e --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -eq 0) {
            Write-Host "OK: Python installed successfully" -ForegroundColor Green
            Write-Host "WARNING: You may need to restart your terminal for PATH changes to take effect" -ForegroundColor Yellow
        } else {
            Write-Host "ERROR: Python installation failed" -ForegroundColor Red
        }
    }
}
Write-Host ""

# Check Visual Studio
Write-Host ">>> Checking Visual Studio..." -ForegroundColor Cyan
$vswhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    $vsInstances = & $vswhere -latest -format json | ConvertFrom-Json
    if ($vsInstances) {
        Write-Host "OK: Visual Studio 2022 found" -ForegroundColor Green
        Write-Host "  Version: $($vsInstances.installationVersion)" -ForegroundColor Gray
        Write-Host "  Path: $($vsInstances.installationPath)" -ForegroundColor Gray

        # Check for ARM64 build tools if on ARM64
        if ($isArm64) {
            $vsPath = $vsInstances.installationPath
            $arm64Tools = Get-ChildItem -Path "$vsPath\VC\Tools\MSVC\*\bin\HostARM64" -ErrorAction SilentlyContinue
            if ($arm64Tools) {
                Write-Host "  OK: ARM64 native build tools found" -ForegroundColor Green
            } else {
                Write-Host "  WARNING: ARM64 native build tools not found" -ForegroundColor Yellow
                Write-Host "  Install via VS Installer: MSVC v143 ARM64 build tools" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "WARNING: Visual Studio found but no instances detected" -ForegroundColor Yellow
    }
} else {
    Write-Host "ERROR: Visual Studio 2022 not found" -ForegroundColor Red
    Write-Host "   Download from: https://visualstudio.microsoft.com/downloads/" -ForegroundColor Yellow
    Write-Host "   Required workload: Desktop development with C++" -ForegroundColor Yellow
    if ($isArm64) {
        Write-Host "   Required component: MSVC v143 ARM64 build tools" -ForegroundColor Yellow
    }
}
Write-Host ""

# Summary
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Summary" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Architecture: $nativeArch" -ForegroundColor White

if ($isArm64) {
    Write-Host ""
    Write-Host "ARM64 Notes:" -ForegroundColor Yellow
    Write-Host "  - NASM is NOT required (x86 SIMD only)" -ForegroundColor Gray
    Write-Host "  - For best performance, use MSYS2 ARM64 native installer:" -ForegroundColor Gray
    Write-Host "    https://github.com/msys2/msys2-installer/releases" -ForegroundColor White
    Write-Host "    Download: msys2-aarch64-latest.exe" -ForegroundColor White
}

Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host "  1. If you installed new software, restart your terminal" -ForegroundColor Yellow
Write-Host "  2. Open MSYS2 MSYS shell (Start Menu -> MSYS2 -> MSYS2 MSYS)" -ForegroundColor Yellow
Write-Host "  3. Navigate to repository:" -ForegroundColor Yellow
Write-Host "     cd /c/Users/matte/Documents/workspace/personal/libreoffice-to-pdf" -ForegroundColor White
Write-Host "  4. Run MSYS2 setup:" -ForegroundColor Yellow
Write-Host "     ./scripts/setup-windows-msys2.sh" -ForegroundColor White
Write-Host "  5. Run build:" -ForegroundColor Yellow
Write-Host "     ./scripts/windows-build.sh" -ForegroundColor White
Write-Host ""
