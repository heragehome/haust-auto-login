**河南科技大学校园网自动认证部署指南**
（大学掌 · POST 版）

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-blue.svg)
![Windows](https://img.shields.io/badge/Platform-Windows-0078d6.svg)
![Auth: POST + CSRF](https://img.shields.io/badge/Auth-POST%2BCSRF-important.svg)

> **河南科技大学（HAUST）校园网自动认证工具**，零常驻 PowerShell 脚本 + Windows 任务计划程序，双击即用。
> 适用于使用「大学掌（autewifi.cn）」认证服务的河南高校（河科大、河大、新医等）。

<details>
<summary><b>English Abstract</b></summary>

**campus-auth v2.0** — a zero-resident **Windows PowerShell** auto-login for the **Captive-Portal** network at **Henan University of Science and Technology (HAUST)** and other universities using the **"Daxuezhang" (autewifi.cn)** platform.

- **Authentication**: POST JSON API with **CSRF Token**, no cookies, keep-alive reuse.
- **Scheduling**: auto-triggered at user logon, on network change (event 10000), and every 10 minutes via Windows Task Scheduler. No daemon stays resident.
- **Companion**: pairs with [v1.0](https://github.com/heragehome/haust-auto-login/releases/tag/v1.0) (legacy Ruijie ePortal, GET + JSONP) to show how the same university evolved across two authentication generations — a practical **GET vs POST** case for network-automation / reverse-engineering study.

> **Disclaimer**: For study & research only; do not violate your university's network policies. Provided AS-IS with no warranty; use at your own risk.

</details>

---

## 项目定位

本项目是**校园网强制门户（Captive Portal）自动认证**的一个**真实、可运行的工程案例**，同时面向两类用户：

1. **河科大/河南高校的学生**：直接下载解压、填账号、双击 ③，即可免手动登录自动认证。
2. **社区/开发者（开源案例）**：本项目连同 [v1.0](https://github.com/heragehome/haust-auto-login/releases/tag/v1.0)（旧锐捷系统）一起，
   完整呈现了**同一所高校先后两代认证系统的协议演进**，可作为强制门户认证的迁移、二次开发与教学参考：

   | 版本 | 认证系统 | 请求方式 | 协议特征 | 状态 |
   | --- | --- | --- | --- | --- |
   | [v1.0](https://github.com/heragehome/haust-auto-login/releases/tag/v1.0) | 锐捷 ePortal（旧） | **GET** | 透明代理劫持 + JSONP 解析、cmd/icmp 放行 | 河科大已弃用，仍适用于其他锐捷 ePortal 高校 |
   | **v2.0（本版）** | 大学掌 / autewifi（新） | **POST** | JSON API + **CSRF Token**、无 Cookie、keep-alive 复用 | 河科大现役 |

   > 两版脚本对比即可直观理解 **GET 表单认证（URL 传参 + JSONP）** 与 **POST JSON API 认证（请求头 + CSRF + 状态复查）** 的差异，适合作为网络自动化 / 反爬 / 协议逆向的入门实战。

**关键词**：校园网自动登录 / 强制门户 / captive portal / 锐捷 ePortal / 大学掌 autewifi / 河南科技大学 / PowerShell / 免驻留 / Windows 任务计划

---

## 功能与特性

- **零常驻内存**：脚本由任务计划触发，执行完立即退出，不驻留任何守护进程。
- **全双击免命令行**：5 个 `.bat` 启动器，自动请求管理员、出错窗口驻留可截图。
- **三重自动触发**：① 用户登录后 ② 网络变更（NetworkProfile 事件 10000）③ 每 10 分钟轮询兜底。
- **隐蔽探测**：完全模拟 Microsoft Edge 的强制门户探测请求，应用层不可区分。
- **自动下线**：双击 ④ 即可下线本机。
- **自动安装任务计划**：可一键注册到 Windows 任务计划程序（无需手动配置）。

---

## 文件说明

| 文件 | 用途 |
| --- | --- |
| `⑤ 解除锁定（只需运行一次）.bat` | 首次运行：去除下载文件“网络来源”标记，免授权弹窗 |
| `① 运行DryRun测试.bat` | 双击运行：安全预演（只探测+取参数，**不实际登录**） |
| `② 立即认证.bat` | 双击运行：立即执行网络诊断 + 认证一次 |
| `③ 安装任务计划.bat` | 双击运行：自动注册开机/断网/定时自动认证（自动请求管理员） |
| `④ 下线本机.bat` | 双击运行：立即下线 |
| `config.json` | 账号与网络配置，与脚本同目录 |
| `CampusAuth.ps1` | 主脚本（探测 + 认证 + 下线） |
| `Install-Task.ps1` | 安装任务计划（三触发器自动注册） |
| `Uninstall-Task.ps1` | 卸载任务计划 |
| `campus-auth.log` | 运行日志，自动生成在脚本同目录 |
| `项目AI提示词.md` | 协议逆向/二次开发的完整参考（含实测抓包校准） |

---

## 快速使用

> **首次使用按 ⑤→①→②→③ 的顺序**：先解除锁定，再 DryRun 预演，再手动认证，最后装任务计划。

1. **双击** `⑤ 解除锁定（只需运行一次）.bat` —— 清除 Windows 给下载文件打的“网络来源”标记。
   从此双击任何 `.bat` 不再弹“打开文件-安全警告”（本次运行 ⑤ 本身还会弹最后一次，点“运行”）。
2. **双击** `① 运行DryRun测试.bat` —— 只探测网络、取参数、读接口，**不实际登录**。
   正常会看到“提取到认证参数”，把窗口截图发回即可核对。
3. **编辑 `config.json`** 填入学号账号与密码（详见下文「四、配置文件」）。
4. **双击** `② 立即认证.bat` —— 真实登录一次。看到“认证成功，已联网”即全部就绪。
5. **双击** `③ 安装任务计划.bat` —— 安装自动认证（会弹管理员确认框，点“是”）。
   之后开机登录 / 断网恢复 / 每 10 分钟，都会自动检查并按需登录，且零常驻。
6. 想下线：**双击** `④ 下线本机.bat`。

所有窗口执行完都会停住（`pause`），出错时可直接截图。

---

## 配置文件（config.json）

下载后必须编辑 **`username` / `password`**。其余字段一般无需改动。

```jsonc
{
  "credentials": {
    "username": "请输入账号",
    "password": "请输入密码",
    "isp": "local",          // 运营商：local / wcmcc(移动) / unicom(联通) / wtelecom(电信)
    "timeLimit": ""
  },
  "network": {
    "authServer": "10.100.51.1",   // 认证服务器（内网），2026-09-01 实测校准
    "loginApiPath": "/api/account/login",
    "statusApiPath": "/api/account/status",
    "csrfTokenApiPath": "/api/csrf-token",
    "nasId": "1"
  },
  "detection": {
    "probeUrl": "http://www.msftconnecttest.com/connecttest.txt",
    "expectRedirect": "10.100.51.1",  // 未认证时重定向到的网关地址
    "timeoutSec": 5
  },
  "portal": {
    "baseUrl": "http://210.43.0.48",   // 自助服务门户（在线确认 / 下线）
    "verifyPath": "/mac/?clientIP=",
    "logoutPath": "/mac/loginOut?clientIP="
  }
}
```

> ⚠️ **账号密码以明文保存在 `config.json`**（认证走 HTTP 明文，无加密层）。请勿在**填入真实密码后**再把该文件夹上传或分享；提交到仓库的 `config.json` 仅含占位符（`请输入账号` / `请输入密码`），不含任何真实凭据。

---

## 卸载

1. **删除计划任务**：右键 `Uninstall-Task.ps1` → “使用 PowerShell 运行”，或管理员打开 PowerShell 执行：
   ```powershell
   Unregister-ScheduledTask -TaskName "CampusAutoAuth" -Confirm:$false
   ```
2. 直接删除整个 `campus-auth` 文件夹即可。

---

## 命令行方式（进阶，可选）

```powershell
.\CampusAuth.ps1 -DryRun        # 模拟运行（不实际登录）
.\CampusAuth.ps1                # 正常认证（网络诊断 + 登录）
.\CampusAuth.ps1 -Logout        # 下线本机
.\Install-Task.ps1              # 安装任务计划（需管理员）
.\Uninstall-Task.ps1            # 卸载任务计划（需管理员）
```

主脚本可选参数：`-ConfigFile <路径>` 指定配置文件（默认自动发现同目录 `config.json`）。

---

## 故障排查

| 症状 | 原因 / 处理 |
| --- | --- |
| 每次双击 .bat 都弹“打开文件-安全警告” | 下载文件带 MOTW 标记，双击 `⑤` 永久解除；或右键压缩包→属性→勾选“解除锁定”再解压 |
| `②` 提示“登录失败: code=, msg=”为空 | 认证服务器 CSRF Token 与 TCP 连接绑定，必须复用同一 keep-alive 连接。脚本已统一复用单个 HttpClient；若仍出现，看日志是否输出服务器原始响应 |
| 日志显示 `FAIL` | 账号/密码/运营商（`isp`）不匹配，或欠费、未绑定当前 IP；对照 `config.json` 与自助门户核对 |
| 日志显示 `NET_ERR` | 认证服务器在内网，开启防火墙/代理时不可达；检查到 `10.100.51.1` 的连通性，确认系统时间正确（影响 SSL） |
| 日志显示 `UNREACHABLE` / `PROBE_FAIL` | 网卡未连接 / 未获取 IP（如未拿到 `10.x.x.x`）；重启网络适配器 |
| 日志显示 `MUTEX` | 上一实例仍在运行，正常保护机制，无需处理 |
| 登录成功却又弹出认证页 | 校园网强制约 24 小时踢下线一次，属正常；脚本下次触发会自动重登 |
| 提示“需要验证码” | 连续输错密码后服务器要求图形验证码，脚本无法自动处理；用浏览器手动登录一次即可恢复 |

> `UNKNOWN` / `PARSE_ERR`：服务器返回未识别 `result` 或非 JSON 内容，多为认证系统升级，可把日志原文 + `项目AI提示词.md` 一起反馈。

---

## 触发时机与日志

### 触发时机（`③ 安装任务计划` 自动注册）

| 触发器 | 说明 | 状态 |
| --- | --- | --- |
| 用户登录时 | 开机登录后自动触发 | ✓ 自动安装 |
| 定时轮询 | 每 10 分钟检查一次（兜底） | ✓ 自动安装 |
| 网络变更 | 切换 WiFi / 插拔网线（NetworkProfile 事件 10000） | ✓ 自动注入 XML |

### 日志

日志默认生成在脚本同目录 `campus-auth.log`，超过 512KB 自动轮转为 `.old`。

```
[2026-09-01 09:45:00] [INFO] ========== 校园网自动认证开始 ==========
[2026-09-01 09:45:00] [WARN] 网络未认证（重定向到 10.100.51.1）
[2026-09-01 09:45:01] [INFO] 提取到认证参数: ip=10.100.0.100, mac=00:11:22:33:44:55, nasId=1, vlan=eth-trunk/1:3002.3752
[2026-09-01 09:45:01] [INFO] 登录尝试 1 / 3
[2026-09-01 09:45:02] [INFO] 登录成功！（服务器返回 code=0）
[2026-09-01 09:45:04] [INFO] 账户已在线: 202600000000
[2026-09-01 09:45:04] [INFO] ========== 认证成功，已联网 ==========
```

**状态码**：`SUCCESS` 认证成功 / `ONLINE` 已在线 / `FAIL` 认证失败 / `NET_ERR` 登录请求异常 / `UNREACHABLE` 网络不通 / `PROBE_FAIL` 探测彻底失败 / `UNKNOWN` 未知响应 / `PARSE_ERR` 响应解析失败 / `WARN` 状态可疑 / `ERROR` 脚本运行错误 / `FATAL` 致命异常 / `MUTEX` 互斥锁跳过。

---

## 版本历史

| 版本 | 日期 | 说明 |
| --- | --- | --- |
| 0.1.0 | 2026-06 | 预发布河科大校园网认证系统 |
| 1.0.0 | 2026-06 | 正式发布 锐捷（GET）版本 |
| v2.0 | 2026-09 | 正式发布 大学掌（POST）版本 |

## 已知限制

- **验证码（code=2）无法自动化**：连续输错密码后需浏览器手动登录一次。
- **密码明文**：认证协议明文传输，`config.json` 中的账号密码以明文保存在本机。**填入真实密码后请勿再将本文件夹提交/分享**；仓库中的 `config.json` 仅含占位符。
- **IPv6 未验证**：本协议只覆盖 IPv4 认证。
- **皮肤名变化**：学校可能更换登录页皮肤（`default`↔`stu-xy`），脚本不硬编码，自动跟随重定向。

---

## ⚠️ 免责声明

本项目仅供个人学习、研究计算机网络自动化与脚本编写技术之用，**不得用于违反学校网络管理规定的行为**（包括但不限于：非法占用校园网资源、规避实名认证或流量审计等安全策略、在未授权设备/网络中使用）。

使用本脚本即代表你已仔细阅读并完全理解本声明，并**自愿承担使用脚本带来的一切风险与后果**。作者不对任何因使用或滥用本脚本造成的直接或间接损失负责（含账号被封禁/处罚、网络安全事件、其他纠纷）。若你所在学校/网络环境明确禁止此类自动化操作，请立即停止使用并删除所有相关文件。

本项目遵循“原样（AS-IS）”提供，作者不提供任何明示或暗示的担保。继续使用、复制或分发即代表接受上述条款；不同意请勿使用。
