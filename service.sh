#!/system/bin/sh

MODDIR="${0%/*}"
DAEMON="$MODDIR/bin/sms_forwarder.sh"
CONFIG_DIR="/data/adb/sms_forwarder"
LOG_FILE="$CONFIG_DIR/forwarder.log"
PID_FILE="$CONFIG_DIR/forwarder.pid"

# 等待系统启动完成
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 5
done

# 等待系统服务完全就绪（电话/短信等服务需要时间初始化）
sleep 30

# 检查配置文件是否存在
if [ ! -f "$CONFIG_DIR/config.conf" ]; then
    echo "[$(date)] [ERROR] 配置文件不存在: $CONFIG_DIR/config.conf" >> "$LOG_FILE"
    exit 1
fi

# 终止可能残留的旧进程
if [ -f "$PID_FILE" ]; then
    old_pid=$(cat "$PID_FILE")
    kill "$old_pid" 2>/dev/null
    rm -f "$PID_FILE"
fi

# 启动守护进程
nohup sh "$DAEMON" >> "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"
