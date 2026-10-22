@echo off
rem Double-click to start. Right-click > "Run as administrator" so other PCs can open the page.
rem Settings live in SystemMonitor.config.psd1 (copy SystemMonitor.config.example.psd1 to create it).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0SystemMonitor.ps1"
pause
