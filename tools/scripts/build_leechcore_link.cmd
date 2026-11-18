@echo off
rem All paths are relative to the repository root.
if not defined RX25_ROOT set "RX25_ROOT=%~dp0..\.."
setlocal enabledelayedexpansion
title LeechCore link build (Release x64)
set "OUTDIR=%RX25_ROOT%\outputs\leechcore_build"
set "SLN=%RX25_ROOT%\pcileech-as02-3p\LeechCore\LeechCore.sln"
if not exist "%OUTDIR%" mkdir "%OUTDIR%"

rem Everything below is captured to a file as well, so the evidence survives
rem even if the window is closed.  This script never exits silently.
call :work > "%OUTDIR%\build_console.log" 2>&1
set "RC=%ERRORLEVEL%"

type "%OUTDIR%\build_console.log"
echo.
echo ============================================================
echo  exit=%RC%
echo  console log : %OUTDIR%\build_console.log
echo  msbuild log : %OUTDIR%\link.log   (only if msbuild actually ran)
echo ============================================================
if exist "%RX25_ROOT%\pcileech-as02-3p\LeechCore\files\leechcore.dll" (
  for %%f in ("%RX25_ROOT%\pcileech-as02-3p\LeechCore\files\leechcore.dll") do echo  DLL OK      : %%~f  %%~zf bytes  %%~tf
) else (
  echo  DLL MISSING : the build did not produce leechcore.dll
)
echo.
if /i not "%~1"=="nopause" pause
exit /b %RC%

:work
chcp 65001 >nul
echo ============================================================
echo  Build leechcore.vcxproj  Release ^| x64
echo ============================================================
echo.

if not exist "%SLN%" (
  echo [ERROR] solution not found: %SLN%
  exit /b 2
)
echo solution : %SLN%
echo.

rem Keep the (x86) path in a delayed-expansion variable: expanding it directly
rem inside a parenthesised block injects parentheses into the block structure.
set "PF86=%ProgramFiles(x86)%"

rem Locate MSBuild by walking the Visual Studio install tree.  vswhere is
rem avoided on purpose: its path contains spaces and parentheses, and quoting
rem it inside a for/f backtick expression silently splits the command.
set "MSBUILD="
for /d %%d in ("%ProgramFiles%\Microsoft Visual Studio\*") do (
  for /d %%e in ("%%~d\*") do (
    if not defined MSBUILD if exist "%%~e\MSBuild\Current\Bin\MSBuild.exe" set "MSBUILD=%%~e\MSBuild\Current\Bin\MSBuild.exe"
  )
)
if not defined MSBUILD (
  for /d %%d in ("!PF86!\Microsoft Visual Studio\*") do (
    for /d %%e in ("%%~d\*") do (
      if not defined MSBUILD if exist "%%~e\MSBuild\Current\Bin\MSBuild.exe" set "MSBUILD=%%~e\MSBuild\Current\Bin\MSBuild.exe"
    )
  )
)
if not defined MSBUILD (
  echo [ERROR] MSBuild.exe was not found under Program Files.
  exit /b 3
)
echo msbuild   : !MSBUILD!
echo.

set "EXTRA="
call :build
set "RC=!ERRORLEVEL!"
echo msbuild exit=!RC!

if not "!RC!"=="0" (
  findstr /c:"MSB8020" "%OUTDIR%\link.log" >nul 2>&1
  if not errorlevel 1 (
    rem Ask the install itself which toolsets exist instead of guessing: the
    rem mapping "Visual Studio 2022 -> v143" is not the only naming scheme
    rem (VS 2026 ships v145).
    set "TOOLSET="
    for /d %%v in ("%ProgramFiles%\Microsoft Visual Studio\*") do (
      for /d %%e in ("%%~v\*") do (
        for /d %%m in ("%%~e\MSBuild\Microsoft\VC\*") do (
          for /d %%p in ("%%~m\Platforms\x64\PlatformToolsets\*") do set "TOOLSET=%%~nxp"
        )
      )
    )
    if not defined TOOLSET set "TOOLSET=v145"
    echo.
    echo [INFO] the requested PlatformToolset is not installed here.
    echo [INFO] available toolset detected: !TOOLSET!
    echo [INFO] retrying with PlatformToolset=!TOOLSET!
    set "EXTRA=/p:PlatformToolset=!TOOLSET!"
    call :build
    set "RC=!ERRORLEVEL!"
    echo msbuild exit=!RC!  ^(retry^)
  )
)

echo.
echo ---- link.log tail ----
type "%OUTDIR%\link.log"
echo ---- end ----
exit /b !RC!

:build
"!MSBUILD!" "%SLN%" /t:leechcore /p:Configuration=Release /p:Platform=x64 /p:PostBuildEventUseInBuild=false !EXTRA! /m /v:minimal /nologo > "%OUTDIR%\link.log" 2>&1
exit /b %ERRORLEVEL%
