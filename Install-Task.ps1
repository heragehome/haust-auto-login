<#
.SYNOPSIS
  安装校园网自动认证到 Windows 任务计划程序

.DESCRIPTION
  注册三个触发器：
    1. 用户登录时
    2. 网络变更时（NetworkProfile 事件ID 10000，XML 自动注入）
    3. 每 10 分钟轮询（兜底）

  运行方式：以当前用户身份运行，无窗口（隐藏）

.NOTES
  需要管理员权限
#>

[CmdletBinding()]
param(
  # 注意：PS 5.1 的 param() 默认值阶段 $PSScriptRoot 还未就绪，留空在脚本体内解析
  [string]$ScriptPath = "",
  [string]$ConfigPath = "",
  [string]$TaskName = "CampusAutoAuth",
  [int]$PollIntervalMin = 10
)

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

# 解析默认路径（函数体/脚本体内 $PSScriptRoot 可靠）
if (-not $ScriptPath) { $ScriptPath = Join-Path $PSScriptRoot "CampusAuth.ps1" }
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot "config.json" }

Write-Host "`n=== 校园网自动认证 - 任务计划安装 ===" -ForegroundColor Cyan

# 验证脚本存在
if (-not (Test-Path $ScriptPath)) {
  Write-Host "错误: 找不到主脚本 $ScriptPath" -ForegroundColor Red
  exit 1
}

# 构建 PowerShell 启动命令
# -WindowStyle Hidden: 隐藏窗口
# -NoProfile: 不加载配置文件（提速）
# -ExecutionPolicy Bypass: 绕过执行策略
$fullScript = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -ConfigFile `"$ConfigPath`""

Write-Host "`n配置信息:" -ForegroundColor Yellow
Write-Host "  任务名称: $TaskName"
Write-Host "  脚本路径: $ScriptPath"
Write-Host "  配置路径: $ConfigPath"
Write-Host "  轮询间隔: ${PollIntervalMin} 分钟"
Write-Host ""

# 删除已有任务（如果存在）
$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask) {
  Write-Host "已存在同名任务，正在移除..." -ForegroundColor Yellow
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

# 动作
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $fullScript

# 触发器
$triggers = @()

# 1. 用户登录时
$triggerLogon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$triggers += $triggerLogon
Write-Host "  [✓] 触发器1: 用户登录时" -ForegroundColor Green

# 2. 定时轮询（兜底）
$triggerPoll = New-ScheduledTaskTrigger -Once -At (Get-Date) `
  -RepetitionInterval (New-TimeSpan -Minutes $PollIntervalMin) `
  -RepetitionDuration ([TimeSpan]::MaxValue)
$triggers += $triggerPoll
Write-Host "  [✓] 触发器2: 每 ${PollIntervalMin} 分钟轮询" -ForegroundColor Green

# 设置
$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -StartWhenAvailable `
  -RestartCount 3 `
  -RestartInterval (New-TimeSpan -Minutes 2) `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
  -MultipleInstances IgnoreNew

# 主体（当前用户，最高权限）
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest

# 注册
try {
  Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $triggers `
    -Settings $settings `
    -Principal $principal `
    -Description "校园网自动认证 - 探测并自动登录" `
    -Force | Out-Null

  Write-Host "`n正在注入网络变更事件触发器..." -ForegroundColor Yellow

  # 导出任务 XML，注入 EventTrigger（网络连接事件 ID 10000），再重新注册
  $xmlPath = Join-Path $env:TEMP "campus_auth_task.xml"
  Export-ScheduledTask -TaskName $TaskName | Out-File $xmlPath -Encoding Unicode

  $xml = Get-Content $xmlPath -Raw

  # Task Scheduler XML 中 <Subscription> 内是转义后的 XML 查询文本
  $subscription = [System.Security.SecurityElement]::Escape(
    '<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"><Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[(EventID=10000)]]</Select></Query></QueryList>'
  )

  $eventTrigger = @"
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>$subscription</Subscription>
    </EventTrigger>
"@

  if ($xml -match '</Triggers>') {
    $xml = $xml -replace '</Triggers>', "$eventTrigger</Triggers>"
    $xml | Out-File $xmlPath -Encoding Unicode

    # 用修改后的 XML 重新注册（保留 Principals/Settings）
    Register-ScheduledTask -TaskName $TaskName -Xml (Get-Content $xmlPath -Raw) -Force | Out-Null
    Write-Host "  [✓] 触发器3: 网络变更事件（NetworkProfile EventID 10000）" -ForegroundColor Green
  } else {
    Write-Host "  [!] XML 注入失败，仅保留前两个触发器（功能不受影响）" -ForegroundColor Yellow
  }

  Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue

  Write-Host "`n=== 安装成功 ===" -ForegroundColor Green
  Write-Host "任务已注册: $TaskName" -ForegroundColor Green
  Write-Host "`n管理命令:" -ForegroundColor Cyan
  Write-Host "  立即运行:  Start-ScheduledTask -TaskName '$TaskName'"
  Write-Host "  查看状态:  Get-ScheduledTask -TaskName '$TaskName' | Get-ScheduledTaskInfo"
  Write-Host "  下线本机:  powershell -File '$ScriptPath' -Logout"
  Write-Host ""
} catch {
  Write-Host "`n注册失败: $_" -ForegroundColor Red
  exit 1
}
