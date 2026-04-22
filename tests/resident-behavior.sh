#!/bin/bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/claude-resident"
BASE_PATH="$PATH"
TEST_TMP=""
PASS_COUNT=0
FAIL_COUNT=0

fail() {
  printf 'FAIL %s\n' "$1" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  printf 'PASS %s\n' "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

assert_contains() {
  : "${1:?label is required}"
  local haystack="${2:?haystack is required}"
  local needle="${3:?needle is required}"

  if ! printf '%s' "$haystack" | grep -Fq "$needle"; then
    printf 'Expected to find: %s\nOutput was:\n%s\n' "$needle" "$haystack" >&2
    return 1
  fi
  return 0
}

assert_file_contains() {
  local file="${1:?file is required}"
  local needle="${2:?needle is required}"

  [ -f "$file" ] || {
    printf 'Expected file to exist: %s\n' "$file" >&2
    return 1
  }
  if ! grep -Fq "$needle" "$file"; then
    printf 'Expected file %s to contain: %s\n' "$file" "$needle" >&2
    printf 'File was:\n' >&2
    sed -n '1,80p' "$file" >&2
    return 1
  fi
  return 0
}

setup_case() {
  TEST_TMP="$(mktemp -d)"
  mkdir -p "$TEST_TMP/bin" "$TEST_TMP/config/claude-resident/test/memory" "$TEST_TMP/state"
  printf 'test startup rules\n' > "$TEST_TMP/config/claude-resident/test/CLAUDE.md"
  printf 'test soul\n' > "$TEST_TMP/config/claude-resident/test/memory/soul.md"
  printf 'test user\n' > "$TEST_TMP/config/claude-resident/test/memory/user.md"
  cat > "$TEST_TMP/bin/fake-claude" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$TEST_TMP/bin/fake-claude"
}

cleanup_case() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
  TEST_TMP=""
}

run_resident() {
  local instance="${1:?instance is required}"
  local command="${2:?command is required}"
  shift 2
  local case_tmp="$TEST_TMP"

  env \
  PATH="$case_tmp/bin:$BASE_PATH" \
  TEST_TMP="$case_tmp" \
  XDG_CONFIG_HOME="$case_tmp/config" \
  XDG_STATE_HOME="$case_tmp/state" \
  CLAUDE_BIN="$case_tmp/bin/fake-claude" \
  CLAUDE_RESIDENT_OMX_BRIDGE_ENV_FILE="$case_tmp/fallback.env" \
  "$SCRIPT" "$instance" "$command" "$@"
}

write_tmux_always_running() {
  cat > "$TEST_TMP/bin/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_TMP/tmux.calls"
case "$1" in
  has-session) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$TEST_TMP/bin/tmux"
}

write_tmux_new_session_fails() {
  cat > "$TEST_TMP/bin/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_TMP/tmux.calls"
case "$1" in
  has-session) exit 1 ;;
  new-session) printf 'new-session boom\n' >&2; exit 42 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$TEST_TMP/bin/tmux"
}

write_tmux_pipe_fails() {
  cat > "$TEST_TMP/bin/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_TMP/tmux.calls"
case "$1" in
  has-session)
    [ -f "$TEST_TMP/session" ]
    exit $?
    ;;
  new-session)
    touch "$TEST_TMP/session"
    exit 0
    ;;
  pipe-pane)
    exit 31
    ;;
  kill-session)
    touch "$TEST_TMP/killed"
    rm -f "$TEST_TMP/session"
    exit 0
    ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$TEST_TMP/bin/tmux"
}

write_tmux_not_running() {
  cat > "$TEST_TMP/bin/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_TMP/tmux.calls"
case "$1" in
  has-session) exit 1 ;;
  kill-session) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$TEST_TMP/bin/tmux"
}

write_fake_curl_success() {
  cat > "$TEST_TMP/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_TMP/curl.calls"
printf '200'
EOF
  chmod +x "$TEST_TMP/bin/curl"
}

write_fake_sleep() {
  cat > "$TEST_TMP/bin/sleep" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_TMP/sleep.calls"
exit 0
EOF
  chmod +x "$TEST_TMP/bin/sleep"
}

write_fake_systemctl_active_restart_creates_session() {
  cat > "$TEST_TMP/bin/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_TMP/systemctl.calls"
if [ "$1" = "--user" ] && [ "$2" = "is-active" ]; then
  exit 0
fi
if [ "$1" = "--user" ] && [ "$2" = "restart" ]; then
  touch "$TEST_TMP/session"
  exit 0
fi
exit 1
EOF
  chmod +x "$TEST_TMP/bin/systemctl"
}

write_tmux_session_file() {
  cat > "$TEST_TMP/bin/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_TMP/tmux.calls"
case "$1" in
  has-session)
    [ -f "$TEST_TMP/session" ]
    exit $?
    ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$TEST_TMP/bin/tmux"
}

run_test() {
  local name="${1:?name is required}"
  shift

  setup_case
  if "$@"; then
    pass "$name"
  else
    fail "$name"
  fi
  cleanup_case
}

test_env_priority() {
  write_tmux_not_running
  cat > "$TEST_TMP/config/claude-resident/test/.env" <<'EOF'
TELEGRAM_BOT_TOKEN=instance-token
TELEGRAM_NOTIFY_CHAT_ID=12345
CLAUDE_RESIDENT_PERMISSION_MODE=acceptEdits
EOF
  cat > "$TEST_TMP/fallback.env" <<'EOF'
TELEGRAM_BOT_TOKEN=fallback-token
CLAUDE_RESIDENT_PERMISSION_MODE=bypassPermissions
EOF

  local output
  output="$(run_resident test check 2>&1)"
  assert_contains "permission mode" "$output" "OK   permission mode: acceptEdits"
}

test_start_existing_session_does_not_create() {
  write_tmux_always_running
  local output
  output="$(run_resident test start 2>&1)"
  assert_contains "already running" "$output" "test 이미 실행 중." || return 1
  if grep -Fq 'new-session' "$TEST_TMP/tmux.calls"; then
    printf 'new-session should not be called when session exists\n' >&2
    return 1
  fi
}

test_start_new_session_failure_is_nonzero() {
  write_tmux_new_session_fails
  local output
  if output="$(run_resident test start 2>&1)"; then
    printf 'start should fail when tmux new-session fails\n' >&2
    return 1
  fi
  assert_contains "new-session failure" "$output" "tmux session 생성 실패"
}

test_start_pipe_failure_cleans_session() {
  write_tmux_pipe_fails
  local output
  if output="$(run_resident test start 2>&1)"; then
    printf 'start should fail when tmux pipe-pane fails\n' >&2
    return 1
  fi
  assert_contains "pipe failure" "$output" "pipe-pane 로깅 설정 실패" || return 1
  [ -f "$TEST_TMP/killed" ] || {
    printf 'expected pipe-pane failure to kill created session\n' >&2
    return 1
  }
}

test_shutdown_uses_configured_wait() {
  write_tmux_not_running
  write_fake_curl_success
  write_fake_sleep
  cat > "$TEST_TMP/config/claude-resident/test/.env" <<'EOF'
TELEGRAM_BOT_TOKEN=fake-token
TELEGRAM_NOTIFY_CHAT_ID=12345
CLAUDE_RESIDENT_SHUTDOWN_WAIT_SEC=7
EOF

  run_resident test shutdown >/dev/null 2>&1 || return 1
  assert_file_contains "$TEST_TMP/sleep.calls" "7"
}

test_cleanup_memory_preserves_candidates_and_deletes_plain_old_daily() {
  local daily_dir="$TEST_TMP/config/claude-resident/test/memory/daily"
  mkdir -p "$daily_dir"
  local old_date
  local older_date
  old_date="$(date -d '2 days ago' +%F)"
  older_date="$(date -d '3 days ago' +%F)"
  printf 'plain old note\n' > "$daily_dir/$old_date.md"
  printf '[memory-candidate] keep me\n' > "$daily_dir/$older_date.md"
  printf 'CLAUDE_RESIDENT_DAILY_RETENTION_DAYS=1\n' > "$TEST_TMP/config/claude-resident/test/.env"

  run_resident test cleanup-memory >/dev/null 2>&1 || return 1
  [ ! -e "$daily_dir/$old_date.md" ] || {
    printf 'expected plain old daily file to be deleted\n' >&2
    return 1
  }
  [ -e "$daily_dir/$older_date.md" ] || {
    printf 'expected candidate daily file to be preserved\n' >&2
    return 1
  }
  [ ! -e "$TEST_TMP/config/claude-resident/test/memory/.daily.lock" ] || {
    printf 'expected cleanup-memory to release daily lock\n' >&2
    return 1
  }
}

test_cleanup_memory_skips_when_daily_lock_is_held() {
  local memory_dir="$TEST_TMP/config/claude-resident/test/memory"
  local daily_dir="$memory_dir/daily"
  mkdir -p "$daily_dir" "$memory_dir/.daily.lock"
  local old_date
  old_date="$(date -d '2 days ago' +%F)"
  printf 'plain old note\n' > "$daily_dir/$old_date.md"
  printf 'CLAUDE_RESIDENT_DAILY_RETENTION_DAYS=1\n' > "$TEST_TMP/config/claude-resident/test/.env"

  run_resident test cleanup-memory >/dev/null 2>&1 || return 1
  [ -e "$daily_dir/$old_date.md" ] || {
    printf 'expected cleanup-memory to preserve file when daily lock is held\n' >&2
    return 1
  }
  [ -d "$memory_dir/.daily.lock" ] || {
    printf 'expected externally held daily lock to remain\n' >&2
    return 1
  }
}

test_health_restart_records_state() {
  write_fake_systemctl_active_restart_creates_session
  write_tmux_session_file

  run_resident test health >/dev/null 2>&1 || return 1
  local state_file="$TEST_TMP/state/claude-resident/test/health-state.json"
  assert_file_contains "$state_file" '"action": "restart"' || return 1
  assert_file_contains "$state_file" '"reason": "session_missing"' || return 1
  assert_file_contains "$state_file" '"session_exists_after": true'
}

test_installed_layout_loads_libs() {
  write_tmux_not_running
  local install_root="$TEST_TMP/install"
  mkdir -p "$install_root/bin" "$install_root/lib/claude-resident"
  cp "$SCRIPT" "$install_root/bin/claude-resident"
  cp "$ROOT_DIR"/lib/claude-resident/*.sh "$install_root/lib/claude-resident/"
  cat > "$TEST_TMP/config/claude-resident/test/.env" <<'EOF'
TELEGRAM_BOT_TOKEN=fake-token
TELEGRAM_NOTIFY_CHAT_ID=12345
EOF

  local output
  output="$(
    env \
      PATH="$TEST_TMP/bin:$BASE_PATH" \
      TEST_TMP="$TEST_TMP" \
      XDG_CONFIG_HOME="$TEST_TMP/config" \
      XDG_STATE_HOME="$TEST_TMP/state" \
      CLAUDE_BIN="$TEST_TMP/bin/fake-claude" \
      CLAUDE_RESIDENT_OMX_BRIDGE_ENV_FILE="$TEST_TMP/fallback.env" \
      "$install_root/bin/claude-resident" test check 2>&1
  )"
  assert_contains "installed layout" "$output" "OK   JSON encoder available"
}

run_test "env priority uses instance .env before fallback" test_env_priority
run_test "start skips new-session when tmux session exists" test_start_existing_session_does_not_create
run_test "start returns non-zero when tmux new-session fails" test_start_new_session_failure_is_nonzero
run_test "start cleans session when pipe-pane fails" test_start_pipe_failure_cleans_session
run_test "shutdown uses CLAUDE_RESIDENT_SHUTDOWN_WAIT_SEC" test_shutdown_uses_configured_wait
run_test "cleanup-memory deletes old daily but preserves candidate daily" test_cleanup_memory_preserves_candidates_and_deletes_plain_old_daily
run_test "cleanup-memory skips deletion when daily lock is held" test_cleanup_memory_skips_when_daily_lock_is_held
run_test "health restart branch records state" test_health_restart_records_state
run_test "installed bin can load ../lib/claude-resident modules" test_installed_layout_loads_libs

printf 'Summary: %s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
