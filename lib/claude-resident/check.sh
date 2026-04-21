#!/bin/bash

check() {
  local failures=0
  local warnings=0

  _ok() { printf 'OK   %s\n' "$1"; }
  _warn() { printf 'WARN %s\n' "$1"; warnings=$((warnings + 1)); }
  _fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

  if [ -x "$CLAUDE_BIN" ]; then
    _ok "Claude binary: $CLAUDE_BIN"
  else
    _fail "Claude binary not executable: $CLAUDE_BIN"
  fi

  if command -v tmux >/dev/null 2>&1; then
    _ok "tmux available"
  else
    _fail "tmux not found in PATH"
  fi

  if command -v bun >/dev/null 2>&1 || [ -x "$BUN_BIN_DIR/bun" ]; then
    _ok "bun available"
  else
    _warn "bun not found; Telegram plugin runtime may fail"
  fi

  if json_encoder_available; then
    _ok "JSON encoder available (jq or python3)"
  else
    _warn "jq and python3 not found; Telegram JSON generation will fail"
  fi

  if portable_days_ago "$DAILY_RETENTION_DAYS" >/dev/null 2>&1; then
    _ok "daily cleanup date calculation available"
  else
    _warn "GNU date, BSD date, and python3 unavailable; cleanup-memory will fail"
  fi

  if [ -d "$INSTANCE_CONFIG_DIR" ]; then
    _ok "config dir: $INSTANCE_CONFIG_DIR"
  else
    _fail "missing config dir: $INSTANCE_CONFIG_DIR"
  fi

  if [ -d "$INSTANCE_STATE_DIR" ]; then
    _ok "state dir: $INSTANCE_STATE_DIR"
  else
    _fail "missing state dir: $INSTANCE_STATE_DIR"
  fi

  if [ -f "$HEALTH_STATE_FILE" ]; then
    local health_summary
    if health_summary=$(read_health_state_summary "$HEALTH_STATE_FILE" 2>/dev/null); then
      _ok "health state: $health_summary"
    else
      _warn "health state unreadable: $HEALTH_STATE_FILE"
    fi
  else
    _warn "health state missing; expected after health timer runs: $HEALTH_STATE_FILE"
  fi

  if [ -f "$INSTANCE_CONFIG_DIR/CLAUDE.md" ]; then
    _ok "CLAUDE.md present"
  else
    _warn "missing CLAUDE.md"
  fi

  if [ -f "$MEMORY_DIR/soul.md" ]; then
    _ok "memory/soul.md present"
  else
    _warn "missing memory/soul.md"
  fi

  if [ -f "$MEMORY_DIR/user.md" ]; then
    _ok "memory/user.md present"
  else
    _warn "missing memory/user.md"
  fi

  if [ -d "$DAILY_DIR" ]; then
    _ok "memory daily dir: $DAILY_DIR"
  elif [ -f "$MEMORY_DIR/recent.md" ]; then
    _warn "memory/daily missing; using legacy memory/recent.md fallback"
  else
    _warn "missing memory/daily and legacy memory/recent.md"
  fi

  if [ -d "$TELEGRAM_STATE_DIR" ]; then
    _ok "telegram state dir: $TELEGRAM_STATE_DIR"
  else
    _warn "missing telegram state dir: $TELEGRAM_STATE_DIR"
  fi

  if [ -f "$TELEGRAM_STATE_DIR/access.json" ]; then
    _ok "telegram access file present"
  else
    _warn "missing telegram access file: $TELEGRAM_STATE_DIR/access.json"
  fi

  if [ -f "$INSTANCE_ENV_FILE" ]; then
    _ok "instance env present: $INSTANCE_ENV_FILE"
  elif [ -f "$ENV_FILE" ]; then
    _warn "instance env missing; using fallback env: $ENV_FILE"
  else
    _fail "no env source found (checked $INSTANCE_ENV_FILE and $ENV_FILE)"
  fi

  if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
    _ok "telegram bot token configured"
  else
    _fail "telegram bot token missing"
  fi

  if [ -n "$TELEGRAM_NOTIFY_CHAT_ID" ]; then
    _ok "telegram notify chat id configured"
  else
    _warn "telegram notify chat id missing"
  fi

  if [ -n "$WEBHOOK_PORT" ]; then
    _ok "webhook port configured: $WEBHOOK_PORT"
  else
    _warn "webhook port not configured; MCP defaults may apply"
  fi

  local global_telegram_env="${HOME}/.claude/channels/telegram/.env"
  if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -f "$global_telegram_env" ]; then
    local global_token
    global_token=$(awk -F= '$1 == "TELEGRAM_BOT_TOKEN" {print substr($0, index($0, "=") + 1)}' "$global_telegram_env")
    if [ "$global_token" = "$TELEGRAM_BOT_TOKEN" ]; then
      _warn "global Claude Telegram token matches this resident; non-resident Claude sessions may steal polling"
    fi
  fi

  if [ -f "$TELEGRAM_STATE_DIR/bot.pid" ]; then
    local bot_pid
    bot_pid=$(cat "$TELEGRAM_STATE_DIR/bot.pid")
    if [ -n "$bot_pid" ] && kill -0 "$bot_pid" 2>/dev/null; then
      _ok "telegram poller pid alive: $bot_pid"
    else
      _warn "telegram poller pid stale: ${bot_pid:-empty}"
    fi
  else
    _warn "telegram poller pid missing; expected while session is running"
  fi

  if [ -d "$WORKSPACE_DIR" ]; then
    _ok "workspace dir: $WORKSPACE_DIR"
  else
    _warn "workspace dir missing: $WORKSPACE_DIR"
  fi
  _ok "permission mode: $PERMISSION_MODE"

  if tmux has-session -t "$SESSION" 2>/dev/null; then
    _ok "tmux session running: $SESSION"
  else
    _warn "tmux session not running: $SESSION"
  fi

  printf 'Summary: %s failure(s), %s warning(s)\n' "$failures" "$warnings"
  [ "$failures" -eq 0 ]
}
