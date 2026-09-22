@echo off
title 校园网认证 - 立即认证
cd /d "%~dp0"
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "CampusAuth.ps1"
echo.
pause
