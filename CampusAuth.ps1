<#
.SYNOPSIS
  校园网自动认证脚本 —— 探测网络状态，未认证则自动登录

.DESCRIPTION
  实测协议（2026-09-01 河南科技大学校园网，裕达/大学掌体系）：

    1. 探测 http://www.msftconnecttest.com/connecttest.txt
       ├─ HTTP 200/204        → 已联网，退出
       └─ HTTP 302 → 10.100.51.1 → 未认证，继续
    2. 跟随重定向链，从最终 URL 提取 ip / mac / nasId / vlan
       /api/r/1?mac=..&vlan=.. → /tpl/<skin>/login.html?ip=..&mac=..&nasId=..&vlan=..
    3. GET /api/csrf-token  → {"csrf_token":"..."}（无需任何 Cookie）
    4. GET /api/account/status?nasId=&userIpv4=&userMac=..
       ├─ code=0 → 已在线，退出
       └─ code=1 → 不在线，继续登录
    5. POST /api/account/login
       头: X-CSRF-Token / X-Requested-With: XMLHttpRequest / Referer / Origin
       体: username&password&nasId&userIpv4&userMac&isp&timeLimit（明文）
       ├─ code=0 → 认证成功
       ├─ code=1 → 认证失败（msg 说明原因，如"认证失败"）
       └─ code=2 → 需要验证码（无法自动化，需浏览器手动登录一次）
    6. GET /api/account/status 复查 code=0 → 认证成功，退出

  ★ 关键实测结论（2026-09-01）：认证服务器的 CSRF token 绑定在 TCP 连接上！
    取 token（GET /api/csrf-token）与登录（POST /api/account/login）必须走
    同一条 keep-alive 连接，否则服务器返回 HTTP 400 {"error":"CSRF token mismatch"}。
    浏览器正是靠页面加载与 AJAX 共用连接才成功的。
    因此本脚本全程复用同一个 HttpClient，绝不每个请求新建连接（v1.0.3 及之前
    的"登录失败: code=, msg="空报错即源于此）。

  设计原则：
    - 脚本运行完毕即退出，零常驻
    - 全程无 Cookie 依赖（实测整个认证流程服务器不下发也不要求 Cookie）
    - 配合 Windows 任务计划程序触发（登录时 / 网络变更时 / 定时轮询）

.EXAMPLE
  .\CampusAuth.ps1                # 正常认证
  .\CampusAuth.ps1 -DryRun        # 模拟运行，不实际登录
  .\CampusAuth.ps1 -VerboseLog    # 详细日志
  .\CampusAuth.ps1 -Logout        # 下线本机

.NOTES
  Author : Campus Auto-Auth
  Version: 1.0.4（修复 CSRF token 连接绑定问题，2026-09-01）
#>

[CmdletBinding()]
param(
  # 注意：PS 5.1 的 param() 默认值阶段 $PSScriptRoot 还未就绪，留空由 Load-Config 自动发现
  [string]$ConfigFile = "",
  [switch]$DryRun,
  [switch]$VerboseLog,
  [switch]$Logout
)

# ============================================================
# 工具函数
# ============================================================

function Write-Log {
  param(
    [Parameter(Position = 0)][string]$Message,
    [Parameter(Position = 1)][ValidateSet("DEBUG", "INFO", "WARN", "ERROR")][string]$Level = "INFO"
  )

  $config = $script:_config
  if (-not $config) { $config = @{ log = @{ logLevel = "INFO"; logFile = "./campus-auth.log"; maxLogSizeKB = 512 } } }

  if ($VerboseLog -and $Level -eq "DEBUG") { $Level = "INFO" }
  $minLevel = $config.log.logLevel
  $levelOrder = @{ "DEBUG" = 0; "INFO" = 1; "WARN" = 2; "ERROR" = 3 }
  if ($levelOrder[$Level] -lt $levelOrder[$minLevel]) { return }

  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $line = "[$ts] [$Level] $Message"

  $colors = @{ "DEBUG" = "DarkGray"; "INFO" = "Green"; "WARN" = "Yellow"; "ERROR" = "Red" }
  Write-Host $line -ForegroundColor $colors[$Level]

  $logPath = $config.log.logFile
  if (-not [System.IO.Path]::IsPathRooted($logPath)) {
    $logPath = Join-Path $PSScriptRoot $logPath
  }
  $logDir = Split-Path $logPath -Parent
  if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

  if (Test-Path $logPath) {
    $size = (Get-Item $logPath).Length / 1KB
    $maxKB = 512
    if ($config.log.maxLogSizeKB) { $maxKB = [int]$config.log.maxLogSizeKB }
    if ($size -gt $maxKB) {
      $logName = Split-Path $logPath -Leaf
      $bak = Join-Path $logDir ($logName + ".old")
      if (Test-Path $bak) { Remove-Item $bak -Force }
      # Rename-Item 的 -NewName 只能是纯文件名，带路径会报"表示路径或设备名称"
      Rename-Item -LiteralPath $logPath -NewName ($logName + ".old") -Force
    }
  }

  Add-Content -Path $logPath -Value $line -Encoding UTF8
}

function Get-LocalIPv4 {
  # 获取本机活动网卡的 IPv4（排除回环 / 链路本地 / 认证服务器网段）
  try {
    $ip = Get-NetIPAddress -AddressFamily IPv4 |
      Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown' } |
      Where-Object { $_.IPAddress -notmatch '^(169\.254|10\.100\.)' } |
      Sort-Object InterfaceAlias |
      Select-Object -First 1 -ExpandProperty IPAddress
    return $ip
  } catch {
    Write-Log "获取本机IP失败: $_" "ERROR"
    return $null
  }
}

function Get-LocalMac {
  # 获取活动物理网卡 MAC，统一为 aa:bb:cc:dd:ee:ff 小写冒号格式
  try {
    $mac = Get-NetAdapter -Physical |
      Where-Object { $_.Status -eq 'Up' } |
      Sort-Object LinkSpeed -Descending |
      Select-Object -First 1 -ExpandProperty MacAddress
    if (-not $mac) { return $null }
    return ($mac.ToLower() -replace '-', ':')
  } catch {
    Write-Log "获取本机MAC失败: $_" "ERROR"
    return $null
  }
}

# 全局共享的 HttpClient（懒加载）。
# ★ 认证服务器实测：CSRF token 与 TCP 连接绑定，取 token 与登录必须同连接，
#   所以整个流程只能有一个 HttpClient，绝不能每个请求新建（否则 CSRF mismatch）。
$script:_httpClient = $null

function Get-AuthHttpClient {
  <# 返回全局共享的 HttpClient（不自动跟随重定向，需手动跟踪 302）#>
  param([int]$TimeoutSec = 10)

  if (-not $script:_httpClient) {
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $script:_httpClient = New-Object System.Net.Http.HttpClient($handler)
    $script:_httpClient.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
  }
  return $script:_httpClient
}

function Invoke-AuthRequest {
  <#
    统一的 HTTP 请求封装（PS 5.1 兼容，手动控制头与重定向）。
    ★ 使用全局共享 HttpClient：CSRF token 与 TCP 连接绑定，全程必须同连接。
    返回 @{ StatusCode; Headers; Body }，异常时返回 @{ Error }
  #>
  param(
    [string]$Method = "GET",
    [string]$Url,
    [hashtable]$Headers = @{},
    [string]$Body = $null,
    [int]$TimeoutSec = 10
  )

  # 注意：TimeoutSec 仅在首次创建客户端时生效；后续请求复用已有连接
  $client = Get-AuthHttpClient -TimeoutSec $TimeoutSec
  try {
    $methodObj = New-Object System.Net.Http.HttpMethod($Method)
    $request = New-Object System.Net.Http.HttpRequestMessage($methodObj, $Url)

    foreach ($key in $Headers.Keys) {
      if ($key -eq "Content-Type") { continue }   # 正文头单独设置
      $request.Headers.TryAddWithoutValidation($key, [string]$Headers[$key]) | Out-Null
    }

    if ($Body -ne $null -and $Body -ne "") {
      $contentType = "application/x-www-form-urlencoded"
      if ($Headers.ContainsKey("Content-Type")) { $contentType = $Headers["Content-Type"] }
      # StringContent 的 mediaType 只接受纯类型；charset 由 Encoding 参数负责，
      # 传入 "; charset=UTF-8" 之类的后缀会抛 FormatException，故剥离之
      $mediaType = ($contentType -split ';')[0].Trim()
      $request.Content = New-Object System.Net.Http.StringContent($Body, [System.Text.Encoding]::UTF8, $mediaType)
    }

    $response = $client.SendAsync($request).Result
    $bodyText = ""
    if ($response.Content) {
      $bodyText = $response.Content.ReadAsStringAsync().Result
    }

    $respHeaders = @{}
    foreach ($h in $response.Headers) { $respHeaders[$h.Key] = ($h.Value -join '; ') }
    foreach ($h in $response.Content.Headers) { $respHeaders[$h.Key] = ($h.Value -join '; ') }

    return @{
      StatusCode = [int]$response.StatusCode
      Headers    = $respHeaders
      Body       = $bodyText
    }
  } catch {
    return @{ Error = $_.Exception.Message }
  }
  # 注意：不 Dispose 共享客户端，连接需要跨请求存活（CSRF token 绑定连接）
}

function ConvertTo-UrlEncoded {
  <# 按浏览器方式做 percent-encoding（大写十六进制，冒号→%3A 斜杠→%2F）#>
  param([string]$Value)
  return [System.Uri]::EscapeDataString($Value)
}

# ============================================================
# 配置加载
# ============================================================

function Load-Config {
  param([string]$Path)

  # 候选路径依次尝试：指定路径 → 脚本同目录 → 脚本上级目录 → 当前目录
  $candidates = @()
  if ($Path) { $candidates += $Path }
  if ($PSScriptRoot) {
    $candidates += (Join-Path $PSScriptRoot "config.json")
    $candidates += (Join-Path (Split-Path $PSScriptRoot -Parent) "config.json")
  }
  $candidates += (Join-Path (Get-Location).Path "config.json")

  $found = $null
  foreach ($c in $candidates) {
    if ($c -and (Test-Path $c -PathType Leaf)) { $found = $c; break }
  }

  if (-not $found) {
    Write-Log "config.json 没有找到！尝试过以下位置：" "ERROR"
    foreach ($c in $candidates) { Write-Log "  - $c" "ERROR" }
    # 列出脚本目录实际存在的文件，便于远程诊断（截图发回即可定位）
    if ($PSScriptRoot) {
      Write-Log "脚本目录实际内容：" "ERROR"
      Get-ChildItem -LiteralPath $PSScriptRoot | ForEach-Object {
        Write-Log ("  {0}  ({1} 字节)" -f $_.Name, $_.Length) "ERROR"
      }
    }
    exit 1
  }

  if ($Path -and $found -ne $Path) { Write-Log "config.json 实际加载自: $found" "WARN" }

  try {
    return (Get-Content $found -Raw -Encoding UTF8 | ConvertFrom-Json)
  } catch {
    Write-Log "配置文件解析失败: $_" "ERROR"
    exit 1
  }
}

# ============================================================
# 步骤1：网络探测
# ============================================================

function Test-NetworkConnected {
  <#
    探测是否已联网。
    返回: $true=已联网 / $false=未认证（重定向目标写入 $script:_redirectUrl）
  #>
  param($Config)

  $probeUrl = $Config.detection.probeUrl
  $expectRedirect = $Config.detection.expectRedirect
  $timeout = $Config.detection.timeoutSec

  Write-Log "开始网络探测: $probeUrl" "DEBUG"

  $resp = Invoke-AuthRequest -Method "GET" -Url $probeUrl -TimeoutSec $timeout

  if ($resp.Error) {
    Write-Log "网络探测异常: $($resp.Error)（可能未连接 WiFi/网线）" "WARN"
    return $false
  }

  if ($resp.StatusCode -eq 200 -or $resp.StatusCode -eq 204) {
    Write-Log "网络已连通（HTTP $($resp.StatusCode)）" "INFO"
    return $true
  }

  if ($resp.StatusCode -ge 300 -and $resp.StatusCode -lt 400) {
    $location = $resp.Headers["Location"]
    Write-Log "检测到重定向: $location" "DEBUG"
    if ($location -and $location -match $expectRedirect) {
      Write-Log "网络未认证（重定向到 $expectRedirect）" "WARN"
      $script:_redirectUrl = $location
      return $false
    }
  }

  Write-Log "探测返回未知状态: HTTP $($resp.StatusCode)" "WARN"
  return $false
}

# ============================================================
# 步骤2：跟随重定向链提取认证参数
# ============================================================

function Get-AuthParamsFromRedirect {
  <#
    跟随重定向链，提取 ip / mac / nasId / vlan。
    实测链路:
      /api/r/1?mac=..&vlan=..                          (302, 网关附带)
      → /tpl/<skin>/login.html?ip=..&mac=..&nasId=..&vlan=..  (200, 登录入口)
    皮肤名可能变化（default → stu-xy），不硬编码，以重定向实际指向为准。
    返回: @{ ip; mac; nasId; vlan; loginPageUrl }
  #>
  param(
    [string]$InitialUrl,
    $Config
  )

  $timeout = $Config.detection.timeoutSec
  $params = @{}
  $finalUrl = $InitialUrl

  $currentUrl = $InitialUrl
  $maxRedirects = 5

  try {
    for ($i = 0; $i -lt $maxRedirects; $i++) {
      $resp = Invoke-AuthRequest -Method "GET" -Url $currentUrl -TimeoutSec $timeout
      if ($resp.Error) {
        Write-Log "跟随重定向异常: $($resp.Error)" "ERROR"
        break
      }

      if ($resp.StatusCode -ge 300 -and $resp.StatusCode -lt 400) {
        $location = $resp.Headers["Location"]
        if (-not $location) { break }

        # 相对路径补全
        if ($location.StartsWith('/')) {
          $base = $currentUrl -replace '^(https?://[^/]+).*$', '$1'
          $location = "$base$location"
        }

        Write-Log "  → $location" "DEBUG"
        $currentUrl = $location
        $finalUrl = $location
        continue
      }

      # 非 3xx（通常是 200），停止跟随
      break
    }

    # 从最终 URL 提取参数
    $uri = [System.Uri]$finalUrl
    $query = $uri.Query.TrimStart('?')
    foreach ($pair in $query -split '&') {
      $kv = $pair -split '=', 2
      if ($kv.Count -eq 2) {
        $key = [System.Uri]::UnescapeDataString($kv[0])
        $val = [System.Uri]::UnescapeDataString($kv[1])
        $params[$key] = $val
      }
    }
  } catch {
    Write-Log "提取认证参数异常: $_" "ERROR"
  }

  # 登录页 URL：login.html 会由前端 JS 跳转到 login_account.html（参数原样保留）
  # Referer 伪装成 login_account.html，与浏览器行为一致
  $loginPageUrl = $finalUrl -replace '/login\.html', '/login_account.html'

  $result = @{
    ip           = $params['ip']
    mac          = $params['mac']
    nasId        = $params['nasId']
    vlan         = $params['vlan']
    loginPageUrl = $loginPageUrl
  }

  Write-Log "提取到认证参数: ip=$($result.ip), mac=$($result.mac), nasId=$($result.nasId), vlan=$($result.vlan)" "INFO"
  return $result
}

# ============================================================
# 步骤3：获取 CSRF Token
# ============================================================

function Get-CsrfToken {
  <#
    实测确认：GET /api/csrf-token 返回 {"csrf_token":"..."}。
    请求需带 X-Requested-With 与 Referer（模拟浏览器 AJAX）。
    全程无需 Cookie（实测服务器不下发也不校验 Cookie）。
  #>
  param(
    $Config,
    [string]$LoginPageUrl
  )

  $url = "http://$($Config.network.authServer)$($Config.network.csrfTokenApiPath)"
  $headers = @{
    "User-Agent"       = $Config.advanced.userAgent
    "Accept"           = "*/*"
    "X-Requested-With" = "XMLHttpRequest"
    "Referer"          = $LoginPageUrl
  }

  Write-Log "获取 CSRF Token: $url" "DEBUG"
  $resp = Invoke-AuthRequest -Method "GET" -Url $url -Headers $headers -TimeoutSec $Config.detection.timeoutSec

  if ($resp.Error) {
    Write-Log "CSRF Token 获取失败: $($resp.Error)" "ERROR"
    return $null
  }

  try {
    $data = $resp.Body | ConvertFrom-Json
    if ($data.csrf_token) {
      Write-Log "CSRF Token 获取成功: $($data.csrf_token)" "DEBUG"
      return $data.csrf_token
    }
  } catch {
    Write-Log "CSRF 响应解析失败: $($resp.Body)" "ERROR"
  }

  Write-Log "CSRF 响应中无 csrf_token 字段" "ERROR"
  return $null
}

# ============================================================
# 步骤4：账户在线状态查询
# ============================================================

function Test-AccountOnline {
  <#
    GET /api/account/status 实测：
      不在线 → {"code":1,"msg":"不在线"}
      在线   → code=0（含 online 对象）
    返回: $true=在线 / $false=不在线
  #>
  param(
    $Config,
    $AuthParams,
    [string]$CsrfToken,
    [string]$LoginPageUrl
  )

  $timeout = $Config.detection.timeoutSec

  $ip  = $AuthParams.ip
  $mac = $AuthParams.mac
  if (-not $ip)  { $ip  = Get-LocalIPv4 }
  if (-not $mac) { $mac = Get-LocalMac }
  if (-not $ip -or -not $mac) {
    Write-Log "无法确定 IP/MAC，跳过在线检查" "WARN"
    return $false
  }

  # 与浏览器请求参数完全一致（含空参数项）
  $query = "username=&password=&switchip=&nasId=$($AuthParams.nasId)" +
           "&userIpv4=$(ConvertTo-UrlEncoded $ip)" +
           "&userMac=$(ConvertTo-UrlEncoded $mac)" +
           "&captcha=&captchaId=&isp=&timeLimit="
  $url = "http://$($Config.network.authServer)$($Config.network.statusApiPath)?$query"

  $headers = @{
    "User-Agent"       = $Config.advanced.userAgent
    "Accept"           = "application/json, text/plain, */*"
    "X-Requested-With" = "XMLHttpRequest"
    "Referer"          = $LoginPageUrl
  }
  if ($CsrfToken) { $headers["X-CSRF-Token"] = $CsrfToken }

  $resp = Invoke-AuthRequest -Method "GET" -Url $url -Headers $headers -TimeoutSec $timeout

  if ($resp.Error) {
    Write-Log "在线状态查询异常: $($resp.Error)" "WARN"
    return $false
  }

  try {
    $data = $resp.Body | ConvertFrom-Json
    if ($data.code -eq 0) {
      Write-Log "账户已在线: $($data.online.Username)" "INFO"
      return $true
    }
    Write-Log "账户不在线（code=$($data.code), msg=$($data.msg)）" "DEBUG"
  } catch {
    Write-Log "在线状态响应解析失败: $($resp.Body)" "WARN"
  }

  return $false
}

# ============================================================
# 步骤5：POST 登录
# ============================================================

function Invoke-CampusLogin {
  <#
    POST /api/account/login 实测返回码：
      code=0 → 认证成功
      code=1 → 认证失败（msg: "认证失败" / "第三方密码校验失败" 等）
      code=2 → 需要验证码（返回 captcha.picPath / captchaId）
  #>
  param(
    $Config,
    $AuthParams,
    [string]$CsrfToken
  )

  $authServer = $Config.network.authServer
  $loginUrl = "http://$authServer$($Config.network.loginApiPath)"
  $timeout = $Config.detection.timeoutSec

  $ip  = $AuthParams.ip
  $mac = $AuthParams.mac
  if (-not $ip)  { $ip  = Get-LocalIPv4 }
  if (-not $mac) { $mac = Get-LocalMac }

  $nasId = $AuthParams.nasId
  if (-not $nasId) { $nasId = $Config.network.nasId }

  # 字段顺序与浏览器一致；空值字段（timeLimit）保留为空串
  $body = "username=$(ConvertTo-UrlEncoded $Config.credentials.username)" +
          "&password=$(ConvertTo-UrlEncoded $Config.credentials.password)" +
          "&nasId=$(ConvertTo-UrlEncoded ([string]$nasId))" +
          "&userIpv4=$(ConvertTo-UrlEncoded $ip)" +
          "&userMac=$(ConvertTo-UrlEncoded $mac)" +
          "&isp=$(ConvertTo-UrlEncoded $Config.credentials.isp)" +
          "&timeLimit=$(ConvertTo-UrlEncoded $Config.credentials.timeLimit)"

  $headers = @{
    "User-Agent"       = $Config.advanced.userAgent
    "Accept"           = "*/*"
    "Content-Type"     = "application/x-www-form-urlencoded; charset=UTF-8"
    "Origin"           = "http://$authServer"
    "Referer"          = $AuthParams.loginPageUrl
    "X-Requested-With" = "XMLHttpRequest"
  }
  if ($CsrfToken) { $headers["X-CSRF-Token"] = $CsrfToken }

  Write-Log "登录 POST $loginUrl" "INFO"
  Write-Log "  username=$($Config.credentials.username), ip=$ip, mac=$mac, nasId=$nasId" "DEBUG"

  if ($DryRun) {
    Write-Log "[DryRun] 跳过实际 POST 请求" "INFO"
    Write-Log "[DryRun] Body: $body" "DEBUG"
    return @{ success = $false; dryRun = $true }
  }

  $resp = Invoke-AuthRequest -Method "POST" -Url $loginUrl -Headers $headers -Body $body -TimeoutSec $timeout

  if ($resp.Error) {
    Write-Log "登录请求异常: $($resp.Error)" "ERROR"
    return @{ success = $false; error = $resp.Error }
  }

  Write-Log "登录响应: HTTP $($resp.StatusCode)" "DEBUG"
  Write-Log "响应内容: $($resp.Body)" "DEBUG"

  if ($resp.Body) {
    try {
      $result = $resp.Body | ConvertFrom-Json

      if ($result.code -eq 0) {
        Write-Log "登录成功！（服务器返回 code=0）" "INFO"
        return @{ success = $true; response = $result }
      }
      elseif ($result.code -eq 2) {
        # 需要验证码：密码校验失败次数过多后触发，无法自动化
        Write-Log "服务器要求验证码（code=2），脚本无法自动处理" "ERROR"
        Write-Log "请用浏览器打开认证页手动登录一次（含验证码），之后再运行本脚本" "ERROR"
        return @{ success = $false; needCaptcha = $true }
      }
      else {
        # v1.0.4: 服务器也会返回 {"error":"..."}（如 CSRF token mismatch），原样展示便于诊断
        if ($result.error) {
          Write-Log "登录被服务器拒绝: error=$($result.error)（HTTP $($resp.StatusCode)）" "ERROR"
        } else {
          Write-Log "登录失败: code=$($result.code), msg=$($result.msg)（HTTP $($resp.StatusCode)）" "ERROR"
        }
        Write-Log "登录原始响应: $($resp.Body)" "ERROR"
        return @{ success = $false; response = $result }
      }
    } catch {
      Write-Log "登录响应不是 JSON: $($resp.Body.Substring(0, [Math]::Min(200, $resp.Body.Length)))" "WARN"
    }
  }

  Write-Log "登录响应无法解析" "ERROR"
  return @{ success = $false }
}

# ============================================================
# 可选：下线本机
# ============================================================

function Invoke-CampusLogout {
  <#
    POST http://210.43.0.48/mac/loginOut?clientIP=
    Body: mac=<URL编码的MAC>（无 Cookie、无 CSRF，实测有效）
  #>
  param($Config)

  $timeout = $Config.detection.timeoutSec
  $logoutUrl = "$($Config.portal.baseUrl)$($Config.portal.logoutPath)"

  $mac = Get-LocalMac
  if (-not $mac) {
    Write-Log "获取本机 MAC 失败，无法下线" "ERROR"
    return $false
  }

  $headers = @{
    "User-Agent"   = $Config.advanced.userAgent
    "Accept"       = "application/json, text/plain, */*"
    "Content-Type" = "application/x-www-form-urlencoded;charset=UTF-8"
    "Origin"       = $Config.portal.baseUrl
    "Referer"      = "$($Config.portal.baseUrl)/"
  }
  $body = "mac=$(ConvertTo-UrlEncoded $mac)"

  if ($DryRun) {
    Write-Log "[DryRun] 跳过下线请求" "INFO"
    Write-Log "[DryRun] POST $logoutUrl  Body: $body" "DEBUG"
    return $false
  }

  Write-Log "下线请求: POST $logoutUrl mac=$mac" "INFO"
  $resp = Invoke-AuthRequest -Method "POST" -Url $logoutUrl -Headers $headers -Body $body -TimeoutSec $timeout

  if ($resp.Error) {
    Write-Log "下线请求异常: $($resp.Error)" "ERROR"
    return $false
  }

  Write-Log "下线响应: HTTP $($resp.StatusCode) $($resp.Body)" "DEBUG"

  # 验证：重新探测，应回到 302 认证状态
  Start-Sleep -Seconds 2
  $script:_redirectUrl = $null
  $stillOnline = Test-NetworkConnected -Config $Config
  if (-not $stillOnline) {
    Write-Log "下线成功（探测已回到未认证状态）" "INFO"
    return $true
  }

  Write-Log "下线请求已发送，但探测仍显示在线，请人工确认" "WARN"
  return $false
}

# ============================================================
# 主流程
# ============================================================

function Invoke-CampusAuth {
  param($Config)

  Write-Log "========== 校园网自动认证开始 ==========" "INFO"

  # -Logout 分支：下线后直接退出
  if ($Logout) {
    $ok = Invoke-CampusLogout -Config $Config
    if ($ok) { exit 0 } else { exit 1 }
  }

  # 步骤1: 网络探测
  $connected = Test-NetworkConnected -Config $Config
  if ($connected) {
    Write-Log "网络已连通，无需认证" "INFO"
    exit 0
  }

  if (-not $script:_redirectUrl) {
    Write-Log "未获取到重定向URL（可能未连上校园网）" "ERROR"
    exit 1
  }

  # 步骤2: 从重定向链提取参数
  $authParams = Get-AuthParamsFromRedirect -InitialUrl $script:_redirectUrl -Config $Config

  if (-not $authParams.ip -or -not $authParams.mac) {
    Write-Log "未能从重定向提取完整参数，回退到本机 IP/MAC" "WARN"
    if (-not $authParams.ip)  { $authParams.ip  = Get-LocalIPv4 }
    if (-not $authParams.mac) { $authParams.mac = Get-LocalMac }
    if (-not $authParams.nasId) { $authParams.nasId = $Config.network.nasId }
  }

  # 步骤3: 在线预检查（已在线则无需登录）
  $preCheckToken = Get-CsrfToken -Config $Config -LoginPageUrl $authParams.loginPageUrl
  if (Test-AccountOnline -Config $Config -AuthParams $authParams -CsrfToken $preCheckToken -LoginPageUrl $authParams.loginPageUrl) {
    Write-Log "账号已在线，无需重复认证" "INFO"
    exit 0
  }

  # 步骤4: 登录（带重试）
  $maxRetries = $Config.advanced.maxRetries
  $retryDelay = $Config.advanced.retryDelaySec
  $success = $false

  for ($i = 1; $i -le $maxRetries; $i++) {
    Write-Log "登录尝试 $i / $maxRetries" "INFO"

    # 每次重试都重新取 Token（防止 Token 刷新失效）
    $csrfToken = Get-CsrfToken -Config $Config -LoginPageUrl $authParams.loginPageUrl
    if (-not $csrfToken) {
      Write-Log "无法获取 CSRF Token" "ERROR"
      break
    }

    $result = Invoke-CampusLogin -Config $Config -AuthParams $authParams -CsrfToken $csrfToken

    if ($result.success) {
      $success = $true
      break
    }

    # 需要验证码时重试无意义，直接退出
    if ($result.needCaptcha) { exit 2 }
    if ($result.dryRun) { exit 0 }

    if ($i -lt $maxRetries) {
      Write-Log "等待 ${retryDelay}s 后重试..." "WARN"
      Start-Sleep -Seconds $retryDelay
    }
  }

  # 步骤5: 验证
  if ($success) {
    Start-Sleep -Seconds 2
    $online = Test-AccountOnline -Config $Config -AuthParams $authParams -CsrfToken $csrfToken -LoginPageUrl $authParams.loginPageUrl
    if ($online) {
      Write-Log "========== 认证成功，已联网 ==========" "INFO"
      exit 0
    } else {
      Write-Log "登录请求成功但状态复查未通过，请人工确认" "WARN"
      exit 1
    }
  } else {
    Write-Log "========== 认证失败 ==========" "ERROR"
    exit 1
  }
}

# ============================================================
# 入口
# ============================================================

# PS 5.1 不会自动加载 System.Net.Http，必须显式加载（HttpClient/HttpRequestMessage/StringContent 都在里面）
try {
  Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
} catch {
  Write-Host "[FATAL] 无法加载 System.Net.Http 程序集: $_" -ForegroundColor Red
  Write-Host "本脚本需要 .NET Framework 4.5+（Windows 10 自带）。请把此截图发回。" -ForegroundColor Red
  exit 1
}

$script:_config = Load-Config -Path $ConfigFile
$script:_redirectUrl = $null

try {
  Invoke-CampusAuth -Config $script:_config
} catch {
  Write-Log "未捕获异常: $_" "ERROR"
  Write-Log $_.ScriptStackTrace "ERROR"
  exit 1
} finally {
  # 释放共享 HttpClient（exit 也会触发 finally）
  if ($script:_httpClient) { $script:_httpClient.Dispose() }
}
