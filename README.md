# SMS Forwarder

**Forward SMS and incoming calls from your Android device to iOS via [Bark](https://github.com/Finb/Bark) push notifications.**

A SukiSU / KernelSU systemless module that monitors incoming SMS messages and phone calls in real-time, then forwards them as rich push notifications to one or more iOS devices through the Bark push service.

---

## Features

- **SMS Forwarding** — Detects new SMS messages and pushes sender, time, SIM slot, and full message body to Bark
- **Incoming Call Alerts** — Real-time ringing detection via `dumpsys telephony.registry`, pushes caller number, SIM slot, and carrier/location info
- **Multiple Bark Endpoints** — Send to multiple Bark URLs simultaneously (e.g., personal + work devices)
- **Dual SIM Support** — Identifies which SIM slot received the SMS or call
- **Phone Number Location Lookup** — Queries carrier and region for 11-digit Chinese mobile numbers
- **Smart Monitoring Modes**
  - **Event-driven** — Uses `content observe` for near-instant SMS detection
  - **Polling fallback** — Automatic degradation when event mode is unavailable
  - **Hybrid** — `auto` mode tries event-driven first, falls back gracefully
- **Boot Autostart** — Daemon launches automatically after device boot
- **Crash Recovery** — Built-in watchdog restarts child processes if they die
- **Silent Catch-up** — On first run, records current position without flooding historical messages
- **State-first Updates** — State is persisted before sending notifications, preventing duplicates on failure
- **32-bit Safe** — Handles 13-digit millisecond timestamps without integer overflow
- **Multi-fallback Date Formatting** — `awk strftime` → `toybox date` → `GNU date` → pure `awk` math
- **SELinux Aware** — Runs within KernelSU/SukiSU permission model
- **Configurable Everything** — Poll intervals, retry policy, Bark sound/group/icon/level, log rotation

## Requirements

- Android 14+ (API 34+)
- [SukiSU Ultra](https://github.com/tiann/KernelSU) or KernelSU installed
- [Bark](https://apps.apple.com/app/bark/id1403753865) app installed on the target iOS device
- `curl` or `wget` available on the device (usually provided by BusyBox module)

## Installation

1. Download the latest `SMSForwarder-v*.zip` from [Releases](../../releases)
2. Open SukiSU / KernelSU Manager → Modules → Install from storage
3. Select the downloaded ZIP file
4. **Edit the config file** to add your Bark push URL(s):

```bash
# Connect via adb shell or terminal emulator
su
vi /data/adb/sms_forwarder/bark.conf
```

5. Reboot — the module starts automatically

## Configuration

Config file location: `/data/adb/sms_forwarder/bark.conf`

The config is preserved across module updates — only a fresh install creates the default.

### Bark URLs (required)

```bash
BARK_URLS=(
    https://api.day.app/your-key-here
    https://bark.example.com/another-key
)
```

### Feature Toggles

| Option | Default | Description |
|--------|---------|-------------|
| `FORWARD_SMS` | `true` | Enable SMS forwarding |
| `FORWARD_CALL` | `true` | Enable incoming call forwarding |
| `LOOKUP_LOCATION` | `true` | Query phone number carrier/location |

### Monitoring & Performance

| Option | Default | Description |
|--------|---------|-------------|
| `MONITOR_MODE` | `auto` | `auto` / `event` / `poll` |
| `POLL_INTERVAL` | `5` | Polling interval in seconds (poll mode) |
| `EVENT_DELAY_SMS` | `1` | Delay after event trigger to ensure data is ready |
| `CALL_RING_POLL` | `2` | Ringing detection poll interval in seconds |
| `HTTP_TIMEOUT` | `10` | HTTP request timeout in seconds |
| `MAX_RETRIES` | `3` | Retry count on push failure |
| `RETRY_BACKOFF` | `2` | Retry backoff base in seconds (actual = base × attempt) |

### Bark Message Options

| Option | Default | Description |
|--------|---------|-------------|
| `BARK_GROUP` | `SMSForwarder` | Notification group name in iOS |
| `BARK_SOUND` | `minuet` | Push notification sound |
| `BARK_ICON` | *(empty)* | Custom notification icon URL |
| `BARK_LEVEL` | `timeSensitive` | `active` / `timeSensitive` / `passive` |

### Logging

| Option | Default | Description |
|--------|---------|-------------|
| `LOG_LEVEL` | `INFO` | `DEBUG` / `INFO` / `WARN` / `ERROR` |
| `LOG_MAX_LINES` | `2000` | Auto-rotate when log exceeds this |

## Notification Format

**SMS:**
```
Title: 短信 10086 [SIM 1]
Body:  2026-03-20 16:05:19
       尊敬的客户，您的套餐余量...
```

**Incoming Call:**
```
Title: 来电 13800138000 [SIM 2]
Body:  广东 深圳 中国移动
       2026-03-20 16:05:19
```

## File Structure

```
SMSForwarder/
├── module.prop          # Module metadata
├── service.sh           # Boot autostart entry
├── customize.sh         # Installation script
├── uninstall.sh         # Cleanup on uninstall
├── config/
│   └── bark.conf        # Default configuration template
└── bin/
    ├── daemon.sh        # Main daemon with watchdog
    ├── utils.sh         # Shared utilities (logging, HTTP, state, etc.)
    ├── bark_client.sh   # Bark API client with retry logic
    ├── sms_monitor.sh   # SMS monitoring (two-phase query)
    └── call_monitor.sh  # Incoming call detection (telephony state machine)
```

**Runtime paths** (on device):

```
/data/adb/sms_forwarder/
├── bark.conf            # User config (persists across updates)
├── logs/
│   └── sms_forwarder.log
└── run/
    ├── daemon.pid
    └── last_sms_id
```

## Troubleshooting

**View logs:**
```bash
su -c "cat /data/adb/sms_forwarder/logs/sms_forwarder.log"
```

**Check if daemon is running:**
```bash
su -c "cat /data/adb/sms_forwarder/run/daemon.pid && ps -p $(cat /data/adb/sms_forwarder/run/daemon.pid)"
```

**Restart daemon manually:**
```bash
su -c "pkill -f daemon.sh; sleep 1; sh /data/adb/modules/sms_forwarder/bin/daemon.sh &"
```

**Reset SMS state** (if forwarding old messages):
```bash
su -c "rm -f /data/adb/sms_forwarder/run/last_sms_id"
```

## Upgrading

```bash
# 1. Stop old daemon
su -c "pkill -f daemon.sh"

# 2. Clear runtime state
su -c "rm -rf /data/adb/sms_forwarder/run/"

# 3. Install new ZIP via KernelSU Manager

# 4. Reboot
```

Your `bark.conf` is preserved automatically.

## Building from Source

```bash
cd SMSForwarder
zip -r SMSForwarder-v1.0.0.zip \
    module.prop \
    service.sh \
    customize.sh \
    uninstall.sh \
    config/ \
    bin/ \
    -x '*.git*'
```

## License

MIT

---

# SMS Forwarder（短信转发器）

**将 Android 设备上的短信和来电通知，通过 [Bark](https://github.com/Finb/Bark) 推送到 iOS 设备。**

这是一个 SukiSU / KernelSU 无系统模块，实时监控收到的短信和来电，通过 Bark 推送服务将通知发送到一台或多台 iOS 设备。

---

## 功能特点

- **短信转发** — 检测新短信，推送发送方号码、时间、SIM 卡槽、完整短信内容
- **来电提醒** — 通过 `dumpsys telephony.registry` 实时检测响铃，推送来电号码、SIM 卡槽、归属地
- **多 Bark 地址** — 支持同时推送到多个 Bark URL（如个人 + 工作设备）
- **双卡识别** — 自动识别短信/来电对应的 SIM 卡槽
- **号码归属地** — 自动查询 11 位手机号的运营商和归属地
- **智能监控模式**
  - **事件驱动** — 使用 `content observe` 实现近乎即时的短信检测
  - **轮询降级** — 事件模式不可用时自动切换为轮询
  - **自动模式** — `auto` 模式优先尝试事件驱动，失败时优雅降级
- **开机自启** — 系统启动后守护进程自动运行
- **崩溃恢复** — 内置看门狗，子进程异常退出后自动重启
- **静默追进** — 首次运行时只记录当前位置，不会推送历史短信
- **状态先行** — 先持久化状态再发送通知，防止失败后重复推送
- **32 位安全** — 正确处理 13 位毫秒时间戳，避免整数溢出
- **多重日期回退** — `awk strftime` → `toybox date` → `GNU date` → 纯 `awk` 计算
- **SELinux 感知** — 在 KernelSU/SukiSU 权限模型下运行
- **全面可配置** — 轮询间隔、重试策略、Bark 铃声/分组/图标/级别、日志轮转

## 环境要求

- Android 14+（API 34+）
- 已安装 [SukiSU Ultra](https://github.com/tiann/KernelSU) 或 KernelSU
- 目标 iOS 设备已安装 [Bark](https://apps.apple.com/app/bark/id1403753865)
- 设备上需有 `curl` 或 `wget`（通常由 BusyBox 模块提供）

## 安装步骤

1. 从 [Releases](../../releases) 下载最新的 `SMSForwarder-v*.zip`
2. 打开 SukiSU / KernelSU 管理器 → 模块 → 从存储安装
3. 选择下载的 ZIP 文件
4. **编辑配置文件**，添加你的 Bark 推送地址：

```bash
# 通过 adb shell 或终端模拟器
su
vi /data/adb/sms_forwarder/bark.conf
```

5. 重启设备 — 模块自动启动

## 配置说明

配置文件位置：`/data/adb/sms_forwarder/bark.conf`

模块更新时会保留现有配置，仅全新安装才创建默认配置。

### Bark 推送地址（必填）

```bash
BARK_URLS=(
    https://api.day.app/你的KEY
    https://bark.example.com/另一个KEY
)
```

### 功能开关

| 选项 | 默认值 | 说明 |
|------|--------|------|
| `FORWARD_SMS` | `true` | 是否转发短信 |
| `FORWARD_CALL` | `true` | 是否转发来电 |
| `LOOKUP_LOCATION` | `true` | 是否查询号码归属地 |

### 监控与性能

| 选项 | 默认值 | 说明 |
|------|--------|------|
| `MONITOR_MODE` | `auto` | `auto` / `event` / `poll` |
| `POLL_INTERVAL` | `5` | 轮询间隔，秒（poll 模式） |
| `EVENT_DELAY_SMS` | `1` | 事件触发后的延迟，秒 |
| `CALL_RING_POLL` | `2` | 来电检测轮询间隔，秒 |
| `HTTP_TIMEOUT` | `10` | HTTP 请求超时，秒 |
| `MAX_RETRIES` | `3` | 推送失败重试次数 |
| `RETRY_BACKOFF` | `2` | 重试退避基数，秒（实际间隔 = 基数 × 次数） |

### Bark 消息参数

| 选项 | 默认值 | 说明 |
|------|--------|------|
| `BARK_GROUP` | `SMSForwarder` | iOS 通知中心分组名 |
| `BARK_SOUND` | `minuet` | 推送铃声 |
| `BARK_ICON` | *（空）* | 自定义通知图标 URL |
| `BARK_LEVEL` | `timeSensitive` | `active` / `timeSensitive` / `passive` |

### 日志设置

| 选项 | 默认值 | 说明 |
|------|--------|------|
| `LOG_LEVEL` | `INFO` | `DEBUG` / `INFO` / `WARN` / `ERROR` |
| `LOG_MAX_LINES` | `2000` | 日志超出此行数时自动轮转 |

## 通知格式

**短信：**
```
标题：短信 10086 [SIM 1]
正文：2026-03-20 16:05:19
      尊敬的客户，您的套餐余量...
```

**来电：**
```
标题：来电 13800138000 [SIM 2]
正文：广东 深圳 中国移动
      2026-03-20 16:05:19
```

## 文件结构

```
SMSForwarder/
├── module.prop          # 模块元信息
├── service.sh           # 开机自启入口
├── customize.sh         # 安装脚本
├── uninstall.sh         # 卸载清理脚本
├── config/
│   └── bark.conf        # 默认配置模板
└── bin/
    ├── daemon.sh        # 主守护进程（含看门狗）
    ├── utils.sh         # 公共工具库（日志、HTTP、状态等）
    ├── bark_client.sh   # Bark API 客户端（含重试逻辑）
    ├── sms_monitor.sh   # 短信监控（两阶段查询）
    └── call_monitor.sh  # 来电监控（电话状态机）
```

**设备上的运行时路径：**

```
/data/adb/sms_forwarder/
├── bark.conf            # 用户配置（跨更新保留）
├── logs/
│   └── sms_forwarder.log
└── run/
    ├── daemon.pid
    └── last_sms_id
```

## 故障排查

**查看日志：**
```bash
su -c "cat /data/adb/sms_forwarder/logs/sms_forwarder.log"
```

**检查守护进程状态：**
```bash
su -c "cat /data/adb/sms_forwarder/run/daemon.pid && ps -p $(cat /data/adb/sms_forwarder/run/daemon.pid)"
```

**手动重启守护进程：**
```bash
su -c "pkill -f daemon.sh; sleep 1; sh /data/adb/modules/sms_forwarder/bin/daemon.sh &"
```

**重置短信状态**（如果在转发旧短信）：
```bash
su -c "rm -f /data/adb/sms_forwarder/run/last_sms_id"
```

## 升级方法

```bash
# 1. 停止旧守护进程
su -c "pkill -f daemon.sh"

# 2. 清除运行时状态
su -c "rm -rf /data/adb/sms_forwarder/run/"

# 3. 通过 KernelSU 管理器安装新 ZIP

# 4. 重启
```

`bark.conf` 配置会自动保留。

## 从源码构建

```bash
cd SMSForwarder
zip -r SMSForwarder-v1.0.0.zip \
    module.prop \
    service.sh \
    customize.sh \
    uninstall.sh \
    config/ \
    bin/ \
    -x '*.git*'
```

## 许可证

MIT
