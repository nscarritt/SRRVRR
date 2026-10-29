@echo off
rem Double-click to stop the SRRVRR in this folder: it saves and closes cleanly (forced after 10 seconds).
rem It closes SRRVRR's window too. Asks for administrator when SRRVRR was started as administrator.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0SRRVRR.ps1" -Stop
