@echo off
chcp 65001 >nul
title INVAXION - Offline Autoplay Debug
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0offline.ps1" -Action Launch -Autoplay -LiveLog %*
set "INVAXION_EXIT_CODE=%ERRORLEVEL%"
pause
exit /b %INVAXION_EXIT_CODE%
