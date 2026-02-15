@echo off
REM SlimLO Windows Build Launcher
REM Loads MSVC environment, then launches MSYS2 MSYS shell for the build
REM Supports both ARM64 (C:\msys-arm64) and x64 (C:\msys64) MSYS2

echo ============================================
echo  SlimLO - Windows Build Launcher
echo ============================================
echo.

REM Check for ARM64 MSYS2 first, then x64
set "MSYS2_SHELL="
if exist "C:\msys-arm64\msys2_shell.cmd" (
    set "MSYS2_SHELL=C:\msys-arm64\msys2_shell.cmd"
    echo Found: MSYS2 ARM64 at C:\msys-arm64
) else if exist "C:\msys64\msys2_shell.cmd" (
    set "MSYS2_SHELL=C:\msys64\msys2_shell.cmd"
    echo Found: MSYS2 at C:\msys64
) else (
    echo ERROR: MSYS2 not found at C:\msys-arm64 or C:\msys64
    echo Please install MSYS2 from https://github.com/msys2/msys2-installer/releases
    pause
    exit /b 1
)

REM Find and load MSVC environment via vcvarsall.bat
echo.
echo Loading MSVC environment...
set "VSWHERE=C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "delims=" %%i in ('"%VSWHERE%" -products * -latest -property installationPath 2^>nul') do set "VS_PATH=%%i"

if not defined VS_PATH (
    echo ERROR: Visual Studio not found
    pause
    exit /b 1
)

set "VCVARSALL=%VS_PATH%\VC\Auxiliary\Build\vcvarsall.bat"
if not exist "%VCVARSALL%" (
    echo ERROR: vcvarsall.bat not found at %VCVARSALL%
    pause
    exit /b 1
)

REM MSYS2 runs under x64 emulation even on ARM64, so LO configure
REM detects x86_64. Use vcvarsall x64 to match.
set "VCARCH=x64"

call "%VCVARSALL%" %VCARCH% >nul 2>&1
if errorlevel 1 (
    echo ERROR: vcvarsall.bat failed
    pause
    exit /b 1
)
echo OK: MSVC %VCARCH% environment loaded

echo.
echo This will:
echo   1. Run setup-windows-msys2.sh (install dependencies)
echo   2. Run windows-build.sh (build LibreOffice, ~2-4 hours)
echo.
echo Press Ctrl+C to cancel, or
pause

REM Launch MSYS2 MSYS shell with build commands
REM INCLUDE, LIB, etc. are inherited from this process
%MSYS2_SHELL% -msys -defterm -no-start -here -c "cd '%CD%' && ./scripts/setup-windows-msys2.sh && ./scripts/windows-build.sh"

echo.
echo Build process completed.
echo Check output above for any errors.
pause
