@echo off
setlocal

where pwsh.exe >nul 2>&1
if not errorlevel 1 goto launch
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" goto installed
echo PowerShell 7.2 or newer is required.
echo Install with: winget install --id Microsoft.PowerShell --exact --source winget
echo Then run this launcher again.
exit /b 1
:installed
"%ProgramFiles%\PowerShell\7\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0ninfer-manager.ps1" %*
exit /b %errorlevel%
:launch
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0ninfer-manager.ps1" %*
exit /b %errorlevel%
