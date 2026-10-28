@echo off
rem Double-click to start. It asks for administrator, so other PCs can open the page.
rem Say No to run without it (then only this PC can open the page).
rem Settings live in SRRVRR.config.psd1 (copy SRRVRR.config.example.psd1 to create it).

rem "net session" only succeeds with administrator rights.
net session >nul 2>&1
if %errorlevel% equ 0 goto admin
rem "elevated" means this is already the administrator copy, so don't ask again.
if /i "%~1"=="elevated" goto noadmin

rem Open an administrator copy of this file and close this window. A mapped drive letter
rem is swapped for its network path, since administrator windows don't see mapped drives.
set "SRRVRR_BAT=%~f0"
powershell -NoProfile -Command "$p = $env:SRRVRR_BAT; $r = (Get-PSDrive $p.Substring(0,1) -ErrorAction SilentlyContinue).DisplayRoot; if ($r) { $p = $r + $p.Substring(2) }; try { Start-Process -FilePath $p -ArgumentList elevated -Verb RunAs -ErrorAction Stop } catch { exit 1 }"
if %errorlevel% equ 0 exit /b
echo The administrator prompt was declined.

:noadmin
echo Loading without Admin Privs...
goto run

:admin
echo Loading...

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0SRRVRR.ps1"
pause
