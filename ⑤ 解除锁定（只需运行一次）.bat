@echo off
title 校园网认证 - 解除锁定
cd /d "%~dp0"
echo.
echo  正在解除本文件夹所有文件的"网络下载"标记...
echo  （解决每次运行都弹"打开文件-安全警告"的问题）
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse -File | Unblock-File"
echo.
echo  完成！以后双击 ①②③④ 不会再弹授权提醒。
echo  （刚才运行本文件时弹的那次提醒，是最后一次）
pause
