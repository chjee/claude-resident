#!/bin/bash

write_health_state() {
  local checked_at="${1:?checked_at is required}"
  local service_active="${2:?service_active is required}"
  local session_exists_before="${3:?session_exists_before is required}"
  local action="${4:?action is required}"
  local reason="${5:?reason is required}"
  local restart_requested_at="${6:-}"
  local restart_exit_code="${7:-}"
  local session_exists_after="${8:-}"
  local poller_alive="${9:-null}"
  local tmp_file="${HEALTH_STATE_FILE}.tmp.$$"

  {
    printf '{\n'
    printf '  "checked_at": %s,\n' "$(json_string_or_null "$checked_at")"
    printf '  "instance": %s,\n' "$(json_string_or_null "$INSTANCE")"
    printf '  "service_name": %s,\n' "$(json_string_or_null "claude-resident@$INSTANCE.service")"
    printf '  "service_active": %s,\n' "$service_active"
    printf '  "session_name": %s,\n' "$(json_string_or_null "$SESSION")"
    printf '  "session_exists_before": %s,\n' "$session_exists_before"
    printf '  "action": %s,\n' "$(json_string_or_null "$action")"
    printf '  "reason": %s,\n' "$(json_string_or_null "$reason")"
    printf '  "restart_requested_at": %s,\n' "$(json_string_or_null "$restart_requested_at")"
    if [ -n "$restart_exit_code" ]; then
      printf '  "restart_exit_code": %s,\n' "$restart_exit_code"
    else
      printf '  "restart_exit_code": null,\n'
    fi
    printf '  "session_exists_after": %s,\n' "$(json_bool_or_null "$session_exists_after")"
    printf '  "poller_alive": %s\n' "$poller_alive"
    printf '}\n'
  } > "$tmp_file" || {
    rm -f "$tmp_file"
    return 1
  }

  mv "$tmp_file" "$HEALTH_STATE_FILE"
}

check_poller_alive() {
  local pid_file="$TELEGRAM_STATE_DIR/bot.pid"
  [ -f "$pid_file" ] || { printf 'null'; return; }
  local bot_pid
  bot_pid=$(cat "$pid_file" 2>/dev/null)
  if [ -n "$bot_pid" ] && kill -0 "$bot_pid" 2>/dev/null; then
    printf 'true'
  else
    printf 'false'
  fi
}

record_health_state() {
  if ! write_health_state "$@"; then
    log "[$INSTANCE] ERROR: health state 기록 실패: $HEALTH_STATE_FILE"
    return 1
  fi
}

health() {
  local checked_at
  local service_active=false
  local session_exists_before=false
  local session_exists_after=""
  local action=""
  local reason=""
  local restart_requested_at=""
  local restart_exit_code=""
  local tmux_available=true
  local poller_alive

  checked_at=$(timestamp_now)
  poller_alive=$(check_poller_alive)

  if ! command -v tmux >/dev/null 2>&1; then
    tmux_available=false
  elif tmux has-session -t "$SESSION" 2>/dev/null; then
    session_exists_before=true
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    action="error"
    reason="systemctl_unavailable"
    session_exists_after="$session_exists_before"
    record_health_state "$checked_at" "$service_active" "$session_exists_before" "$action" "$reason" "$restart_requested_at" "$restart_exit_code" "$session_exists_after" "$poller_alive" || return 1
    log "[$INSTANCE] ERROR: health check 실패 — systemctl 없음"
    return 1
  fi

  if systemctl --user is-active --quiet "claude-resident@$INSTANCE.service" 2>/dev/null; then
    service_active=true
  else
    action="skip_inactive"
    reason="service_inactive"
    session_exists_after="$session_exists_before"
    record_health_state "$checked_at" "$service_active" "$session_exists_before" "$action" "$reason" "$restart_requested_at" "$restart_exit_code" "$session_exists_after" "$poller_alive" || return 1
    log "[$INSTANCE] health check: service inactive — restart 생략"
    return 0
  fi

  if [ "$tmux_available" = false ]; then
    action="error"
    reason="tmux_unavailable"
    session_exists_after=false
    record_health_state "$checked_at" "$service_active" "$session_exists_before" "$action" "$reason" "$restart_requested_at" "$restart_exit_code" "$session_exists_after" "$poller_alive" || return 1
    log "[$INSTANCE] ERROR: health check 실패 — tmux 없음"
    return 1
  fi

  # 세션은 있지만 poller가 죽은 경우 — 기록만 하고 재시작
  if [ "$session_exists_before" = true ] && [ "$poller_alive" = false ]; then
    action="restart"
    reason="poller_dead"
    restart_requested_at=$(timestamp_now)
    log "[$INSTANCE] health check: Telegram poller 죽음 — 세션 재시작"
    if systemctl --user restart "claude-resident@$INSTANCE.service"; then
      restart_exit_code=0
    else
      restart_exit_code=$?
    fi
    if tmux has-session -t "$SESSION" 2>/dev/null; then
      session_exists_after=true
    else
      session_exists_after=false
    fi
    poller_alive=$(check_poller_alive)
    record_health_state "$checked_at" "$service_active" "$session_exists_before" "$action" "$reason" "$restart_requested_at" "$restart_exit_code" "$session_exists_after" "$poller_alive" || return 1
    if [ "$restart_exit_code" -eq 0 ] && [ "$session_exists_after" = true ]; then
      log "[$INSTANCE] health check: poller 재시작 완료"
      return 0
    fi
    log "[$INSTANCE] ERROR: poller 재시작 실패 exit=$restart_exit_code session_after=$session_exists_after"
    return 1
  fi

  if [ "$session_exists_before" = true ]; then
    action="noop"
    reason="session_present"
    session_exists_after="$session_exists_before"
    record_health_state "$checked_at" "$service_active" "$session_exists_before" "$action" "$reason" "$restart_requested_at" "$restart_exit_code" "$session_exists_after" "$poller_alive" || return 1
    log "[$INSTANCE] health check: tmux session 정상 poller=$poller_alive"
    return 0
  fi

  action="restart"
  reason="session_missing"
  restart_requested_at=$(timestamp_now)
  if systemctl --user restart "claude-resident@$INSTANCE.service"; then
    restart_exit_code=0
  else
    restart_exit_code=$?
  fi

  if tmux has-session -t "$SESSION" 2>/dev/null; then
    session_exists_after=true
  else
    session_exists_after=false
  fi
  poller_alive=$(check_poller_alive)

  record_health_state "$checked_at" "$service_active" "$session_exists_before" "$action" "$reason" "$restart_requested_at" "$restart_exit_code" "$session_exists_after" "$poller_alive" || return 1
  if [ "$restart_exit_code" -eq 0 ] && [ "$session_exists_after" = true ]; then
    log "[$INSTANCE] health check: tmux session 없음 — 재시작 완료"
    return 0
  fi

  log "[$INSTANCE] ERROR: health check 재시작 실패 exit=$restart_exit_code session_after=$session_exists_after"
  return 1
}

read_health_state_summary() {
  local file="${1:?file is required}"

  if command -v jq >/dev/null 2>&1; then
    jq -r '"action=\(.action) reason=\(.reason) checked_at=\(.checked_at) session_before=\(.session_exists_before) session_after=\(.session_exists_after) poller=\(.poller_alive)"' "$file"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c \
      'import json,sys; d=json.load(open(sys.argv[1])); b=lambda v: str(v).lower() if isinstance(v, bool) else v; print("action={} reason={} checked_at={} session_before={} session_after={} poller={}".format(d.get("action"), d.get("reason"), d.get("checked_at"), b(d.get("session_exists_before")), b(d.get("session_exists_after")), b(d.get("poller_alive"))))' \
      "$file"
  else
    printf 'file=%s\n' "$file"
  fi
}
