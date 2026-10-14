@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0offline.ps1" -Action Restore %*
pause
