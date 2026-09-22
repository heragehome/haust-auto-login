@echo off
title 校园网认证 - DryRun 安全测试
cd /d "%~dp0"
echo.
echo  当前文件夹内容（远程诊断用）:
dir /b
echo.
echo  正在进行 DryRun 测试（只探测，不实际登录）...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "CampusAuth.ps1" -DryRun
echo.
echo ================================
echo  测试结束，请把整个窗口截图发给助手核对
pause
