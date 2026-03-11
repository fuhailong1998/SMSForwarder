#!/system/bin/sh

SKIPUNZIP=1

CONFIG_DIR="/data/adb/sms_forwarder"

ui_print "========================================"
ui_print "  📩 SMS/Call Forwarder (Bark)"
ui_print "  短信/来电 Bark 推送转发模块"
ui_print "========================================"
ui_print ""

# 解压模块文件
ui_print "- 解压模块文件..."
unzip -o "$ZIPFILE" -x 'META-INF/*' -d "$MODPATH" >&2

# 创建数据目录
ui_print "- 创建数据目录..."
mkdir -p "$CONFIG_DIR"
mkdir -p "$CONFIG_DIR/state"
mkdir -p "$CONFIG_DIR/cache"

# 初始化配置文件（不覆盖已有配置）
if [ ! -f "$CONFIG_DIR/config.conf" ]; then
    cp "$MODPATH/config.conf.example" "$CONFIG_DIR/config.conf"
    ui_print ""
    ui_print "⚠ 首次安装，已创建默认配置文件"
    ui_print "  请编辑: $CONFIG_DIR/config.conf"
    ui_print "  填入你的 Bark 推送地址后重启生效"
    ui_print ""
else
    ui_print "- 检测到已有配置文件，保留不覆盖"
fi

# 设置权限
ui_print "- 设置文件权限..."
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/bin/sms_forwarder.sh" 0 0 0755
set_perm_recursive "$CONFIG_DIR" 0 0 0755 0644

ui_print ""
ui_print "- 安装完成！"
ui_print ""
ui_print "配置文件路径: $CONFIG_DIR/config.conf"
ui_print "日志文件路径: $CONFIG_DIR/forwarder.log"
ui_print ""
ui_print "========================================"
