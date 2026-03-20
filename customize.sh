#!/system/bin/sh
# ============================================================
# SMS Forwarder - KSU/SukiSU 安装脚本
# customize.sh 在模块安装/更新时由管理器调用
# ============================================================

# KSU 安装框架提供的变量:
# MODPATH - 模块将被安装到的路径
# 详见 https://kernelsu.org/guide/how-to-build-a-module.html

SKIPUNZIP=1

CONFIG_DIR="/data/adb/sms_forwarder"

ui_print "==============================="
ui_print "  SMS Forwarder v1.0.0"
ui_print "  短信/来电 Bark 推送模块"
ui_print "==============================="

# ---- 解压模块文件 ----
ui_print "- 解压模块文件..."
unzip -o "$ZIPFILE" -x 'META-INF/*' -d "$MODPATH" >&2

# ---- 设置脚本执行权限 ----
ui_print "- 设置文件权限..."
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
set_perm "$MODPATH/service.sh" 0 0 0755

# ---- 初始化配置目录 ----
ui_print "- 初始化配置..."
mkdir -p "$CONFIG_DIR"
mkdir -p "${CONFIG_DIR}/run"
mkdir -p "${CONFIG_DIR}/logs"

if [ ! -f "${CONFIG_DIR}/bark.conf" ]; then
    cp "${MODPATH}/config/bark.conf" "${CONFIG_DIR}/bark.conf"
    ui_print "- 已创建默认配置: ${CONFIG_DIR}/bark.conf"
    ui_print ""
    ui_print "  !! 重要 !!"
    ui_print "  请编辑配置文件添加你的 Bark 推送地址:"
    ui_print "  ${CONFIG_DIR}/bark.conf"
    ui_print ""
else
    ui_print "- 检测到已有配置，保留不覆盖"
fi

# ---- 检测依赖 ----
ui_print "- 检测运行环境..."

if command -v curl >/dev/null 2>&1; then
    ui_print "  ✓ curl 已就绪"
elif command -v wget >/dev/null 2>&1; then
    ui_print "  ✓ wget 已就绪"
else
    ui_print "  ✗ 警告: 未找到 curl 或 wget"
    ui_print "    模块可能无法发送推送通知"
    ui_print "    请安装 busybox 模块或包含 curl 的工具包"
fi

if command -v content >/dev/null 2>&1; then
    ui_print "  ✓ content 命令已就绪"
else
    ui_print "  ✗ 警告: 未找到 content 命令"
    ui_print "    短信/通话记录查询可能异常"
fi

ui_print ""
ui_print "==============================="
ui_print "  安装完成!"
ui_print "  配置文件: ${CONFIG_DIR}/bark.conf"
ui_print "  日志目录: ${CONFIG_DIR}/logs/"
ui_print "  重启后自动生效"
ui_print "==============================="
