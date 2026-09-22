@echo off
title 校园网认证 - 下线本机
cd /d "%~dp0"
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "CampusAuth.ps1" -Logout
echo.
pause
