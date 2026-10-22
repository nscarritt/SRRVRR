@echo off
rem Double-click to start. Right-click > "Run as administrator" so other PCs can open the page.
rem Settings live in SRRVRR.config.psd1 (copy SRRVRR.config.example.psd1 to create it).

rem "net session" only succeeds with administrator rights.
net session >nul 2>&1
if %errorlevel% equ 0 (
    echo Loading...
) else (
    echo Loading without Admin Privs...
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0SRRVRR.ps1"
pause
