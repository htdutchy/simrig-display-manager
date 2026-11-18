@echo off
setlocal
set "SCRIPT=%~dp0VideoInfo-Menu.ps1"
if not exist "%SCRIPT%" (
    echo Could not find VideoInfo-Menu.ps1 next to this launcher.
    pause
    exit /b 1
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
if errorlevel 1 (
    echo.
    echo Display Manager exited with an error.
    pause
)
