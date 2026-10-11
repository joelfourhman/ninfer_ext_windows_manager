@echo off
setlocal

where pwsh.exe >nul 2>&1
if errorlevel 1 (
    echo PowerShell 7 is required. Install it with:
    echo winget install --id Microsoft.PowerShell --exact
    exit /b 1
)

pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0ninfer-manager.ps1" %*
exit /b %errorlevel%
