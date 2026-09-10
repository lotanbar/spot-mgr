@echo off
setlocal
pushd "%~dp0"

where pwsh.exe >nul 2>&1
if %errorlevel% equ 0 (
    set "POWERSHELL_EXE=pwsh.exe"
) else (
    set "POWERSHELL_EXE=powershell.exe"
)

echo Building spot-mgr.exe...
"%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference = 'Stop'; $source = Join-Path $PWD 'spot-mgr.ps1'; $output = Join-Path $PWD 'spot-mgr.exe'; $temporaryOutput = Join-Path $PWD 'spot-mgr.build.exe'; if (-not (Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue)) { Write-Host 'Installing ps2exe...'; Install-Module ps2exe -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -ErrorAction Stop }; Remove-Item $temporaryOutput -Force -ErrorAction SilentlyContinue; Invoke-ps2exe -inputFile $source -outputFile $temporaryOutput -noConsole -title 'spot-mgr' -description 'Fixes and manages Windows Spotlight images' -ErrorAction Stop; if (-not (Test-Path $temporaryOutput)) { throw 'PS2EXE did not create an output file.' }; Move-Item $temporaryOutput $output -Force -ErrorAction Stop"
set "BUILD_EXIT=%errorlevel%"

if not "%BUILD_EXIT%"=="0" (
    echo Build failed.
    popd
    exit /b %BUILD_EXIT%
)

echo Built %CD%\spot-mgr.exe
popd
exit /b 0
