# SMS/Call Forwarder (Bark)

📩 短信/来电转发到 Bark 推送服务 | Forward SMS and incoming calls to Bark push notification service

适用于 SukiSU Ultra / KernelSU / Magisk 的 Android 模块，当手机收到新短信或来电时，自动通过 Bark 推送到指定设备。

## 功能特性

- **短信转发**：来源号码、短信内容、卡槽备注、接收时间
- **来电转发**：来源号码、卡槽备注、号码归属地
- **多 Bark 地址**：支持配置多个推送目标
- **防洪保护**：首次启动不转发历史消息，避免刷屏

## 环境要求

- Android 设备已 Root（SukiSU Ultra / KernelSU / Magisk）
- 已安装 Bark 客户端并获取推送 Key

## 安装步骤

1. 运行 `bash build.sh` 生成 `SMSForwarder-v1.0.0.zip`
2. 将 zip 传输到手机，在 SukiSU Ultra 中安装模块
3. 编辑配置文件 `/data/adb/sms_forwarder/config.conf`，填入 Bark 推送地址
4. 重启手机

## 配置说明

| 配置项 | 说明 | 默认值 |
|--------|------|--------|
| `BARK_URLS` | Bark 推送地址，支持多行 | 必填 |
| `POLL_INTERVAL` | 轮询间隔（秒） | 10 |
| `FORWARD_SMS` | 是否转发短信 | true |
| `FORWARD_CALL` | 是否转发来电 | true |
| `SIM1_NAME` / `SIM2_NAME` | 自定义卡槽名称 | 空 |
| `PHONE_LOCATION_API` | 号码归属地查询 API | 空 |
| `MAX_FORWARD_BATCH` | 单次最大转发条数（防洪） | 10 |
| `LOG_LEVEL` | 日志级别 0-3 | 2 |

## 文件结构

```
SMSForwarder/
├── META-INF/          # 安装引导
├── bin/
│   └── sms_forwarder.sh   # 核心守护进程
├── module.prop
├── customize.sh       # 安装脚本
├── service.sh         # 开机启动
├── uninstall.sh       # 卸载清理
├── config.conf.example
└── build.sh           # 打包脚本
```

## 日志

- 日志路径：`/data/adb/sms_forwarder/forwarder.log`
- 状态文件：`/data/adb/sms_forwarder/state/`

## License

MIT
