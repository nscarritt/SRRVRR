@echo off
rem Double-click to stop SRRVRR: the live or the test version, whichever is running.
rem It closes SRRVRR's window too. Asks for administrator when SRRVRR was started as administrator.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0SRRVRR.ps1" -Stop
