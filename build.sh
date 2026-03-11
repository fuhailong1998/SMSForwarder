#!/bin/bash

# SMS/Call Forwarder 模块打包脚本

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULE_NAME="SMSForwarder"
VERSION=$(grep '^version=' "$SCRIPT_DIR/module.prop" | cut -d= -f2)
OUTPUT_FILE="${SCRIPT_DIR}/${MODULE_NAME}-${VERSION}.zip"

echo "========================================"
echo "  打包 SMS/Call Forwarder 模块"
echo "  版本: $VERSION"
echo "========================================"

rm -f "$OUTPUT_FILE"

cd "$SCRIPT_DIR" || exit 1

FILES="module.prop customize.sh service.sh uninstall.sh config.conf.example bin/sms_forwarder.sh META-INF/com/google/android/update-binary META-INF/com/google/android/updater-script"

if command -v zip >/dev/null 2>&1; then
    zip -r9 "$OUTPUT_FILE" $FILES
else
    python3 -c "
import zipfile, sys
files = sys.argv[1:]
with zipfile.ZipFile('$OUTPUT_FILE', 'w', zipfile.ZIP_DEFLATED) as zf:
    for f in files:
        zf.write(f)
" $FILES
fi

echo ""
echo "打包完成: $OUTPUT_FILE"
echo "文件大小: $(du -h "$OUTPUT_FILE" | cut -f1)"
echo ""
echo "安装方式:"
echo "  1. 将 zip 文件传输到手机"
echo "  2. 在 SukiSU Ultra / KernelSU 中安装模块"
echo "  3. 编辑 /data/adb/sms_forwarder/config.conf"
echo "  4. 重启手机"
echo "========================================"
