# SMS Forwarder

[中文文档](README_CN.md)

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
