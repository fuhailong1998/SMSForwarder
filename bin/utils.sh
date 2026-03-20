#!/system/bin/sh
# ============================================================
# SMS Forwarder - 公共工具函数库
# ============================================================

MODDIR="${0%/*}/.."
CONFIG_DIR="/data/adb/sms_forwarder"
CONFIG_FILE="${CONFIG_DIR}/bark.conf"
STATE_DIR="${CONFIG_DIR}/run"
LOG_DIR="${CONFIG_DIR}/logs"
LOG_FILE="${LOG_DIR}/sms_forwarder.log"
PID_FILE="${STATE_DIR}/daemon.pid"
SMS_STATE_FILE="${STATE_DIR}/last_sms_id"
CALL_STATE_FILE="${STATE_DIR}/last_call_id"

# 确保运行目录存在
ensure_dirs() {
    mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR"
    chmod 700 "$CONFIG_DIR"
}

# ----------------------------------------------------------
# 日志系统
# ----------------------------------------------------------

_log_level_num() {
    case "$1" in
        DEBUG) echo 0 ;;
        INFO)  echo 1 ;;
        WARN)  echo 2 ;;
        ERROR) echo 3 ;;
        *)     echo 1 ;;
    esac
}

log_msg() {
    local level="$1"
    shift
    local msg="$*"
    local configured_level="${LOG_LEVEL:-INFO}"

    local level_num=$(_log_level_num "$level")
    local configured_num=$(_log_level_num "$configured_level")

    [ "$level_num" -lt "$configured_num" ] && return

    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'unknown')"
    local line="[${timestamp}] [${level}] ${msg}"

    echo "$line" >> "$LOG_FILE" 2>/dev/null

    # 日志轮转
    local max_lines="${LOG_MAX_LINES:-2000}"
    if [ -f "$LOG_FILE" ]; then
        local current_lines
        current_lines="$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)"
        if [ "$current_lines" -gt "$max_lines" ]; then
            local keep=$((max_lines / 2))
            tail -n "$keep" "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null
            mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null
        fi
    fi
}

log_debug() { log_msg "DEBUG" "$@"; }
log_info()  { log_msg "INFO"  "$@"; }
log_warn()  { log_msg "WARN"  "$@"; }
log_error() { log_msg "ERROR" "$@"; }

# ----------------------------------------------------------
# 配置加载
# ----------------------------------------------------------

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "配置文件不存在: ${CONFIG_FILE}"
        return 1
    fi
    . "$CONFIG_FILE"

    # 校验 Bark URL 是否已配置
    if [ "${#BARK_URLS[@]}" -eq 0 ]; then
        log_error "未配置任何 Bark 推送地址，请编辑 ${CONFIG_FILE}"
        return 1
    fi

    log_info "配置加载完成: ${#BARK_URLS[@]} 个 Bark 地址"
    return 0
}

# ----------------------------------------------------------
# JSON 字符串转义（不依赖 jq）
# ----------------------------------------------------------

json_escape() {
    printf '%s' "$1" | \
        sed 's/\\/\\\\/g' | \
        sed 's/"/\\"/g' | \
        sed 's/	/\\t/g' | \
        tr -d '\r' | \
        awk '{if(NR>1) printf "\\n"; printf "%s", $0}'
}

# ----------------------------------------------------------
# 日期格式化（毫秒时间戳 -> 可读格式）
# ----------------------------------------------------------

_TZ_OFFSET_SEC=""

# 获取本地时区偏移（秒），只计算一次
_get_tz_offset() {
    if [ -n "$_TZ_OFFSET_SEC" ]; then
        echo "$_TZ_OFFSET_SEC"
        return
    fi

    local tz_str
    tz_str="$(date +%z 2>/dev/null)"

    if [ -n "$tz_str" ]; then
        local sign=1
        case "$tz_str" in -*) sign=-1; tz_str="${tz_str#-}" ;; +*) tz_str="${tz_str#+}" ;; esac
        local h="${tz_str%??}"
        local m="${tz_str#??}"
        case "$h" in ''|*[!0-9]*) h=0 ;; esac
        case "$m" in ''|*[!0-9]*) m=0 ;; esac
        _TZ_OFFSET_SEC=$(( sign * (h * 3600 + m * 60) ))
    else
        _TZ_OFFSET_SEC=0
    fi

    echo "$_TZ_OFFSET_SEC"
}

# 纯 awk 实现的 epoch 秒转日期（不依赖 date 命令）
_epoch_to_date_awk() {
    local epoch="$1"
    local tz_off="$2"

    awk -v epoch="$epoch" -v tz="$tz_off" 'BEGIN {
        t = epoch + tz
        SECS_PER_DAY = 86400
        days = int(t / SECS_PER_DAY)
        rem = t - days * SECS_PER_DAY
        if (rem < 0) { days--; rem += SECS_PER_DAY }
        h = int(rem / 3600); rem -= h * 3600
        mi = int(rem / 60); s = rem - mi * 60

        y = 1970
        while (1) {
            lp = (y%4==0 && (y%100!=0 || y%400==0))
            diy = 365 + lp
            if (days < diy) break
            days -= diy; y++
        }

        split("31,28,31,30,31,30,31,31,30,31,30,31", md, ",")
        if (y%4==0 && (y%100!=0 || y%400==0)) md[2] = 29

        mo = 1
        while (mo <= 12 && days >= md[mo]+0) {
            days -= md[mo]+0; mo++
        }
        d = days + 1

        printf "%04d-%02d-%02d %02d:%02d:%02d\n", y, mo, d, h, mi, s
    }'
}

format_date_ms() {
    local ts_ms="$1"

    # 13 位毫秒时间戳 -> 10 位秒时间戳
    # 不用 shell 算术（$((ts_ms/1000))），因为 mksh 32 位整数会溢出
    local ts_s="${ts_ms%???}"
    [ -z "$ts_s" ] && ts_s="0"
    case "$ts_s" in ''|*[!0-9]*) ts_s="0" ;; esac

    local result

    # 方法 1: awk strftime（gawk / busybox awk）
    result="$(awk -v ts="$ts_s" 'BEGIN{print strftime("%Y-%m-%d %H:%M:%S",ts)}' 2>/dev/null)"
    case "$result" in 20*) echo "$result"; return ;; esac

    # 方法 2: toybox date
    result="$(date -D '%s' -d "$ts_s" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    case "$result" in 20*) echo "$result"; return ;; esac

    # 方法 3: GNU date
    result="$(date -d "@$ts_s" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    case "$result" in 20*) echo "$result"; return ;; esac

    # 方法 4: 纯 awk 计算（不依赖任何外部命令的日期转换能力）
    local tz_off
    tz_off="$(_get_tz_offset)"
    result="$(_epoch_to_date_awk "$ts_s" "$tz_off")"
    case "$result" in [12]*) echo "$result"; return ;; esac

    echo "$ts_ms"
}

# ----------------------------------------------------------
# SIM 卡槽识别
# ----------------------------------------------------------

get_sim_slot() {
    local sub_id="$1"
    if [ -z "$sub_id" ] || [ "$sub_id" = "null" ]; then
        echo "未知"
        return
    fi

    local sim_info
    sim_info="$(content query --uri content://telephony/siminfo \
        --projection '_id:sim_id' \
        --where "_id=${sub_id}" 2>/dev/null)"

    if echo "$sim_info" | grep -q 'sim_id='; then
        local slot
        slot="$(echo "$sim_info" | sed 's/.*sim_id=\([0-9]*\).*/\1/')"
        echo "SIM $((slot + 1))"
    else
        # 回退：多数设备 sub_id 直接对应卡槽
        echo "SIM ${sub_id}"
    fi
}

# ----------------------------------------------------------
# HTTP 客户端（自动选择 curl / wget）
# ----------------------------------------------------------

_http_client=""

detect_http_client() {
    if command -v curl >/dev/null 2>&1; then
        _http_client="curl"
    elif command -v wget >/dev/null 2>&1; then
        _http_client="wget"
    else
        log_error "未找到 curl 或 wget，无法发送 HTTP 请求"
        return 1
    fi
    log_debug "HTTP 客户端: ${_http_client}"
    return 0
}

# POST JSON 数据到指定 URL
# 参数: $1=URL $2=JSON_BODY
http_post_json() {
    local url="$1"
    local body="$2"
    local timeout="${HTTP_TIMEOUT:-10}"

    case "$_http_client" in
        curl)
            curl -s -S --connect-timeout "$timeout" -m "$((timeout * 2))" \
                -X POST "$url" \
                -H 'Content-Type: application/json; charset=utf-8' \
                -d "$body" 2>&1
            ;;
        wget)
            echo "$body" | wget -q -O - --timeout="$timeout" \
                --header='Content-Type: application/json; charset=utf-8' \
                --post-file=/dev/stdin "$url" 2>&1
            ;;
        *)
            log_error "无可用 HTTP 客户端"
            return 1
            ;;
    esac
}

# GET 请求
# 参数: $1=URL
http_get() {
    local url="$1"
    local timeout="${HTTP_TIMEOUT:-10}"

    case "$_http_client" in
        curl)
            curl -s -S --connect-timeout "$timeout" -m "$((timeout * 2))" \
                "$url" 2>&1
            ;;
        wget)
            wget -q -O - --timeout="$timeout" "$url" 2>&1
            ;;
        *)
            log_error "无可用 HTTP 客户端"
            return 1
            ;;
    esac
}

# ----------------------------------------------------------
# 号码归属地查询
# ----------------------------------------------------------

lookup_phone_location() {
    local number="$1"

    # 仅对 11 位手机号查询
    if ! echo "$number" | grep -qE '^1[3-9][0-9]{9}$'; then
        echo ""
        return
    fi

    local resp
    resp="$(http_get "https://cx.shouji.360.cn/phonearea.php?number=${number}" 2>/dev/null)"

    if [ -n "$resp" ]; then
        local province city carrier
        province="$(echo "$resp" | sed -n 's/.*"province"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        city="$(echo "$resp" | sed -n 's/.*"city"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        carrier="$(echo "$resp" | sed -n 's/.*"sp"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

        local location=""
        [ -n "$province" ] && location="${province}"
        [ -n "$city" ] && [ "$city" != "$province" ] && location="${location} ${city}"
        [ -n "$carrier" ] && location="${location} ${carrier}"

        echo "$location"
    else
        echo ""
    fi
}

# ----------------------------------------------------------
# 状态持久化
# ----------------------------------------------------------

read_state() {
    local file="$1"
    if [ -f "$file" ]; then
        local val
        val="$(cat "$file" 2>/dev/null)"
        # 只返回纯数字，防止脏数据
        case "$val" in
            ''|*[!0-9]*) echo "0" ;;
            *) echo "$val" ;;
        esac
    else
        echo "0"
    fi
}

write_state() {
    local file="$1"
    local value="$2"

    # 校验：只允许写入纯数字
    case "$value" in
        ''|*[!0-9]*)
            log_error "write_state 拒绝写入非法值: '${value}' -> ${file}"
            return 1
            ;;
    esac

    echo "$value" > "$file"
    if [ $? -ne 0 ]; then
        log_error "write_state 写入失败: ${file}"
        return 1
    fi

    log_debug "write_state: ${file} = ${value}"
}

# ----------------------------------------------------------
# 进程管理
# ----------------------------------------------------------

is_daemon_running() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid="$(cat "$PID_FILE" 2>/dev/null)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        rm -f "$PID_FILE"
    fi
    return 1
}

write_pid() {
    echo "$$" > "$PID_FILE"
}

cleanup_pid() {
    rm -f "$PID_FILE"
}

# ----------------------------------------------------------
# 网络就绪检测
# ----------------------------------------------------------

wait_for_network() {
    local max_wait=120
    local waited=0
    log_info "等待网络连接..."

    while [ "$waited" -lt "$max_wait" ]; do
        if ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1; then
            log_info "网络已就绪 (${waited}s)"
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done

    log_warn "等待网络超时 (${max_wait}s)，将继续运行"
    return 1
}
