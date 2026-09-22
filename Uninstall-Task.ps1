<#
.SYNOPSIS
  卸载校园网自动认证任务
#>

[CmdletBinding()]
param(
  [string]$TaskName = "CampusAutoAuth"
)

#Requires -RunAsAdministrator

Write-Host "`n=== 校园网自动认证 - 卸载 ===" -ForegroundColor Cyan

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

if (-not $task) {
  Write-Host "任务不存在: $TaskName" -ForegroundColor Yellow
  exit 0
}

Write-Host "正在移除任务: $TaskName" -ForegroundColor Yellow
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Host "已移除" -ForegroundColor Green

# 清理临时 XML（如果存在）
$tempXml = Join-Path $env:TEMP "campus_auth_task.xml"
if (Test-Path $tempXml) {
  Remove-Item $tempXml -Force
}

Write-Host "`n=== 卸载完成 ===" -ForegroundColor Green
