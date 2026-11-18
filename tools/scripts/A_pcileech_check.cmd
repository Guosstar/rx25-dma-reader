@echo off
rem All paths are relative to the repository root.
if not defined RX25_ROOT set "RX25_ROOT=%~dp0..\.."
setlocal enabledelayedexpansion
title RX25: PCILeech upper-layer integration check
net session >nul 2>&1
if errorlevel 1 (
    echo.
    echo   NOT elevated.  Right-click this file, "Run as administrator".
    echo.
    pause
    exit /b 1
)
set "HERE=%~dp0"
set "PY=python"
if not exist "%PY%" set "PY=python"
set "LOGDIR=%RX25_ROOT%\outputs\pcileech_check"
set "LOGF=%LOGDIR%\pcileech_check.log"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"

chcp 65001 >nul
"%PY%" "%HERE%pcileech_check.py" > "%LOGF%" 2>&1
set "RC=!ERRORLEVEL!"
type "%LOGF%"
echo.
echo ============================================================
echo  exit=!RC!
echo  log =%LOGF%
echo ============================================================
pause
exit /b !RC!
