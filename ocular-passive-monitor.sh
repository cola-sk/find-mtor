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

targets='OCular|LAgent|LAgentUser|LMonitor|LMonitor2|LInject|LSensitive|LSDHelper|LVnctransfer|LWMHelper'
screen_terms='ScreenShot|screenshot|Snapshot|SCREEN_CAPTURE|CGDisplay|CGWindow|SCStream|ScreenCapture|GetScreenshot|CaptureCtrl|ScreenShotCtrl|TCC|kTCCServiceScreenCapture'

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
    sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
      "select * from access where service like '%Screen%' or client like '%OCular%' or client like '%tec%';" 2>&1
  } >> "$OUT_DIR/tcc-snapshot.log"
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
  sudo fs_usage -w -f filesys 2>/dev/null | filter_i "$targets|/\.OCular/|ScreenShot|kTCCServiceScreenCapture" \
    >> "$OUT_DIR/fs-usage.log" 2>&1 &
  echo $! > "$OUT_DIR/fs-usage.pid"
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
  # fs_usage runs as root behind sudo; the recorded pid is the local filter, so kill
  # the privileged fs_usage process directly by name to avoid leaving a root process.
  [[ -f "$OUT_DIR/fs-usage.pid" ]] && kill "$(cat "$OUT_DIR/fs-usage.pid")" 2>/dev/null || true
  sudo pkill -f 'fs_usage -w -f filesys' 2>/dev/null || true
  echo "Duration: ${hours}h ${minutes}min"
  echo "Saved logs in: $OUT_DIR"
  exit 0
}
trap cleanup INT TERM EXIT

write_tcc_snapshot
start_log_stream
start_fs_usage
snapshot_loop
