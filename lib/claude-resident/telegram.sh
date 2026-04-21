#!/bin/bash

write_access_json() {
  local target="${1:?target is required}"
  local chat_id="${2:?chat_id is required}"

  if command -v jq >/dev/null 2>&1; then
    jq -n --arg cid "$chat_id" \
      '{"dmPolicy":"allowlist","allowFrom":[$cid],"groups":{},"pending":{}}' \
      > "$target"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c \
      'import json,sys; print(json.dumps({"dmPolicy":"allowlist","allowFrom":[sys.argv[1]],"groups":{},"pending":{}}))' \
      "$chat_id" > "$target"
  else
    printf 'ERROR: jq or python3 required for access.json generation\n' >&2
    return 1
  fi
}

build_telegram_payload() {
  local chat_id="${1:?chat_id is required}"
  local text="${2:?text is required}"

  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg chat_id "$chat_id" \
      --arg text "$text" \
      '{"chat_id": $chat_id, "text": $text}'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c \
      'import json,sys; print(json.dumps({"chat_id": sys.argv[1], "text": sys.argv[2]}))' \
      "$chat_id" "$text"
  else
    printf 'ERROR: jq or python3 required for JSON encoding\n' >&2
    return 1
  fi
}

ensure_telegram_state() {
  mkdir -p "$TELEGRAM_STATE_DIR"
  chmod 700 "$TELEGRAM_STATE_DIR" 2>/dev/null || true

  if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
    ( umask 077; printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TELEGRAM_BOT_TOKEN" > "$TELEGRAM_STATE_DIR/.env" )
  fi

  if [ ! -f "$TELEGRAM_STATE_DIR/access.json" ] && [ -n "$TELEGRAM_NOTIFY_CHAT_ID" ]; then
    ( umask 077; write_access_json "$TELEGRAM_STATE_DIR/access.json" "$TELEGRAM_NOTIFY_CHAT_ID" ) || return 1
  fi
}

send_telegram_text() {
  local text="${1:?text is required}"
  local retries="${2:-1}"
  local attempt=1
  local http_status=""
  local payload

  payload=$(build_telegram_payload "$TELEGRAM_NOTIFY_CHAT_ID" "$text") || return 1

  while [ "$attempt" -le "$retries" ]; do
    http_status=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "$payload")

    if [ "$http_status" = "200" ]; then
      return 0
    fi

    if [ "$attempt" -lt "$retries" ]; then
      sleep "$TRIGGER_RETRY_DELAY_SEC"
    fi
    attempt=$((attempt + 1))
  done

  printf '%s\n' "${http_status:-000}"
  return 1
}

send_startup_trigger() {
  # Claude 세션이 안정화되길 기다린 후 __STARTUP__ 트리거 전송
  sleep "$STARTUP_TRIGGER_DELAY_SEC"
  if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_NOTIFY_CHAT_ID" ]; then
    log "[$INSTANCE] WARN: TELEGRAM_BOT_TOKEN 또는 TELEGRAM_NOTIFY_CHAT_ID 없음 — startup 트리거 생략"
    return
  fi

  if send_telegram_text "__STARTUP__" "$STARTUP_TRIGGER_RETRIES"; then
    log "[$INSTANCE] startup 트리거 전송 성공"
  else
    log "[$INSTANCE] ERROR: startup 트리거 전송 실패 — 수동으로 __STARTUP__ 전송 필요"
  fi
}
