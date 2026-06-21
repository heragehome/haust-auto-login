#Requires -Version 5.1
<#
.SYNOPSIS
    河南科大校园网 ePortal 自动认证脚本（锐捷V4/V5）（仅限个人学习与研究使用）
.DESCRIPTION
    检测网络状态，掉线时自动登录。无后台驻留，由任务计划程序触发。
    免责声明：使用本脚本所产生的一切后果由使用者自行承担，作者不承担任何责任。
    禁止用于任何违反校园网管理规定的用途。
.NOTES
    配置文件: 同目录 config.json
    日志文件: 同目录 netlogin.log
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

# ── 路径初始化 ──
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$CfgPath   = Join-Path $ScriptDir 'config.json'
$LogPath   = Join-Path $ScriptDir 'netlogin.log'

# ── 日志轮转: 超过 1MB 时保留 1 个备份 ──
try {
    if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 1MB)) {
        $bakPath = "$LogPath.bak"
        if (Test-Path $bakPath) { Remove-Item $bakPath -Force }
        Rename-Item $LogPath $bakPath -Force
    }
} catch {}

function Write-Log {
    param([string]$Status, [string]$IP, [string]$ISP, [string]$Msg)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$ts [$Status] $IP $ISP $Msg"
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
    Write-Output $line
}

# ── 步骤 A: 获取本机 IPv4 ──
function Get-LocalIPv4 {
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
                 Sort-Object RouteMetric, InterfaceMetric |
                 Select-Object -First 1
        if ($route) {
            $ip = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex `
                  -AddressFamily IPv4 -ErrorAction Stop |
                  Where-Object { $_.AddressState -eq 'Preferred' } |
                  Select-Object -First 1
            if ($ip) { return $ip.IPAddress }
        }
    } catch {}
    try {
        return (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.AddressState -eq 'Preferred' } |
                Select-Object -First 1).IPAddress
    } catch { return $null }
}

# ── 步骤 B: 网络状态探测 ──
function Test-NetworkStatus {
    param([int]$MaxRetries = 2, [int]$RetryDelaySec = 2)

    $edgeUA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0'

    # 主探测 URL（域名，系统自动选择 v6/v4）
    $primaryUrl  = 'http://edge.microsoft.com/captiveportal/generate_204'

    # 备用 IPv4 固定地址列表（原逻辑）
    $ipv4List = @('150.171.27.11', '150.171.28.11')
    $hostHeader = 'edge.microsoft.com'
    $uriPath = '/captiveportal/generate_204'

    # 封装探测逻辑为子函数，便于复用
    # 参数：$uri 为完整 URL（含 http://），$hostOverride 若指定则设置 Host 头
    function Invoke-UrlProbe {
        param([string]$Uri, [string]$HostOverride)
        $headers = @{
            'User-Agent'   = $edgeUA
            'Cache-Control'= 'no-cache'
            'Pragma'       = 'no-cache'
        }
        if ($HostOverride) {
            $headers['Host'] = $HostOverride
        }

        # 尝试 HEAD
        try {
            $resp = Invoke-WebRequest -Uri $Uri -Method Head -Headers $headers `
                    -MaximumRedirection 0 -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
            if ($resp.StatusCode -eq 204) { return 'online' }
            if ($resp.StatusCode -eq 302) {
                $loc = $resp.Headers['Location']
                if ($loc -match 'wlan\.haust\.edu\.cn') { return 'offline' }
                if ($loc) { return 'offline' }
            }
        } catch {
            $ex = $_.Exception
            if ($ex.Response) {
                $code = [int]$ex.Response.StatusCode
                if ($code -eq 302) {
                    $loc = $ex.Response.Headers['Location']
                    if ($loc -match 'wlan\.haust\.edu\.cn') { return 'offline' }
                    if ($loc) { return 'offline' }
                }
            }
            # 其他异常（如连接重置、超时）会向上抛出，由外层捕获
            throw
        }

        # HEAD 未得出确定结论，再 GET
        try {
            $resp2 = Invoke-WebRequest -Uri $Uri -Method Get -Headers $headers `
                     -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
            if ($resp2.StatusCode -eq 200) {
                $body = $resp2.Content
                if ($body.Length -gt 10240) { $body = $body.Substring(0, 10240) }
                if ($body -match 'wlan\.haust\.edu\.cn|a79\.htm') { return 'offline' }
                if ($body.Length -lt 100) { return 'suspicious' }
                return 'online'
            }
        } catch {
            throw
        }
        # 理论上不会走到这里
        return 'unreachable'
    }

    # 主重试循环
    $attempt = 0
    while ($attempt -le $MaxRetries) {
        if ($attempt -gt 0) { Start-Sleep -Seconds $RetryDelaySec }

        # ── 优先：通过域名探测（系统自动选地址族） ──
        try {
            return Invoke-UrlProbe -Uri $primaryUrl
        } catch {
            # 记录一次 IPv6/域名探测失败，继续后续备用方案
            $primaryError = $_.Exception.Message
        }

        # ── 备用：逐个固定 IPv4 地址探测 ──
        foreach ($ip in $ipv4List) {
            try {
                $uri = "http://${ip}${uriPath}"
                return Invoke-UrlProbe -Uri $uri -HostOverride $hostHeader
            } catch {
                # 单个 IPv4 地址失败，继续下一个
            }
        }

        $attempt++
    }

    # 所有尝试均失败
    Write-Log 'PROBE_FAIL' '-' '-' "主探测($primaryUrl)错误：$primaryError；备用 IPv4 列表也全部不可达"
    return 'unreachable'
}

# ── 步骤 C: 读取配置 ──
function Get-LoginConfig {
    if (-not (Test-Path $CfgPath)) {
        throw "配置文件不存在: $CfgPath"
    }
    $cfg = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $cfg.username -or -not $cfg.password -or -not $cfg.isp) {
        throw "config.json 缺少必要字段 (username/password/isp)"
    }
    return $cfg
}

# ── 步骤 D-F: 登录 ──
function Invoke-Login {
    param([string]$IP, [object]$Cfg)

    $user = $Cfg.username
    $pass = $Cfg.password
    $isp  = $Cfg.isp

    $account = [uri]::EscapeDataString(",0,${user}@${isp}")

    $rand = Get-Random -Minimum 1000 -Maximum 9999
    $loginUrl = "https://wlan.haust.edu.cn:802/eportal/portal/login" +
                "?callback=dr1003&login_method=1" +
                "&user_account=$account" +
                "&user_password=$pass" +
                "&wlan_user_ip=$IP" +
                "&wlan_user_ipv6=&wlan_user_mac=000000000000" +
                "&wlan_ac_ip=&wlan_ac_name=" +
                "&jsVersion=4.2.1&terminal_type=1&lang=zh-cn" +
                "&v=$rand&lang=zh"

    try {
        $resp = Invoke-WebRequest -Uri $loginUrl -Method Get -TimeoutSec 5 `
                -UseBasicParsing -ErrorAction Stop
        $text = $resp.Content

        $start = $text.IndexOf('{')
        $end   = $text.LastIndexOf('}')
        if ($start -ge 0 -and $end -gt $start) {
            $jsonText = $text.Substring($start, $end - $start + 1)
            try {
                $json = $jsonText | ConvertFrom-Json
                if ($json.result -eq 1) {
                    Write-Log 'SUCCESS' $IP $isp '认证成功'
                } elseif ($json.result -eq 0) {
                    if ($json.msg -match '已经在线') {
                        Write-Log 'ONLINE' $IP $isp '已在线，无需操作'
                    } else {
                        Write-Log 'FAIL' $IP $isp "登录失败: $($json.msg)"
                    }
                } else {
                    Write-Log 'UNKNOWN' $IP $isp "未知 result: $jsonText"
                }
            } catch {
                Write-Log 'PARSE_ERR' $IP $isp "JSON 解析失败: $jsonText"
            }
        } else {
            Write-Log 'PARSE_ERR' $IP $isp "JSONP 提取失败: $text"
        }
    } catch {
        Write-Log 'NET_ERR' $IP $isp "登录请求异常: $($_.Exception.Message)"
    }
}

# ═══════════════════════════════════════
#  主流程
# ═══════════════════════════════════════
$mutexName = 'Global\CampusAutoLogin_Mutex'   # 唯一名称，避免冲突
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
try {
    # 尝试在 3 秒内获取锁，若已有实例运行则退出
    if (-not $mutex.WaitOne(3000)) {
        Write-Log 'MUTEX' '-' '-' '已有实例正在运行，跳过本次执行'
        exit 0
    }

    $localIP = Get-LocalIPv4
    if (-not $localIP) {
        Write-Log 'ERROR' '-' '-' '无法获取本机 IPv4 地址'
        exit 1
    }

    $status = Test-NetworkStatus

    switch ($status) {
        'online' {
            exit 0
        }
        'suspicious' {
            Write-Log 'WARN' $localIP '-' '已连接互联网但无法自动认证，可能锐捷更新了认证策略'
            exit 2
        }
        'unreachable' {
            Write-Log 'UNREACHABLE' $localIP '-' '网络不通，无法访问探测地址'
            exit 1
        }
        'offline' {
            $cfg = Get-LoginConfig
            Invoke-Login -IP $localIP -Cfg $cfg
        }
    }
} catch {
    Write-Log 'FATAL' '-' '-' $_.Exception.Message
    exit 1
} finally {
    # 释放互斥锁（如果获取到了）
    if ($mutex) { $mutex.ReleaseMutex(); $mutex.Close() }
}