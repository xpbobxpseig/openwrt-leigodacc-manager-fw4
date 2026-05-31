#!/bin/sh
# ============================================================
# LeigodAcc Auto-Pause — 自动暂停时长计费 (v2.5)
# 来源: https://github.com/xxx/openwrt-leigodacc-manager-fw4
# 基于: miaoermua/openwrt-leigodacc-manager
# AI 辅助: DeepSeek AI 生成和修改
#
# Token 获取:
#   LuCI 自动暂停页面 → 拖书签到浏览器书签栏
#   打开 leigod.com 登录 → 点击书签 → 一键获取
#   Token 有效期约 7 天，过期后重新点击书签即可。
#
#   登录 API (/wap/login/bind/v1) 被 CloudWAF(418) 全面封锁,
#   家庭宽带/Cloudflare/GitHub Actions/服务器均被拦截。
#   pause API (/api/user/pause) 无此限制, 有 token 即可。
#
# 空闲检测:
#   cron 定时检查, 连续空闲 N 次后触发暂停
#   总空闲时间 = IDLE_CHECK_INTERVAL(分钟) × IDLE_CHECKS_BEFORE_PAUSE(次)
#   默认: 2分钟 × 3次 = 6分钟
# ============================================================

CONFIG_FILE="/etc/leigod-auto-pause.conf"
STATE_FILE="/tmp/leigod-auto-pause.state"
LOG_TAG="leigod-auto-pause"

# --------------- config ---------------
load_config() {
    ACCOUNT_TOKEN=""
    IDLE_CHECKS_BEFORE_PAUSE=3
    IDLE_CHECK_INTERVAL=2
    API_TIMEOUT=10
    API_ENDPOINT="https://webapi.leigod.com"
    NOTIFY_ON_PAUSE=1

    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE"
    fi
    [ -z "$IDLE_CHECKS_BEFORE_PAUSE" ] && IDLE_CHECKS_BEFORE_PAUSE=3
    [ -z "$IDLE_CHECK_INTERVAL" ] && IDLE_CHECK_INTERVAL=2
    [ -z "$API_TIMEOUT" ] && API_TIMEOUT=10
}

# --------------- token ---------------
get_token() {
    if [ -n "$ACCOUNT_TOKEN" ]; then
        echo "$ACCOUNT_TOKEN"
        return 0
    fi
    return 1
}

# --------------- idle detection ---------------
check_all_idle() {
    for dev in Phone PC Game Unknown; do
        local state
        state=$(uci get "accelerator.${dev}.state" 2>/dev/null)
        [ "$state" = "1" ] && return 1
    done
    return 0
}

# Fallback: check GAMEACC iptables rules exist (indicates active acceleration)
check_gameacc_active() {
    local count
    count=$(iptables -L GAMEACC -n 2>/dev/null | grep -c "ACCEPT\|RETURN\|TPROXY\|MARK")
    [ "$count" -gt 0 ] && return 1
    return 0
}

is_idle() {
    if [ -f /etc/config/accelerator ]; then
        check_all_idle || return 1
    fi
    check_gameacc_active || return 1
    return 0
}

# --------------- API ---------------
call_pause_api() {
    local token="$1"
    local resp code
    resp=$(curl -sL --connect-timeout "$API_TIMEOUT" \
        -X POST "${API_ENDPOINT}/api/user/pause" \
        -H 'Content-Type: application/json' \
        -H 'User-Agent: LeigodAcc-AutoPause/2.5' \
        -d "{\"account_token\":\"${token}\",\"lang\":\"zh_CN\"}" 2>/dev/null)
    code=$(echo "$resp" | grep -o '"code": *[-0-9]*' | head -1 | grep -o '[-0-9]*$')
    echo "$code"
}

# --------------- state ---------------
read_state() {
    local idle_count=0
    local last_pause_epoch=0
    if [ -f "$STATE_FILE" ]; then
        local key val
        while IFS='=' read -r key val; do
            case "$key" in
                idle_count) idle_count="$val" ;;
                last_pause_epoch) last_pause_epoch="$val" ;;
            esac
        done < "$STATE_FILE"
    fi
    IDLE_COUNT=$idle_count
    LAST_PAUSE_EPOCH=$last_pause_epoch
}

write_state() {
    cat > "$STATE_FILE" << STATEOF
idle_count=${IDLE_COUNT}
last_pause_epoch=${LAST_PAUSE_EPOCH}
STATEOF
}

# --------------- main ---------------
main() {
    load_config

    local TOKEN
    TOKEN=$(get_token 2>/dev/null)
    if [ -z "$TOKEN" ]; then
        logger -t "$LOG_TAG" "account_token 未配置, 请通过 LuCI 自动暂停页面的书签获取"
        return 1
    fi

    read_state
    local now
    now=$(date +%s)

    # Cooldown: don't re-pause within 10 minutes
    if [ "$LAST_PAUSE_EPOCH" != "0" ] && [ $((now - LAST_PAUSE_EPOCH)) -lt 600 ]; then
        return 0
    fi

    if is_idle; then
        IDLE_COUNT=$((IDLE_COUNT + 1))
        logger -t "$LOG_TAG" "检测到空闲 (${IDLE_COUNT}/${IDLE_CHECKS_BEFORE_PAUSE})"

        if [ "$IDLE_COUNT" -ge "$IDLE_CHECKS_BEFORE_PAUSE" ]; then
            logger -t "$LOG_TAG" "空闲阈值达到, 正在调用暂停 API..."
            local api_code
            api_code=$(call_pause_api "$TOKEN")

            case "$api_code" in
                0)
                    logger -t "$LOG_TAG" "暂停成功! 时长计费已停止"
                    [ "$NOTIFY_ON_PAUSE" = "1" ] && \
                        echo "[LeigodAcc Auto-Pause] $(date '+%H:%M:%S') 暂停成功"
                    LAST_PAUSE_EPOCH=$now
                    IDLE_COUNT=0
                    ;;
                400803)
                    logger -t "$LOG_TAG" "已经处于暂停状态"
                    LAST_PAUSE_EPOCH=$now
                    IDLE_COUNT=0
                    ;;
                400006)
                    logger -t "$LOG_TAG" "token 已过期 (code=400006), 请重新通过书签获取"
                    IDLE_COUNT=$((IDLE_CHECKS_BEFORE_PAUSE - 1))
                    ;;
                "")
                    logger -t "$LOG_TAG" "API 请求失败 (网络/curl 错误)"
                    ;;
                *)
                    logger -t "$LOG_TAG" "API 返回异常 (code=$api_code)"
                    ;;
            esac
        fi
    else
        [ "$IDLE_COUNT" -gt 0 ] && logger -t "$LOG_TAG" "设备活跃, 重置空闲计数"
        IDLE_COUNT=0
    fi

    write_state
}

main "$@"
