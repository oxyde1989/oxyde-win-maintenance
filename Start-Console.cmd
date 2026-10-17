@echo off
rem oxyde-win-maintenance console launcher - double-click to open the GUI (no install needed).
setlocal
cd /d "%~dp0"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0PcConsole.ps1"
endlocal
