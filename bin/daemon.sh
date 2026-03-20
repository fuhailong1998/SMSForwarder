#!/system/bin/sh
# ============================================================
# SMS Forwarder - 主守护进程
# SMS 监控: content observe 事件驱动 / 轮询降级
# 来电监控: dumpsys telephony.registry 实时检测响铃
# ============================================================

SCRIPT_DIR="${0%/*}"
. "${SCRIPT_DIR}/utils.sh"
. "${SCRIPT_DIR}/bark_client.sh"
. "${SCRIPT_DIR}/sms_monitor.sh"
. "${SCRIPT_DIR}/call_monitor.sh"

_CHILD_PIDS=""

_daemon_cleanup() {
    log_info "守护进程收到退出信号，正在清理..."
    for pid in $_CHILD_PIDS; do
        kill "$pid" 2>/dev/null
    done
    wait 2>/dev/null
    cleanup_pid
    exit 0
}
trap _daemon_cleanup INT TERM HUP

_track_child() {
    _CHILD_PIDS="$_CHILD_PIDS $1"
}

# ----------------------------------------------------------
# SMS 事件驱动模式
# ----------------------------------------------------------

_test_content_observe() {
    content observe --uri content://sms/inbox 2>/dev/null &
    local test_pid=$!
    sleep 2
    if kill -0 "$test_pid" 2>/dev/null; then
        kill "$test_pid" 2>/dev/null
        wait "$test_pid" 2>/dev/null
        return 0
    fi
    return 1
}

_sms_event_loop() {
    local delay="${EVENT_DELAY_SMS:-1}"
    log_info "SMS 事件监听已启动 (delay=${delay}s)"

    while true; do
        content observe --uri content://sms/inbox 2>/dev/null | while IFS= read -r _line; do
            case "$_line" in
                *content://*) ;;
                *) continue ;;
            esac

            [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
            [ "${FORWARD_SMS}" != "true" ] && continue

            sleep "$delay"
            check_new_sms
        done

        log_warn "SMS 事件监听断开，10s 后重连..."
        sleep 10
    done
}

_sms_poll_loop() {
    local poll_interval="${POLL_INTERVAL:-5}"
    log_info "SMS 轮询模式已启动 (interval=${poll_interval}s)"

    while true; do
        [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
        [ "${FORWARD_SMS}" = "true" ] && check_new_sms
        sleep "$poll_interval"
    done
}

# ----------------------------------------------------------
# 看门狗
# ----------------------------------------------------------

_watchdog() {
    local sms_pid="$1"
    local call_pid="$2"
    local sms_mode="$3"

    while true; do
        sleep 30
        [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

        if [ "${FORWARD_SMS}" = "true" ] && [ -n "$sms_pid" ]; then
            if ! kill -0 "$sms_pid" 2>/dev/null; then
                log_warn "SMS 监控进程已死亡，重启中..."
                if [ "$sms_mode" = "event" ]; then
                    _sms_event_loop &
                else
                    _sms_poll_loop &
                fi
                sms_pid=$!
                _track_child "$sms_pid"
            fi
        fi

        if [ "${FORWARD_CALL}" = "true" ] && [ -n "$call_pid" ]; then
            if ! kill -0 "$call_pid" 2>/dev/null; then
                log_warn "来电监控进程已死亡，重启中..."
                run_call_monitor &
                call_pid=$!
                _track_child "$call_pid"
            fi
        fi
    done
}

# ----------------------------------------------------------
# 主入口
# ----------------------------------------------------------

main() {
    ensure_dirs

    log_info "========================================="
    log_info "SMS Forwarder 守护进程启动 v1.0.0"
    log_info "========================================="

    if is_daemon_running; then
        log_warn "守护进程已在运行，退出"
        exit 0
    fi

    write_pid

    if ! load_config; then
        log_error "配置加载失败，守护进程退出"
        cleanup_pid
        exit 1
    fi

    if ! detect_http_client; then
        log_error "无可用 HTTP 客户端，守护进程退出"
        cleanup_pid
        exit 1
    fi

    wait_for_network

    # 初始化
    [ "${FORWARD_SMS}" = "true" ] && init_sms_state
    [ "${FORWARD_CALL}" = "true" ] && init_call_state

    local sms_mode="${MONITOR_MODE:-auto}"
    log_info "SMS 监控模式: ${sms_mode}"
    log_info "短信转发: ${FORWARD_SMS:-false} | 来电转发: ${FORWARD_CALL:-false}"

    # 启动 SMS 监控子进程
    local sms_pid=""
    if [ "${FORWARD_SMS}" = "true" ]; then
        case "$sms_mode" in
            event)
                _sms_event_loop &
                sms_pid=$!
                sms_mode="event"
                log_info "SMS: 事件驱动模式"
                ;;
            poll)
                _sms_poll_loop &
                sms_pid=$!
                sms_mode="poll"
                log_info "SMS: 轮询模式"
                ;;
            auto|*)
                if _test_content_observe; then
                    _sms_event_loop &
                    sms_pid=$!
                    sms_mode="event"
                    log_info "SMS: 事件驱动模式 (自动检测成功)"
                else
                    _sms_poll_loop &
                    sms_pid=$!
                    sms_mode="poll"
                    log_info "SMS: 轮询模式 (content observe 不可用)"
                fi
                ;;
        esac
        _track_child "$sms_pid"
    fi

    # 启动来电监控子进程（独立的 dumpsys 轮询，不依赖 content observe）
    local call_pid=""
    if [ "${FORWARD_CALL}" = "true" ]; then
        run_call_monitor &
        call_pid=$!
        _track_child "$call_pid"
        log_info "来电: 实时响铃检测模式 (dumpsys telephony.registry)"
    fi

    # 看门狗主循环
    _watchdog "$sms_pid" "$call_pid" "$sms_mode"
}

main "$@"
