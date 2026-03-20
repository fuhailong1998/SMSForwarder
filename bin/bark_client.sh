#!/system/bin/sh
# ============================================================
# SMS Forwarder - Bark API 客户端
# 封装 Bark 推送逻辑，支持多地址并发、失败重试
# ============================================================

# 依赖: utils.sh (由 daemon.sh 统一加载)

# 向单个 Bark 地址发送推送
# 参数: $1=bark_url $2=title $3=body $4=group $5=sound $6=icon $7=level
_send_to_bark_single() {
    local bark_url="$1"
    local title="$2"
    local body="$3"
    local group="${4:-$BARK_GROUP}"
    local sound="${5:-$BARK_SOUND}"
    local icon="${6:-$BARK_ICON}"
    local level="${7:-$BARK_LEVEL}"

    local escaped_title escaped_body
    escaped_title="$(json_escape "$title")"
    escaped_body="$(json_escape "$body")"

    local json_payload="{\"title\":\"${escaped_title}\",\"body\":\"${escaped_body}\""
    [ -n "$group" ] && json_payload="${json_payload},\"group\":\"${group}\""
    [ -n "$sound" ] && json_payload="${json_payload},\"sound\":\"${sound}\""
    [ -n "$icon" ]  && json_payload="${json_payload},\"icon\":\"${icon}\""
    [ -n "$level" ] && json_payload="${json_payload},\"level\":\"${level}\""
    json_payload="${json_payload}}"

    log_debug "Bark 请求: url=${bark_url} payload=${json_payload}"

    local retries=0
    local max_retries="${MAX_RETRIES:-3}"
    local backoff="${RETRY_BACKOFF:-2}"

    while [ "$retries" -le "$max_retries" ]; do
        local response
        response="$(http_post_json "$bark_url" "$json_payload")"
        local exit_code=$?

        if [ $exit_code -eq 0 ] && echo "$response" | grep -q '"code":200'; then
            log_debug "Bark 推送成功: ${bark_url}"
            return 0
        fi

        retries=$((retries + 1))
        if [ "$retries" -le "$max_retries" ]; then
            local wait_time=$((backoff * retries))
            log_warn "Bark 推送失败 (${retries}/${max_retries})，${wait_time}s 后重试: ${bark_url}"
            sleep "$wait_time"
        fi
    done

    log_error "Bark 推送最终失败: ${bark_url} response=${response}"
    return 1
}

# 向所有已配置的 Bark 地址发送推送
# 参数: $1=title $2=body
send_bark_notification() {
    local title="$1"
    local body="$2"

    if [ "${#BARK_URLS[@]}" -eq 0 ]; then
        log_error "无 Bark 地址可用"
        return 1
    fi

    local success_count=0
    local fail_count=0

    for url in "${BARK_URLS[@]}"; do
        # 跳过空行和注释
        url="$(echo "$url" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$url" ] && continue
        echo "$url" | grep -q '^#' && continue

        _send_to_bark_single "$url" "$title" "$body" \
            "$BARK_GROUP" "$BARK_SOUND" "$BARK_ICON" "$BARK_LEVEL" &
    done

    # 等待所有后台推送完成
    wait

    log_info "Bark 推送完成: title=${title}"
}
