#!/system/bin/sh
# ============================================================
# SMS Forwarder - 卸载清理脚本
# KSU/SukiSU 在用户卸载模块时执行
# ============================================================

CONFIG_DIR="/data/adb/sms_forwarder"

# 终止正在运行的守护进程
if [ -f "${CONFIG_DIR}/run/daemon.pid" ]; then
    pid="$(cat "${CONFIG_DIR}/run/daemon.pid" 2>/dev/null)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        sleep 1
        # 如果还没退出，强制终止
        kill -9 "$pid" 2>/dev/null
    fi
fi

# 清理运行时数据（保留用户配置和日志）
rm -rf "${CONFIG_DIR}/run"

# 提示用户手动清理
# 不自动删除 bark.conf 和 logs，防止用户重装时丢失配置
# 用户如需完全清理，可手动删除: rm -rf /data/adb/sms_forwarder
