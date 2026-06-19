@echo off
setlocal
set "ASTRID_DIR=%~dp0"

where pwsh.exe >nul 2>nul
if %ERRORLEVEL% EQU 0 (
  pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%ASTRID_DIR%AstridUpdater.ps1" -InstallDirectory "%ASTRID_DIR%"
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ASTRID_DIR%AstridUpdater.ps1" -InstallDirectory "%ASTRID_DIR%"
)

echo.
pause
