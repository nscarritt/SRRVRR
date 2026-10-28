@echo off
rem Double-click to set up CPU and memory temperatures (see the README). Close SRRVRR first.
rem It asks for administrator, and the window stays open so you can read what happened.

rem "net session" only succeeds with administrator rights.
net session >nul 2>&1
if %errorlevel% equ 0 goto run
rem "elevated" means this is already the administrator copy, so don't ask again.
if /i "%~1"=="elevated" goto run

rem Open an administrator copy of this file and close this window. A mapped drive letter
rem is swapped for its network path, since administrator windows don't see mapped drives.
set "SRRVRR_BAT=%~f0"
powershell -NoProfile -Command "$p = $env:SRRVRR_BAT; $r = (Get-PSDrive $p.Substring(0,1) -ErrorAction SilentlyContinue).DisplayRoot; if ($r) { $p = $r + $p.Substring(2) }; try { Start-Process -FilePath $p -ArgumentList elevated -Verb RunAs -ErrorAction Stop } catch { exit 1 }"
if %errorlevel% equ 0 exit /b
echo Nothing was installed: the administrator prompt was declined.
pause
exit /b 1

:run
echo SRRVRR temperature sensors setup
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-TemperatureSensors.ps1" -NoPause
pause
