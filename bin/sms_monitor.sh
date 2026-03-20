#!/system/bin/sh
# ============================================================
# SMS Forwarder - 短信监控与转发
# 两阶段查询 + 首次静默追进：
#   Phase 1: 双列数字投影 (_id:date) 获取新 SMS ID 列表
#   Phase 2: 逐条查完整信息 (body 放最后安全提取)
# 首次运行 (last_id=0): 只记录位置，不推送历史消息
# ============================================================

# 依赖: utils.sh, bark_client.sh (由 daemon.sh 统一加载)

# 查询单条 SMS 的完整信息并发送通知
_process_single_sms() {
    local sms_id="$1"

    local detail
    detail="$(content query --uri content://sms/inbox \
        --projection 'address:date:sub_id:body' \
        --where "_id=${sms_id}" 2>&1)"

    if [ -z "$detail" ] || ! echo "$detail" | grep -q '^Row:'; then
        log_warn "SMS ID=${sms_id} 详情查询失败"
        return
    fi

    local first_line
    first_line="$(echo "$detail" | head -1)"

    local address date_ms sub_id
    address="$(echo "$first_line" | sed 's/.*address=\([^,]*\).*/\1/')"
    date_ms="$(echo "$first_line" | sed 's/.*date=\([0-9]*\).*/\1/')"
    sub_id="$(echo "$first_line" | sed 's/.*sub_id=\([^,]*\).*/\1/')"

    case "$sub_id" in
        ''|*[!0-9]*) sub_id="" ;;
    esac

    # body 是最后一个字段，可能跨多行
    local body
    body="$(echo "$first_line" | sed 's/.*body=//')"
    local total_lines
    total_lines="$(echo "$detail" | wc -l)"
    if [ "$total_lines" -gt 1 ]; then
        local extra
        extra="$(echo "$detail" | tail -n +2)"
        body="$(printf '%s\n%s' "$body" "$extra")"
    fi
    body="$(printf '%s' "$body" | tr -d '\r')"
    [ -z "$body" ] && body="(无内容)"

    log_info "检测到新短信: id=${sms_id} from=${address}"

    local sim_slot formatted_date
    sim_slot="$(get_sim_slot "$sub_id")"
    formatted_date="$(format_date_ms "$date_ms")"

    local title="短信 ${address} [${sim_slot}]"
    local content
    content="$(printf '%s\n%s' "$formatted_date" "$body")"

    send_bark_notification "$title" "$content"
}

# 主检查函数
check_new_sms() {
    local last_id
    last_id="$(read_state "$SMS_STATE_FILE")"
    case "$last_id" in
        ''|*[!0-9]*) last_id="0" ;;
    esac

    log_debug "查询新短信 (last_id=${last_id})"

    # ===== Phase 1: 双列数字投影获取 ID 列表 =====
    # 使用 _id:date 而非单独 _id，因为某些设备不支持单列投影
    local ids_result
    ids_result="$(content query --uri content://sms/inbox \
        --projection '_id:date' \
        --where "_id>${last_id}" \
        --sort '_id ASC' 2>&1)"

    if [ -z "$ids_result" ] || echo "$ids_result" | grep -q 'No result found'; then
        log_debug "无新短信"
        return
    fi

    if echo "$ids_result" | grep -qi 'exception\|error\|denied'; then
        log_error "SMS 查询出错: ${ids_result}"
        return
    fi

    local all_ids
    all_ids="$(echo "$ids_result" | grep '^Row:' | sed 's/.*_id=\([0-9]*\).*/\1/')"

    if [ -z "$all_ids" ]; then
        log_debug "无新短信（无有效 Row）"
        return
    fi

    # 提取最大 ID
    local max_id
    max_id="$(echo "$all_ids" | sort -n | tail -1)"
    case "$max_id" in
        ''|*[!0-9]*)
            log_error "max_id 解析失败: '${max_id}'"
            return
            ;;
    esac

    if [ "$max_id" -le "$last_id" ] 2>/dev/null; then
        log_debug "无新短信 (max_id=${max_id} <= last_id=${last_id})"
        return
    fi

    # 状态先行：立即更新
    write_state "$SMS_STATE_FILE" "$max_id"
    log_info "SMS 状态已更新: ${last_id} -> ${max_id}"

    # ===== 首次运行检测 =====
    # last_id=0 意味着是首次运行或初始化失败
    # 此时只记录当前位置，不推送历史消息
    if [ "$last_id" = "0" ]; then
        local count
        count="$(echo "$all_ids" | wc -l)"
        log_info "首次运行: 静默跳过 ${count} 条历史短信 (已追进到 last_id=${max_id})"
        return
    fi

    # ===== Phase 2: 逐条查完整信息并推送 =====
    local row_count=0
    for sms_id in $all_ids; do
        case "$sms_id" in ''|*[!0-9]*) continue ;; esac
        _process_single_sms "$sms_id"
        row_count=$((row_count + 1))
    done

    log_info "本轮处理完成: ${row_count} 条短信"
}

# 初始化 SMS 状态
# 即使初始化查询全部失败 (last_id=0)，check_new_sms 的静默追进也会处理
init_sms_state() {
    if [ -f "$SMS_STATE_FILE" ]; then
        local existing_id
        existing_id="$(read_state "$SMS_STATE_FILE")"
        log_info "SMS 状态已存在: last_id=${existing_id}"
        return
    fi

    log_info "初始化 SMS 状态..."

    local latest_id="0"

    # 尝试方式 1: 双列投影（最兼容）
    local first_row
    first_row="$(content query --uri content://sms/inbox \
        --projection '_id:date' \
        --sort '_id DESC' 2>&1 | grep '^Row:' | head -1)"
    if [ -n "$first_row" ]; then
        latest_id="$(echo "$first_row" | sed 's/.*_id=\([0-9]*\).*/\1/')"
        case "$latest_id" in ''|*[!0-9]*) latest_id="0" ;; esac
    fi

    # 尝试方式 2: 不带投影
    if [ "$latest_id" = "0" ]; then
        first_row="$(content query --uri content://sms/inbox \
            --sort '_id DESC' 2>&1 | grep '^Row:' | head -1)"
        if [ -n "$first_row" ]; then
            latest_id="$(echo "$first_row" | sed 's/.*_id=\([0-9]*\).*/\1/')"
            case "$latest_id" in ''|*[!0-9]*) latest_id="0" ;; esac
        fi
    fi

    write_state "$SMS_STATE_FILE" "$latest_id"

    if [ "$latest_id" = "0" ]; then
        log_info "SMS 初始化: last_id=0 (首次 check 时将静默追进)"
    else
        log_info "SMS 初始化完成: last_id=${latest_id}"
    fi
}
