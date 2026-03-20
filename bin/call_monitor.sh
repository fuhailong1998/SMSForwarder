#!/system/bin/sh
# ============================================================
# SMS Forwarder - 来电实时监控与转发
# 通过 dumpsys telephony.registry 检测 RINGING 状态
# 电话响铃时立即推送 Bark 通知，延迟约 1-2 秒
# ============================================================

# 依赖: utils.sh, bark_client.sh (由 daemon.sh 统一加载)

# 通话状态常量 (TelephonyManager)
_PHONE_STATE_IDLE=0
_PHONE_STATE_RINGING=1
_PHONE_STATE_OFFHOOK=2

# 内部状态跟踪
_prev_state="idle"
_last_notified_number=""

# 从 dumpsys telephony.registry 解析当前通话状态
# 输出格式: phone_id|call_state|incoming_number（每个 SIM 一行）
_parse_telephony_state() {
    dumpsys telephony.registry 2>/dev/null | awk '
    /Phone Id=/ {
        phone_id = $0
        gsub(/.*Phone Id=/, "", phone_id)
        gsub(/[^0-9]/, "", phone_id)
    }
    /mCallState=/ {
        state = $0
        gsub(/.*mCallState=/, "", state)
        gsub(/[^0-9]/, "", state)
    }
    /mCallIncomingNumber=/ {
        number = $0
        gsub(/.*mCallIncomingNumber=/, "", number)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", number)
        print phone_id "|" state "|" number
    }'
}

# 检测是否有来电正在响铃
# 返回值: 0=正在响铃 1=未响铃
# 设置全局变量: _RING_NUMBER, _RING_SLOT
check_ringing() {
    local state_lines
    state_lines="$(_parse_telephony_state)"

    if [ -z "$state_lines" ]; then
        _RING_NUMBER=""
        _RING_SLOT=""
        return 1
    fi

    # 查找 callState=1 (RINGING) 的 SIM 卡
    local ringing_line
    ringing_line="$(echo "$state_lines" | grep "|${_PHONE_STATE_RINGING}|" | head -1)"

    if [ -n "$ringing_line" ]; then
        local phone_id
        phone_id="$(echo "$ringing_line" | cut -d'|' -f1)"
        _RING_NUMBER="$(echo "$ringing_line" | cut -d'|' -f3)"
        _RING_SLOT="SIM $((phone_id + 1))"
        return 0
    fi

    _RING_NUMBER=""
    _RING_SLOT=""
    return 1
}

# 构建来电通知并发送
_send_ring_notification() {
    local number="$1"
    local sim_slot="$2"

    local title="来电 ${number} [${sim_slot}]"
    local now
    now="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '')"

    local content=""

    # 归属地查询（无标签）
    if [ "${LOOKUP_LOCATION}" = "true" ]; then
        local location
        location="$(lookup_phone_location "$number")"
        [ -n "$location" ] && content="$location"
    fi

    # 时间（无标签）
    if [ -n "$now" ]; then
        if [ -n "$content" ]; then
            content="$(printf '%s\n%s' "$content" "$now")"
        else
            content="$now"
        fi
    fi

    [ -z "$content" ] && content="${number}"

    send_bark_notification "$title" "$content"
}

# 主监控循环：轮询 telephony.registry 检测响铃状态变化
# 状态机: IDLE → RINGING(发通知) → IDLE/OFFHOOK(重置)
run_call_monitor() {
    local poll_interval="${CALL_RING_POLL:-2}"
    log_info "来电实时监控已启动 (poll=${poll_interval}s)"

    _prev_state="idle"
    _last_notified_number=""

    while true; do
        [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
        [ "${FORWARD_CALL}" != "true" ] && { sleep "$poll_interval"; continue; }

        if check_ringing; then
            # 当前正在响铃
            if [ "$_prev_state" != "ringing" ]; then
                # 状态转换: IDLE/OFFHOOK → RINGING（新来电）
                if [ -n "$_RING_NUMBER" ] && [ "$_RING_NUMBER" != "$_last_notified_number" ]; then
                    log_info "检测到来电: ${_RING_NUMBER} [${_RING_SLOT}]"
                    _send_ring_notification "$_RING_NUMBER" "$_RING_SLOT"
                    _last_notified_number="$_RING_NUMBER"
                fi
                _prev_state="ringing"
            fi
        else
            # 当前未响铃
            if [ "$_prev_state" = "ringing" ]; then
                # 状态转换: RINGING → IDLE/OFFHOOK（通话结束或接听）
                log_debug "响铃结束: ${_last_notified_number}"
                _prev_state="idle"
                _last_notified_number=""
            fi
        fi

        sleep "$poll_interval"
    done
}

# 初始化通话监控（无需状态文件，实时检测无需历史追踪）
init_call_state() {
    log_info "来电监控初始化完成（实时响铃检测模式）"
}
