#!/system/bin/sh

CONFIG_DIR="/data/adb/sms_forwarder"
PID_FILE="$CONFIG_DIR/forwarder.pid"

# 终止守护进程
if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE")
    kill "$pid" 2>/dev/null
    rm -f "$PID_FILE"
fi

# 清理数据目录（保留配置以防重新安装）
rm -rf "$CONFIG_DIR/state"
rm -rf "$CONFIG_DIR/cache"
rm -f "$CONFIG_DIR/forwarder.log"
rm -f "$CONFIG_DIR/forwarder.pid"

# 如果用户希望完全删除配置，取消下面的注释
# rm -rf "$CONFIG_DIR"
