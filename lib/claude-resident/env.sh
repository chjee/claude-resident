#!/bin/bash

load_instance_env() {
  local instance_env_file="${1:?instance_env_file is required}"
  local fallback_env_file="${2:?fallback_env_file is required}"

  local _env
  for _env in "$instance_env_file" "$fallback_env_file"; do
    [ -f "$_env" ] || continue
    while IFS='=' read -r key val || [ -n "$key" ]; do
      key="${key#"${key%%[![:space:]]*}"}"
      key="${key%"${key##*[![:space:]]}"}"
      case "$key" in
        ""|\#*) continue ;;
      esac
      key="${key#export }"
      key="${key#"${key%%[![:space:]]*}"}"
      key="${key%"${key##*[![:space:]]}"}"

      val="${val%$'\r'}"
      val="${val#"${val%%[![:space:]]*}"}"
      val="${val%"${val##*[![:space:]]}"}"
      val="${val#\"}"
      val="${val%\"}"
      val="${val#\'}"
      val="${val%\'}"

      case "$key" in
        TELEGRAM_BOT_TOKEN|TELEGRAM_NOTIFY_CHAT_ID|TELEGRAM_STATE_DIR|\
        WEBHOOK_PORT|BRIDGE_URL|BRIDGE_CALLBACK_SECRET|ENABLE_CLAUDE_CHANNEL|\
        CLAUDE_RESIDENT_EXTRA_ARGS|\
        CLAUDE_RESIDENT_PERMISSION_MODE|CLAUDE_RESIDENT_STARTUP_DELAY_SEC|\
        CLAUDE_RESIDENT_TRIGGER_RETRY_DELAY_SEC|CLAUDE_RESIDENT_RESTART_DELAY_SEC|\
        CLAUDE_RESIDENT_STARTUP_RETRIES|CLAUDE_RESIDENT_SHUTDOWN_RETRIES|\
        CLAUDE_RESIDENT_SHUTDOWN_WAIT_SEC|CLAUDE_RESIDENT_DAILY_RETENTION_DAYS|\
        CLAUDE_RESIDENT_LOG_ROTATE_BYTES)
          [ -z "${!key}" ] && export "$key=$val"
          ;;
      esac
    done < "$_env"
  done
}
