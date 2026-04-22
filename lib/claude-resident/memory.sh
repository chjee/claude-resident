#!/bin/bash

portable_days_ago() {
  local days="${1:?days is required}"

  if date -d "$days days ago" +%F >/dev/null 2>&1; then
    date -d "$days days ago" +%F
  elif date -v-"${days}"d +%F >/dev/null 2>&1; then
    date -v-"${days}"d +%F
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c \
      'from datetime import date, timedelta; import sys; print((date.today() - timedelta(days=int(sys.argv[1]))).isoformat())' \
      "$days"
  else
    printf 'ERROR: GNU date, BSD date, or python3 required for daily cleanup date calculation\n' >&2
    return 1
  fi
}

acquire_daily_lock() {
  mkdir -p "$MEMORY_DIR"

  local attempts=0
  while ! mkdir "$DAILY_LOCK_DIR" 2>/dev/null; do
    local pid; pid=$(grep '^pid=' "$DAILY_LOCK_DIR/owner" 2>/dev/null | cut -d= -f2-)

    # pid 있고 프로세스 죽었으면 stale
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      # stale: owner 먼저 제거 후 lock dir 삭제 (owner 있으면 rmdir 실패)
      rm -f "$DAILY_LOCK_DIR/owner"
      if rmdir "$DAILY_LOCK_DIR" 2>/dev/null; then
        continue
      fi
      log "[$INSTANCE] WARN: stale daily lock 제거 실패 (권한 문제?) — 재시도"
      (( attempts++ )); sleep 1
      [[ $attempts -ge 10 ]] && { log "[$INSTANCE] WARN: daily lock 대기 시간 초과 — skip"; return 1; }
      continue
    fi

    # owner 없거나 malformed (pid= 비었음): grace period 적용
    if [[ ! -f "$DAILY_LOCK_DIR/owner" ]] || [[ -z "$pid" ]]; then
      local lock_age lock_mtime
      # GNU stat -c %Y (Linux/systemd 운영 환경 전제; BSD는 stat -f %m)
      lock_mtime=$(stat -c %Y "$DAILY_LOCK_DIR" 2>/dev/null) || lock_mtime=$(date +%s)
      lock_age=$(( $(date +%s) - lock_mtime ))
      if [[ $lock_age -lt 2 ]]; then
        (( attempts++ )); sleep 1
        [[ $attempts -ge 10 ]] && { log "[$INSTANCE] WARN: daily lock 대기 시간 초과 — skip"; return 1; }
        continue
      fi
      log "[$INSTANCE] WARN: owner 없는/malformed 오래된 lock 발견 — stale 처리 (age: ${lock_age}s)"
      rm -f "$DAILY_LOCK_DIR/owner"
      if rmdir "$DAILY_LOCK_DIR" 2>/dev/null; then
        continue
      fi
      log "[$INSTANCE] WARN: stale daily lock 제거 실패 (권한 문제?) — 재시도"
      (( attempts++ )); sleep 1
      [[ $attempts -ge 10 ]] && { log "[$INSTANCE] WARN: daily lock 대기 시간 초과 — skip"; return 1; }
      continue
    fi

    (( attempts++ )); sleep 1
    if [[ $attempts -ge 10 ]]; then
      log "[$INSTANCE] WARN: daily lock 대기 시간 초과 — skip"
      return 1
    fi
  done

  # owner 작성 실패는 fatal: partial 파일이 생길 수 있으므로 rm -f 후 rmdir
  if ! {
    printf 'pid=%s\n' "$$"
    printf 'created_at=%s\n' "$(timestamp_now)"
    printf 'command=%s\n' "$CMD"
  } > "$DAILY_LOCK_DIR/owner"; then
    rm -f "$DAILY_LOCK_DIR/owner"
    rmdir "$DAILY_LOCK_DIR" 2>/dev/null || true
    log "[$INSTANCE] ERROR: daily lock owner 기록 실패"
    return 1
  fi
}

# 주의: acquire_daily_lock() 성공 후에만 호출할 것.
# lock을 잡지 않은 경로에서 호출되면 다른 프로세스 lock을 실수로 해제할 수 있다.
release_daily_lock() {
  local owner_pid; owner_pid=$(grep '^pid=' "$DAILY_LOCK_DIR/owner" 2>/dev/null | cut -d= -f2-)
  if [[ "$owner_pid" == "$$" ]]; then
    rm -f "$DAILY_LOCK_DIR/owner"
    rmdir "$DAILY_LOCK_DIR" 2>/dev/null || true
  fi
}

cleanup_memory() {
  mkdir -p "$DAILY_DIR"
  if ! acquire_daily_lock; then
    return 0
  fi

  local cleaned=0
  local skipped=0
  local cutoff
  local result=0
  local candidates='(\[memory-candidate\]|\[project-candidate\]|\[workflow-candidate\])'
  cutoff=$(portable_days_ago "$DAILY_RETENTION_DAYS") || result=$?

  if [ "$result" -eq 0 ]; then
    for daily_file in "$DAILY_DIR"/????-??-??.md; do
      [ -e "$daily_file" ] || continue
      local daily_name="${daily_file##*/}"
      local daily_date="${daily_name%.md}"
      [ "$daily_date" \< "$cutoff" ] || continue

      if grep -Eq "$candidates" "$daily_file"; then
        log "[$INSTANCE] WARN: candidate tag 남은 오래된 daily 유지: $daily_file"
        skipped=$((skipped + 1))
        continue
      fi

      rm -f "$daily_file"
      log "[$INSTANCE] 오래된 daily 삭제: $daily_file"
      cleaned=$((cleaned + 1))
    done

    log "[$INSTANCE] daily cleanup 완료: deleted=$cleaned skipped=$skipped retention_days=$DAILY_RETENTION_DAYS cutoff=$cutoff"
  fi

  release_daily_lock
  return "$result"
}
