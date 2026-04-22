#!/bin/bash

start() {
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "$INSTANCE 이미 실행 중."
    echo "접속: tmux attach -t $SESSION"
    return
  fi

  for f in soul.md user.md; do
    [[ -f "$MEMORY_DIR/$f" ]] || {
      log_event "error" "start_validation" "missing required file: $f"
      return 1
    }
  done
  [[ -f "$INSTANCE_CONFIG_DIR/CLAUDE.md" ]] || {
    log_event "error" "start_validation" "missing CLAUDE.md — resident startup 규칙 없이 기동 불가"
    return 1
  }

  if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_ROTATE_BYTES" ]; then
    mv "$LOG_FILE" "${LOG_FILE}.1"
    log "[$INSTANCE] agent.log rotated (>${LOG_ROTATE_BYTES} bytes)"
  fi

  if [ ! -x "$CLAUDE_BIN" ]; then
    echo "ERROR: Claude Code 바이너리를 찾지 못함: $CLAUDE_BIN"
    return 1
  fi

  echo "$INSTANCE 시작 중..."
  ensure_telegram_state || return 1
  # bun이 PATH에 없어도 플러그인이 동작하도록 보장
  case ":$PATH:" in *":$BUN_BIN_DIR:"*) ;; *) PATH="$BUN_BIN_DIR:$PATH" ;; esac

  claude_cmd=(env
    "CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1"
    "DISABLE_AUTOUPDATER=1"
    "TELEGRAM_STATE_DIR=$TELEGRAM_STATE_DIR"
    "PATH=$PATH"
    ${WEBHOOK_PORT:+"WEBHOOK_PORT=$WEBHOOK_PORT"}
    ${BRIDGE_URL:+"BRIDGE_URL=$BRIDGE_URL"}
    ${BRIDGE_CALLBACK_SECRET:+"BRIDGE_CALLBACK_SECRET=$BRIDGE_CALLBACK_SECRET"}
    ${ENABLE_CLAUDE_CHANNEL:+"ENABLE_CLAUDE_CHANNEL=$ENABLE_CLAUDE_CHANNEL"}
    "$CLAUDE_BIN")
  if [ -d "$WORKSPACE_DIR" ]; then
    claude_cmd+=(--add-dir "$WORKSPACE_DIR")
  else
    echo "WARN: workspace 디렉토리 없음 — --add-dir 생략: $WORKSPACE_DIR"
  fi
  claude_cmd+=(--channels "plugin:telegram@claude-plugins-official")
  if [ -n "${CLAUDE_RESIDENT_EXTRA_ARGS:-}" ]; then
    # shellcheck disable=SC2206
    local extra_args=( $CLAUDE_RESIDENT_EXTRA_ARGS )
    claude_cmd+=("${extra_args[@]}")
  fi
  claude_cmd+=(--permission-mode "$PERMISSION_MODE")

  printf -v claude_cmd_string '%q ' "${claude_cmd[@]}"
  local log_file_q
  local tmux_output
  printf -v log_file_q '%q' "$LOG_FILE"

  if ! tmux_output=$(tmux new-session -d -s "$SESSION" \
    -c "$INSTANCE_CONFIG_DIR" \
    -e "CLAUDE_RESIDENT_INSTANCE=$INSTANCE" \
    -e "CLAUDE_RESIDENT_CONFIG_DIR=$INSTANCE_CONFIG_DIR" \
    -e "CLAUDE_RESIDENT_STATE_DIR=$INSTANCE_STATE_DIR" \
    -e "TELEGRAM_STATE_DIR=$TELEGRAM_STATE_DIR" \
    ${WEBHOOK_PORT:+-e "WEBHOOK_PORT=$WEBHOOK_PORT"} \
    ${BRIDGE_URL:+-e "BRIDGE_URL=$BRIDGE_URL"} \
    ${BRIDGE_CALLBACK_SECRET:+-e "BRIDGE_CALLBACK_SECRET=$BRIDGE_CALLBACK_SECRET"} \
    ${ENABLE_CLAUDE_CHANNEL:+-e "ENABLE_CLAUDE_CHANNEL=$ENABLE_CLAUDE_CHANNEL"} \
    "${claude_cmd_string}" 2>&1); then
    if tmux has-session -t "$SESSION" 2>/dev/null; then
      echo "$INSTANCE 이미 실행 중."
      echo "접속: tmux attach -t $SESSION"
      return 0
    fi
    log "[$INSTANCE] ERROR: tmux session 생성 실패: $tmux_output"
    log_event "error" "session_start_failed" "tmux new-session failed" "output=$tmux_output"
    return 1
  fi

  # pipe-pane으로 로깅 (PTY를 유지하면서 ANSI/OSC escape와 제어문자는 제거)
  if ! tmux pipe-pane -t "$SESSION" "perl -CSDA -pe 's/\\e\\[[0-?]*[ -\\/]*[@-~]//g; s/\\e\\][^\\a]*(?:\\a|\\e\\\\)//gs; s/\\x08//g' | col -b >> $log_file_q"; then
    log "[$INSTANCE] ERROR: tmux pipe-pane 로깅 설정 실패 — 세션 정리"
    log_event "error" "pipe_pane_failed" "tmux pipe-pane setup failed, session cleaned up"
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    return 1
  fi

  log_event "info" "session_started" "tmux session created" "session=$SESSION"
  # 백그라운드에서 startup 트리거 전송
  send_startup_trigger &

  echo "$INSTANCE 시작됨."
  echo "접속: tmux attach -t $SESSION"
  echo "로그: claude-resident $INSTANCE logs"
}

stop() {
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux kill-session -t "$SESSION"
    echo "$INSTANCE 종료됨."
  else
    echo "$INSTANCE 실행 중 아님."
  fi
}

shutdown() {
  # systemd ExecStop 전용 — daily 저장 후 종료
  log "[$INSTANCE] 종료 신호 수신 — daily 저장 요청 중..."
  log_event "info" "shutdown_requested" "systemd ExecStop received"

  if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_NOTIFY_CHAT_ID" ]; then
    if send_telegram_text "__SHUTDOWN__" "$SHUTDOWN_TRIGGER_RETRIES"; then
      log "[$INSTANCE] __SHUTDOWN__ 전송 완료 — ${SHUTDOWN_WAIT_SEC}초 대기 (daily 저장 시간)"
      log_event "info" "shutdown_trigger_sent" "__SHUTDOWN__ delivered" "wait_sec=$SHUTDOWN_WAIT_SEC"
      sleep "$SHUTDOWN_WAIT_SEC"
    else
      log "[$INSTANCE] WARN: __SHUTDOWN__ 전송 실패 — daily 저장 없이 종료될 수 있음"
      log_event "warn" "shutdown_trigger_failed" "telegram send failed, daily may not be saved"
    fi
  else
    log "[$INSTANCE] WARN: 텔레그램 설정 없음 — 즉시 종료"
    log_event "warn" "shutdown_no_telegram" "telegram not configured, shutting down immediately"
  fi

  log_event "info" "session_stopping" "killing tmux session"
  stop
}

graceful_restart() {
  # daily 저장 후 재시작 — 운영 세션을 안전하게 교체할 때 사용
  # systemd ExecStop 경로와 달리 직접 호출용
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    log "[$INSTANCE] graceful-restart: session 없음 — 바로 시작"
    log_event "info" "graceful_restart_no_session" "no existing session, starting fresh"
    start
    return
  fi

  log "[$INSTANCE] graceful-restart: __SHUTDOWN__ 전송 후 재시작"
  log_event "info" "graceful_restart_requested" "sending __SHUTDOWN__ before restart"

  if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_NOTIFY_CHAT_ID" ]; then
    if send_telegram_text "__SHUTDOWN__" "$SHUTDOWN_TRIGGER_RETRIES"; then
      log "[$INSTANCE] graceful-restart: ${SHUTDOWN_WAIT_SEC}초 대기"
      log_event "info" "graceful_restart_waiting" "__SHUTDOWN__ sent, waiting for daily save" "wait_sec=$SHUTDOWN_WAIT_SEC"
      sleep "$SHUTDOWN_WAIT_SEC"
    else
      log "[$INSTANCE] WARN: graceful-restart: __SHUTDOWN__ 전송 실패 — daily 저장 없이 재시작"
      log_event "warn" "graceful_restart_trigger_failed" "telegram send failed, restarting without daily save"
    fi
  else
    log "[$INSTANCE] WARN: graceful-restart: 텔레그램 없음 — 즉시 재시작"
    log_event "warn" "graceful_restart_no_telegram" "no telegram config, restarting immediately"
  fi

  stop
  sleep "$RESTART_DELAY_SEC"
  start
}

status() {
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "✅ $INSTANCE 실행 중 (tmux session: $SESSION)"
    tmux list-sessions -F "  세션: #{session_name} | 생성: #{session_created_string}" \
      -f "#{==:#{session_name},$SESSION}"
    echo "  설정: $INSTANCE_CONFIG_DIR"
    echo "  상태: $INSTANCE_STATE_DIR"
    echo "  로그: $LOG_FILE"
  else
    echo "❌ $INSTANCE 실행 중 아님"
  fi
}

logs() {
  tail -F "$LOG_FILE"
}

attach_session() {
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux attach -t "$SESSION"
  else
    echo "$INSTANCE tmux 세션이 없습니다. (session: $SESSION)"
    return 1
  fi
}
