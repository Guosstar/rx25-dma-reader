@echo off
rem All paths are relative to the repository root.
if not defined RX25_ROOT set "RX25_ROOT=%~dp0..\.."
setlocal enabledelayedexpansion
title RX25 rebuild + LeechCore backend test
net session >nul 2>&1
if errorlevel 1 (
  echo [ERROR] not elevated. Close this and use "Run as administrator".
  pause
  exit /b 5
)
set "HERE=%~dp0"
set "PY=python"
if not exist "%PY%" set "PY=python"
set "LOGDIR=%RX25_ROOT%\outputs\leechcore_build"
set "LCLOG=%LOGDIR%\lc_test.log"
set "DLL=%RX25_ROOT%\pcileech-as02-3p\LeechCore\files\leechcore.dll"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"

echo ============================================================
echo  Stage 1/2  rebuild leechcore.dll (Release x64)
echo ============================================================
call "%HERE%build_leechcore_link.cmd" nopause
set "RC1=!ERRORLEVEL!"
echo.
echo [stage 1 exit=!RC1!]
echo.

if not "!RC1!"=="0" (
  echo [ABORT] the dll was not rebuilt; the test would run stale code.
  pause
  exit /b !RC1!
)

echo ============================================================
echo  Stage 2/2  LeechCore backend test
echo ============================================================
chcp 65001 >nul
"%PY%" "%HERE%lc_rx25_test.py" --long 200 > "%LCLOG%" 2>&1
set "RC2=!ERRORLEVEL!"
type "%LCLOG%"
echo.
echo [stage 2 exit=!RC2!  log=%LCLOG%]
echo.
echo ============================================================
echo  SUMMARY
echo    rebuild        : exit=!RC1!
echo    LeechCore test : exit=!RC2!   ^(0 = pass^)
echo ============================================================
pause
exit /b !RC2!
