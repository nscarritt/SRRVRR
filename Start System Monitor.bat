@echo off
rem Double-click to start. Right-click > "Run as administrator" so other PCs can open the page.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0SystemMonitor.ps1" -OpenFirewall
pause
