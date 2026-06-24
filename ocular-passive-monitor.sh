#!/usr/bin/env zsh
set -u

START_EPOCH="$(date +%s)"
OUT_DIR="${1:-$HOME/find-mtor/logs/ocular-monitor-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT_DIR"

echo "OCular passive monitor"
echo "Local time: $(date '+%F %T %Z %z')"
echo "Logs: $OUT_DIR"
echo "Stop with Ctrl-C"
echo

targets='OCular|LAgent|LAgentUser|LMonitor|LMonitor2|LInject|LSensitive|LSDHelper|LVnctransfer|LWMHelper|LSDConfig|LNacConfig'
screen_terms='ScreenShot|screenshot|Snapshot|SCREEN_CAPTURE|CGDisplay|CGWindow|SCStream|ScreenCapture|GetScreenshot|CaptureCtrl|ScreenShotCtrl|TCC|kTCCServiceScreenCapture'
FS_USAGE_ENABLED=0
FS_USAGE_RESTARTING=0
FS_FIFO="$OUT_DIR/fs-usage.pipe"

# Prefer ripgrep, fall back to grep -E so the script still works without rg.
if command -v rg >/dev/null 2>&1; then
  HAVE_RG=1
else
  HAVE_RG=0
  echo "NOTE: ripgrep (rg) not found, falling back to grep -E."
fi
filter_i() {
  # usage: filter_i 'EXTENDED_REGEX'  (case-insensitive, line buffered)
  if (( HAVE_RG )); then
    rg --line-buffered -i "$1"
  else
    grep --line-buffered -iE "$1"
  fi
}

log_health() {
  echo "[$(date '+%F %T %Z %z')] $*" >> "$OUT_DIR/health.log"
}

ensure_sudo() {
  if sudo -n -v 2>/dev/null; then
    return
  fi

  echo "sudo credentials required for system TCC and fs_usage."
  if ! sudo -v; then
    echo "ERROR: sudo authentication failed; cannot start reliable monitoring." >&2
    exit 1
  fi
}

# Reading TCC.db requires Full Disk Access for the terminal app; warn early.
if ! sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" 'select 1 limit 1;' >/dev/null 2>&1; then
  echo "WARNING: cannot read user TCC.db (grant Full Disk Access to your terminal for TCC checks)."
fi

write_tcc_snapshot() {
  {
    echo "== $(date '+%F %T %Z %z') user TCC screen-capture entries =="
    sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
      "select * from access where service like '%Screen%' or client like '%OCular%' or client like '%tec%';" 2>&1
    echo
    echo "== $(date '+%F %T %Z %z') system TCC screen-capture entries, may require sudo =="
    sudo -n sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
      "select * from access where service like '%Screen%' or client like '%OCular%' or client like '%tec%';" 2>&1
  } >> "$OUT_DIR/tcc-snapshot.log"
}

check_fs_usage_health() {
  (( FS_USAGE_ENABLED )) || return
  (( FS_USAGE_RESTARTING )) && return

  local source_pid filter_pid worker_pid
  source_pid="$(cat "$OUT_DIR/fs-usage-source.pid" 2>/dev/null || true)"
  filter_pid="$(cat "$OUT_DIR/fs-usage-filter.pid" 2>/dev/null || true)"
  worker_pid="$(cat "$OUT_DIR/fs-usage-worker.pid" 2>/dev/null || true)"

  if [[ -z "$source_pid" ]] || ! kill -0 "$source_pid" 2>/dev/null; then
    log_health "fs_usage source exited; restarting"
    {
      echo "== $(date '+%F %T %Z %z') fs_usage source exited; restarting =="
      [[ -s "$OUT_DIR/fs-usage.err" ]] && tail -n 10 "$OUT_DIR/fs-usage.err"
    } >> "$OUT_DIR/fs-usage.log"
    restart_fs_usage
    return
  fi

  if [[ -n "$worker_pid" ]] && ! ps -p "$worker_pid" >/dev/null 2>&1; then
    log_health "fs_usage worker exited; restarting"
    {
      echo "== $(date '+%F %T %Z %z') fs_usage worker exited; restarting =="
      [[ -s "$OUT_DIR/fs-usage.err" ]] && tail -n 10 "$OUT_DIR/fs-usage.err"
    } >> "$OUT_DIR/fs-usage.log"
    restart_fs_usage
    return
  fi

  if [[ -z "$filter_pid" ]] || ! kill -0 "$filter_pid" 2>/dev/null; then
    log_health "fs_usage filter exited; restarting"
    echo "== $(date '+%F %T %Z %z') fs_usage filter exited; restarting ==" >> "$OUT_DIR/fs-usage.log"
    restart_fs_usage
    return
  fi

  # Check for silent log stoppage (kernel kdebug session takeover or trace interruption)
  # If fs-usage.log has not been updated for 60 seconds, force a restart.
  local last_mtime now diff
  last_mtime="$(stat -f %m "$OUT_DIR/fs-usage.log" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  diff=$(( now - last_mtime ))
  if (( diff > 60 )) && (( (now - START_EPOCH) > 60 )); then
    log_health "fs_usage log inactive for $diff seconds (kdebug trace hijacked?); forcing restart"
    {
      echo "== $(date '+%F %T %Z %z') fs_usage log inactive ($diff s); forcing restart =="
    } >> "$OUT_DIR/fs-usage.log"
    restart_fs_usage
  fi
}

snapshot_loop() {
  while true; do
    now="$(date '+%F %T %Z %z')"
    # Unquoted (f)-split drops empty fields, so no phantom empty pid when nothing matches.
    pids=(${(f)"$(pgrep -f "$targets" 2>/dev/null)"})

    {
      echo "===== $now ====="
      pgrep -laf "$targets" || true
      echo
    } >> "$OUT_DIR/processes.log"

    if (( ${#pids[@]} > 0 )); then
      {
        echo "===== $now ====="
        ps -o pid,ppid,stat,etime,pcpu,pmem,command -p "${(j:,:)pids}" 2>/dev/null || true
        echo
      } >> "$OUT_DIR/ps.log"

      {
        echo "===== $now ====="
        for pid in "${pids[@]}"; do
          echo "--- pid $pid ---"
          lsof -nP -p "$pid" 2>/dev/null | filter_i '(/\.OCular/.*/ScreenShot|/ScreenShot/|\.png|\.jpg|\.jpeg|\.bmp|\.dat|/tmp/|/var/folders/)' || true
        done
        echo
      } >> "$OUT_DIR/open-files.log"

      {
        echo "===== $now ====="
        for pid in "${pids[@]}"; do
          # -a ANDs -i and -p so we only get THIS pid's sockets (without -a lsof ORs them).
          lsof -nP -a -i -p "$pid" 2>/dev/null || true
        done
        echo
      } >> "$OUT_DIR/network.log"
    fi

    check_fs_usage_health
    sleep 5
  done
}

start_log_stream() {
  # Use the absolute path: zsh has a builtin `log` that shadows /usr/bin/log in
  # non-interactive scripts and fails with "too many arguments".
  /usr/bin/log stream --style compact --predicate "process CONTAINS[c] 'OCular' OR process CONTAINS[c] 'LAgent' OR process CONTAINS[c] 'LMonitor' OR process CONTAINS[c] 'LInject' OR process CONTAINS[c] 'LSensitive' OR eventMessage CONTAINS[c] 'ScreenShot' OR eventMessage CONTAINS[c] 'Snapshot' OR eventMessage CONTAINS[c] 'SCREEN_CAPTURE' OR eventMessage CONTAINS[c] 'CGDisplayStream' OR eventMessage CONTAINS[c] 'kTCCServiceScreenCapture'" \
    >> "$OUT_DIR/unified-log.log" 2>&1 &
  echo $! > "$OUT_DIR/log-stream.pid"
}

start_fs_usage() {
  # fs_usage is the most reliable way to catch a screenshot being written to disk.
  # On by default; set OCULAR_MONITOR_NO_FS=1 to skip it. Requires sudo (root).
  if [[ "${OCULAR_MONITOR_NO_FS:-0}" == "1" ]]; then
    echo "fs_usage disabled (OCULAR_MONITOR_NO_FS=1)."
    return
  fi
  echo "Starting fs_usage (needs sudo)..."
  # Filter to OCular processes, the .OCular tree, and screenshot markers only.
  # (Matching bare .png/.jpg flooded the log with unrelated system activity.)
  rm -f "$FS_FIFO"
  rm -f "$OUT_DIR/fs-usage-source.pid" "$OUT_DIR/fs-usage-filter.pid" "$OUT_DIR/fs-usage-worker.pid"
  mkfifo "$FS_FIFO"

  filter_i "$targets|/\.OCular/|ScreenShot|kTCCServiceScreenCapture" \
    < "$FS_FIFO" >> "$OUT_DIR/fs-usage.log" 2>&1 &
  echo $! > "$OUT_DIR/fs-usage-filter.pid"

  sudo -n -S fs_usage -w -f filesys > "$FS_FIFO" 2>> "$OUT_DIR/fs-usage.err" < /dev/null &
  echo $! > "$OUT_DIR/fs-usage-source.pid"

  sleep 1
  if ! kill -0 "$(cat "$OUT_DIR/fs-usage-source.pid")" 2>/dev/null; then
    echo "ERROR: fs_usage failed to start; see $OUT_DIR/fs-usage.err" >&2
    log_health "fs_usage failed to start"
    exit 1
  fi

  local worker_pid
  worker_pid="$(pgrep -P "$(cat "$OUT_DIR/fs-usage-source.pid")" -x fs_usage 2>/dev/null | head -n 1 || true)"
  [[ -n "$worker_pid" ]] && echo "$worker_pid" > "$OUT_DIR/fs-usage-worker.pid"
  FS_USAGE_ENABLED=1
  log_health "fs_usage started"
}

stop_fs_usage() {
  FS_USAGE_ENABLED=0
  local pid_file pid
  for pid_file in "$OUT_DIR/fs-usage-worker.pid" "$OUT_DIR/fs-usage-source.pid" "$OUT_DIR/fs-usage-filter.pid"; do
    [[ -f "$pid_file" ]] || continue
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    [[ -n "$pid" ]] || continue
    kill "$pid" 2>/dev/null || sudo -n kill "$pid" 2>/dev/null || true
  done
  rm -f "$FS_FIFO"
}

restart_fs_usage() {
  FS_USAGE_RESTARTING=1
  stop_fs_usage
  if sudo -n -v 2>/dev/null; then
    start_fs_usage
  else
    log_health "cannot restart fs_usage: sudo credentials unavailable"
    echo "== $(date '+%F %T %Z %z') cannot restart fs_usage: sudo credentials unavailable ==" >> "$OUT_DIR/fs-usage.log"
  fi
  FS_USAGE_RESTARTING=0
}

cleanup() {
  trap - INT TERM EXIT  # 重置信号，防止 cleanup 被重复触发
  end_epoch="$(date +%s)"
  duration=$(( end_epoch - START_EPOCH ))
  (( duration < 0 )) && duration=0
  hours=$(( duration / 3600 ))
  minutes=$(( (duration % 3600) / 60 ))

  echo
  echo "Stopping monitor..."
  [[ -f "$OUT_DIR/log-stream.pid" ]] && kill "$(cat "$OUT_DIR/log-stream.pid")" 2>/dev/null || true
  stop_fs_usage
  [[ -f "$OUT_DIR/sudo-keepalive.pid" ]] && kill "$(cat "$OUT_DIR/sudo-keepalive.pid")" 2>/dev/null || true
  echo "Duration: ${hours}h ${minutes}min"
  echo "Saved logs in: $OUT_DIR"
  exit 0
}
trap cleanup INT TERM EXIT

start_sudo_keepalive() {
  # Background loop to refresh sudo credentials every 60 seconds.
  (
    while true; do
      sudo -n -S -v < /dev/null 2>/dev/null || log_health "sudo credential refresh failed"
      sleep 60
    done
  ) &
  echo $! > "$OUT_DIR/sudo-keepalive.pid"
}

ensure_sudo
write_tcc_snapshot
start_sudo_keepalive
start_log_stream
start_fs_usage
snapshot_loop
