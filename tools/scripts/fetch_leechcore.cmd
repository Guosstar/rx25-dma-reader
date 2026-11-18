@echo off
rem Fetch upstream LeechCore and apply the RX25 overlay.
rem
rem LeechCore is NOT vendored in this repository: upstream is GPL-3.0 and the
rem part this project actually changes is small.  This script clones upstream
rem once into third_party\LeechCore (git-ignored) and copies the overlay from
rem host\leechcore\ over it, which is the state the build and the tests expect.
rem
rem usage:
rem   tools\scripts\fetch_leechcore.cmd            clone into third_party\LeechCore
rem   set LEECHCORE_ROOT=D:\src\LeechCore ^&^& tools\scripts\fetch_leechcore.cmd
rem
rem Re-running is safe: an existing checkout is reused and only the overlay is
rem re-applied, so a stale edit in LeechCore\leechcore\ gets reset.
setlocal enabledelayedexpansion
if not defined RX25_ROOT set "RX25_ROOT=%~dp0..\.."
if not defined LEECHCORE_ROOT set "LEECHCORE_ROOT=%RX25_ROOT%\third_party\LeechCore"
set "OVERLAY=%RX25_ROOT%\host\leechcore"

echo ============================================================
echo  Fetch LeechCore + apply RX25 overlay
echo ============================================================
echo  target  : %LEECHCORE_ROOT%
echo  overlay : %OVERLAY%
echo.

if not exist "%OVERLAY%\leechcore.c" (
  echo [ERROR] overlay sources missing: %OVERLAY%
  exit /b 2
)

if exist "%LEECHCORE_ROOT%\LeechCore.sln" (
  echo [1/2] existing checkout found, skipping clone
) else (
  echo [1/2] cloning https://github.com/ufrisk/LeechCore
  where git >nul 2>&1
  if errorlevel 1 (
    echo [ERROR] git is not on PATH.  Install Git for Windows, or clone
    echo         https://github.com/ufrisk/LeechCore yourself and set
    echo         LEECHCORE_ROOT to the result before re-running this script.
    exit /b 3
  )
  for %%d in ("%LEECHCORE_ROOT%") do if not exist "%%~dpd" mkdir "%%~dpd" 2>nul
  git clone --depth 1 https://github.com/ufrisk/LeechCore "%LEECHCORE_ROOT%"
  if errorlevel 1 (
    echo [ERROR] git clone failed.  If this host cannot reach GitHub, clone
    echo         elsewhere and point LEECHCORE_ROOT at it.
    exit /b 4
  )
)

if not exist "%LEECHCORE_ROOT%\leechcore" (
  echo [ERROR] unexpected layout: no leechcore\ directory under target
  exit /b 5
)

echo.
echo [2/2] applying overlay into %LEECHCORE_ROOT%\leechcore
for %%f in ("%OVERLAY%\*.c" "%OVERLAY%\*.h") do (
  copy /y "%%~f" "%LEECHCORE_ROOT%\leechcore\" >nul
  echo   + %%~nxf
)

echo.
echo ============================================================
echo  done.  next:
echo    tools\scripts\build_leechcore_link.cmd
echo  output lands in %LEECHCORE_ROOT%\files\leechcore.dll
echo ============================================================
if /i not "%~1"=="nopause" pause
endlocal
