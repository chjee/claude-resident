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

cleanup_memory() {
  mkdir -p "$DAILY_DIR"

  local cleaned=0
  local skipped=0
  local cutoff
  local candidates='(\[memory-candidate\]|\[project-candidate\]|\[workflow-candidate\])'
  cutoff=$(portable_days_ago "$DAILY_RETENTION_DAYS") || return 1

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
}
