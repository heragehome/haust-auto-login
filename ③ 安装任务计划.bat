@echo off
title 校园网认证 - 安装任务计划
cd /d "%~dp0"

REM 自请求管理员权限
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo 正在请求管理员权限，请在弹窗中点"是"...
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Install-Task.ps1"
echo.
pause
