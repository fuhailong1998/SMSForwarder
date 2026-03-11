#!/system/bin/sh

# ============================================================
# SMS/Call Forwarder Daemon
# 短信/来电 Bark 推送转发守护进程
# ============================================================

MODDIR="${0%/*}"
MODDIR="${MODDIR%/bin}"
CONFIG_DIR="/data/adb/sms_forwarder"
CONFIG_FILE="$CONFIG_DIR/config.conf"
STATE_DIR="$CONFIG_DIR/state"
CACHE_DIR="$CONFIG_DIR/cache"
LOG_FILE="$CONFIG_DIR/forwarder.log"
MAX_LOG_SIZE=524288

# ======================== 工具函数 ========================

log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date)

    case "$level" in
        E) [ "${LOG_LEVEL:-2}" -ge 1 ] && echo "[$timestamp] [ERROR] $msg" >> "$LOG_FILE" ;;
        I) [ "${LOG_LEVEL:-2}" -ge 2 ] && echo "[$timestamp] [INFO]  $msg" >> "$LOG_FILE" ;;
        D) [ "${LOG_LEVEL:-2}" -ge 3 ] && echo "[$timestamp] [DEBUG] $msg" >> "$LOG_FILE" ;;
    esac

    # 日志轮转
    if [ -f "$LOG_FILE" ]; then
        local log_size
        log_size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$log_size" -gt "$MAX_LOG_SIZE" ]; then
            tail -c $((MAX_LOG_SIZE / 2)) "$LOG_FILE" > "${LOG_FILE}.tmp"
            mv "${LOG_FILE}.tmp" "$LOG_FILE"
        fi
    fi
}

json_escape() {
    printf '%s' "$1" | awk '
    BEGIN { ORS="" }
    {
        gsub(/\\/, "\\\\")
        gsub(/"/, "\\\"")
        gsub(/\t/, "\\t")
        gsub(/\r/, "")
        if (NR > 1) print "\\n"
        print
    }'
}

format_date() {
    local ts_ms="$1"
    [ -z "$ts_ms" ] && echo "未知时间" && return

    local ts_s=$((ts_ms / 1000))

    # 尝试多种 date 格式（兼容不同 Android 环境）
    busybox date -d "@$ts_s" "+%Y-%m-%d %H:%M:%S" 2>/dev/null && return
    date -d "@$ts_s" "+%Y-%m-%d %H:%M:%S" 2>/dev/null && return
    toybox date -d "@$ts_s" "+%Y-%m-%d %H:%M:%S" 2>/dev/null && return

    echo "$ts_ms"
}

url_encode() {
    printf '%s' "$1" | awk '
    BEGIN {
        for (i = 0; i <= 255; i++) {
            ord[sprintf("%c", i)] = i
        }
    }
    {
        n = split($0, chars, "")
        for (i = 1; i <= n; i++) {
            c = chars[i]
            if (c ~ /[A-Za-z0-9._~-]/) {
                printf "%s", c
            } else {
                printf "%%%02X", ord[c]
            }
        }
    }'
}

# ======================== Bark 推送 ========================

send_bark() {
    local title="$1"
    local body="$2"
    local group="$3"

    local title_escaped
    local body_escaped
    title_escaped=$(json_escape "$title")
    body_escaped=$(json_escape "$body")

    local json_payload="{\"title\":\"${title_escaped}\",\"body\":\"${body_escaped}\",\"group\":\"${group}\",\"isArchive\":1}"

    echo "$BARK_URLS" | while IFS= read -r url; do
        url=$(echo "$url" | tr -d ' \t\r')
        [ -z "$url" ] && continue
        # 跳过注释行
        case "$url" in \#*) continue ;; esac

        log D "发送推送到: $url"

        curl -sk -X POST "$url" \
            -H "Content-Type: application/json; charset=utf-8" \
            -d "$json_payload" \
            --connect-timeout 10 \
            --max-time 30 \
            > /dev/null 2>&1

        if [ $? -eq 0 ]; then
            log D "推送成功: $url"
        else
            log E "推送失败: $url"
        fi
    done
}

# ======================== SIM 卡信息 ========================

get_sim_name() {
    local sub_id="$1"

    # 优先使用用户自定义卡名
    if [ -n "$sub_id" ]; then
        eval "local custom_name=\$SIM${sub_id}_NAME"
        [ -n "$custom_name" ] && echo "$custom_name" && return
    fi

    # 查询系统 SIM 卡显示名称
    local sim_info
    sim_info=$(content query --uri content://telephony/siminfo \
        --projection "display_name:sim_slot_index" \
        --where "_id=$sub_id" 2>/dev/null | grep "^Row:" | head -1)

    if [ -n "$sim_info" ]; then
        local display_name
        display_name=$(echo "$sim_info" | sed 's/.*display_name=\(.*\), sim_slot_index=.*/\1/' | tr -d '\r')
        local slot_index
        slot_index=$(echo "$sim_info" | sed 's/.*sim_slot_index=\(.*\)/\1/' | tr -d '\r')

        if [ -n "$display_name" ] && [ "$display_name" != "NULL" ]; then
            echo "${display_name} (卡槽$((slot_index + 1)))"
            return
        fi
    fi

    echo "SIM $sub_id"
}

# ======================== 号码归属地 ========================

get_phone_location() {
    local phone="$1"
    phone=$(echo "$phone" | sed 's/^+86//; s/^86//; s/[^0-9]//g')

    # 号码太短无法查询
    [ ${#phone} -lt 7 ] && echo "未知" && return

    # 检查缓存
    local cache_file="$CACHE_DIR/loc_${phone}"
    if [ -f "$cache_file" ]; then
        cat "$cache_file"
        return
    fi

    if [ -z "$PHONE_LOCATION_API" ]; then
        echo "未知"
        return
    fi

    log D "查询号码归属地: $phone"

    local response
    response=$(curl -sk "${PHONE_LOCATION_API}${phone}" \
        --connect-timeout 5 \
        --max-time 10 2>/dev/null)

    if [ -z "$response" ]; then
        log E "归属地查询失败: $phone (无响应)"
        echo "未知"
        return
    fi

    local province city sp location

    # 尝试解析多种常见 API 返回格式
    # 格式1: {"province":"xx","city":"xx"}
    province=$(echo "$response" | grep -o '"province":"[^"]*"' | head -1 | cut -d'"' -f4)
    city=$(echo "$response" | grep -o '"city":"[^"]*"' | head -1 | cut -d'"' -f4)
    sp=$(echo "$response" | grep -o '"sp":"[^"]*"' | head -1 | cut -d'"' -f4)

    # 格式2: {"prov":"xx","city":"xx"} (百度等)
    if [ -z "$province" ]; then
        province=$(echo "$response" | grep -o '"prov":"[^"]*"' | head -1 | cut -d'"' -f4)
    fi

    # 格式3: {"data":[{"prov":"xx","city":"xx"}]}
    if [ -z "$province" ]; then
        province=$(echo "$response" | grep -o '"prov":"[^"]*"' | head -1 | cut -d'"' -f4)
        city=$(echo "$response" | grep -o '"city":"[^"]*"' | head -1 | cut -d'"' -f4)
    fi

    if [ -n "$province" ] && [ -n "$city" ]; then
        if [ "$province" = "$city" ]; then
            location="$city"
        else
            location="${province} ${city}"
        fi
    elif [ -n "$province" ]; then
        location="$province"
    else
        location="未知"
    fi

    [ -n "$sp" ] && location="${location} ${sp}"

    # 写入缓存
    echo "$location" > "$cache_file"
    echo "$location"
}

# ======================== 短信监控 ========================

check_new_sms() {
    [ "$FORWARD_SMS" != "true" ] && return

    local new_ids
    new_ids=$(content query --uri content://sms/inbox \
        --projection "_id" \
        --where "_id>$LAST_SMS_ID" \
        --sort "_id ASC" 2>/dev/null | grep -o '_id=[0-9]*' | cut -d= -f2)

    [ -z "$new_ids" ] && return

    # 防洪保护：如果一次发现过多未处理短信，说明是首次运行或状态丢失，跳过历史消息
    local id_count
    id_count=$(echo "$new_ids" | wc -l)
    if [ "$id_count" -gt "${MAX_FORWARD_BATCH:-10}" ]; then
        log I "检测到 ${id_count} 条未处理短信（超过阈值 ${MAX_FORWARD_BATCH:-10}），跳过历史消息"
        LAST_SMS_ID=$(echo "$new_ids" | tail -1)
        echo "$LAST_SMS_ID" > "$STATE_DIR/last_sms_id"
        log I "短信 ID 已更新为: $LAST_SMS_ID"
        return
    fi

    for id in $new_ids; do
        log I "发现新短信 ID: $id"

        # 分别查询元数据和正文（避免正文中的特殊字符干扰解析）
        local meta
        meta=$(content query --uri content://sms/inbox \
            --projection "_id:address:date:sub_id" \
            --where "_id=$id" 2>/dev/null | grep "^Row:" | head -1)

        [ -z "$meta" ] && continue

        local address date_ms sub_id
        address=$(echo "$meta" | sed 's/.*address=\(.*\), date=.*/\1/' | tr -d '\r')
        date_ms=$(echo "$meta" | sed 's/.*date=\([0-9]*\).*/\1/')
        sub_id=$(echo "$meta" | sed 's/.*sub_id=\(.*\)/\1/' | tr -d '\r')

        # 单独查询正文（整行 Row: 0 body= 之后的内容都是正文）
        local body_raw body
        body_raw=$(content query --uri content://sms/inbox \
            --projection "body" \
            --where "_id=$id" 2>/dev/null)
        body=$(echo "$body_raw" | sed '1{s/^Row: [0-9]* body=//;}')

        local sim_name formatted_date
        sim_name=$(get_sim_name "$sub_id")
        formatted_date=$(format_date "$date_ms")

        local title="📩 新短信"
        local msg
        msg=$(printf '来源号码: %s\n卡槽备注: %s\n接收时间: %s\n\n短信内容:\n%s' \
            "$address" "$sim_name" "$formatted_date" "$body")

        send_bark "$title" "$msg" "sms"

        LAST_SMS_ID=$id
        echo "$id" > "$STATE_DIR/last_sms_id"

        log I "短信已转发: 来自=$address 卡槽=$sim_name"
    done
}

# ======================== 来电监控 ========================

check_new_calls() {
    [ "$FORWARD_CALL" != "true" ] && return

    content query --uri content://call_log/calls \
        --projection "_id:number:type:date:sub_id" \
        --where "_id>$LAST_CALL_ID AND (type=1 OR type=3)" \
        --sort "_id ASC" 2>/dev/null | grep "^Row:" > "$STATE_DIR/tmp_calls" 2>/dev/null

    [ ! -s "$STATE_DIR/tmp_calls" ] && return

    # 防洪保护：同短信逻辑
    local call_count
    call_count=$(wc -l < "$STATE_DIR/tmp_calls")
    if [ "$call_count" -gt "${MAX_FORWARD_BATCH:-10}" ]; then
        log I "检测到 ${call_count} 条未处理通话（超过阈值 ${MAX_FORWARD_BATCH:-10}），跳过历史记录"
        LAST_CALL_ID=$(grep -o '_id=[0-9]*' "$STATE_DIR/tmp_calls" | tail -1 | cut -d= -f2)
        echo "$LAST_CALL_ID" > "$STATE_DIR/last_call_id"
        log I "通话 ID 已更新为: $LAST_CALL_ID"
        rm -f "$STATE_DIR/tmp_calls"
        return
    fi

    while IFS= read -r line; do
        [ -z "$line" ] && continue

        local id number call_type date_ms sub_id
        id=$(echo "$line" | sed 's/.*_id=\([0-9]*\).*/\1/')
        number=$(echo "$line" | sed 's/.*number=\(.*\), type=.*/\1/' | tr -d '\r')
        call_type=$(echo "$line" | sed 's/.*type=\([0-9]*\).*/\1/')
        date_ms=$(echo "$line" | sed 's/.*date=\([0-9]*\).*/\1/')
        sub_id=$(echo "$line" | sed 's/.*sub_id=\(.*\)/\1/' | tr -d '\r')

        log I "发现新通话记录 ID: $id (号码=$number 类型=$call_type)"

        local sim_name location type_name
        sim_name=$(get_sim_name "$sub_id")
        location=$(get_phone_location "$number")

        type_name="来电"
        [ "$call_type" = "3" ] && type_name="未接来电"

        local title="📞 ${type_name}"
        local msg
        msg=$(printf '来源号码: %s\n卡槽备注: %s\n号码归属地: %s' \
            "$number" "$sim_name" "$location")

        send_bark "$title" "$msg" "call"

        LAST_CALL_ID=$id
        echo "$id" > "$STATE_DIR/last_call_id"

        log I "通话已转发: 号码=$number 类型=$type_name 卡槽=$sim_name 归属地=$location"
    done < "$STATE_DIR/tmp_calls"

    rm -f "$STATE_DIR/tmp_calls"
}

# ======================== 主流程 ========================

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log E "配置文件不存在: $CONFIG_FILE"
        echo "配置文件不存在: $CONFIG_FILE" >&2
        exit 1
    fi
    . "$CONFIG_FILE"

    if [ -z "$BARK_URLS" ]; then
        log E "BARK_URLS 未配置，请编辑 $CONFIG_FILE"
        echo "BARK_URLS 未配置" >&2
        exit 1
    fi

    POLL_INTERVAL="${POLL_INTERVAL:-10}"
    FORWARD_SMS="${FORWARD_SMS:-true}"
    FORWARD_CALL="${FORWARD_CALL:-true}"
    LOG_LEVEL="${LOG_LEVEL:-2}"
}

is_valid_id() {
    echo "$1" | grep -qE '^[0-9]+$' 2>/dev/null
}

get_max_sms_id() {
    content query --uri content://sms/inbox \
        --projection "_id" --sort "_id DESC" 2>/dev/null | \
        grep -o '_id=[0-9]*' | head -1 | cut -d= -f2
}

get_max_call_id() {
    content query --uri content://call_log/calls \
        --projection "_id" --sort "_id DESC" 2>/dev/null | \
        grep -o '_id=[0-9]*' | head -1 | cut -d= -f2
}

wait_content_provider() {
    local retries=0
    while [ $retries -lt 12 ]; do
        if content query --uri content://sms --projection "_id" 2>/dev/null | grep -q "Row:"; then
            log I "内容提供者已就绪"
            return 0
        fi
        retries=$((retries + 1))
        log I "等待内容提供者就绪... ($retries/12)"
        sleep 5
    done
    log E "内容提供者等待超时"
    return 1
}

init_state() {
    mkdir -p "$STATE_DIR" "$CACHE_DIR"

    wait_content_provider

    # 读取或初始化短信 ID（去除空白字符后验证是否为有效数字）
    if [ -f "$STATE_DIR/last_sms_id" ]; then
        LAST_SMS_ID=$(cat "$STATE_DIR/last_sms_id" | tr -d ' \t\r\n')
    fi
    if ! is_valid_id "$LAST_SMS_ID"; then
        log I "短信状态无效或不存在，初始化为当前最新 ID"
        LAST_SMS_ID=$(get_max_sms_id)
        if ! is_valid_id "$LAST_SMS_ID"; then
            log E "无法获取当前短信 ID，将在首次轮询时通过防洪保护自动修正"
            LAST_SMS_ID=0
        fi
        echo "$LAST_SMS_ID" > "$STATE_DIR/last_sms_id"
        log I "初始化短信 ID: $LAST_SMS_ID"
    fi

    # 读取或初始化通话 ID
    if [ -f "$STATE_DIR/last_call_id" ]; then
        LAST_CALL_ID=$(cat "$STATE_DIR/last_call_id" | tr -d ' \t\r\n')
    fi
    if ! is_valid_id "$LAST_CALL_ID"; then
        log I "通话状态无效或不存在，初始化为当前最新 ID"
        LAST_CALL_ID=$(get_max_call_id)
        if ! is_valid_id "$LAST_CALL_ID"; then
            log E "无法获取当前通话 ID，将在首次轮询时通过防洪保护自动修正"
            LAST_CALL_ID=0
        fi
        echo "$LAST_CALL_ID" > "$STATE_DIR/last_call_id"
        log I "初始化通话 ID: $LAST_CALL_ID"
    fi
}

cleanup() {
    log I "守护进程收到退出信号，正在停止..."
    rm -f "$STATE_DIR/tmp_calls"
    exit 0
}

main() {
    trap cleanup INT TERM

    log I "========================================"
    log I "SMS/Call Forwarder 守护进程启动"
    log I "========================================"

    load_config
    init_state

    log I "配置信息: 轮询间隔=${POLL_INTERVAL}s 短信转发=${FORWARD_SMS} 来电转发=${FORWARD_CALL}"
    log I "当前状态: 短信ID=$LAST_SMS_ID 通话ID=$LAST_CALL_ID"

    while true; do
        check_new_sms
        check_new_calls
        sleep "$POLL_INTERVAL"
    done
}

main
