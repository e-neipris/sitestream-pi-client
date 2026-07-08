#!/bin/bash
# SiteStream Pi Client — Player Script
# Runs as a systemd service. Manages VLC playback based on the current schedule.
#
# Logic:
#   - Every 30 seconds, checks what video should be playing right now
#   - Compares against the currently-playing video
#   - If different (or VLC is not running), starts VLC with the correct file
#   - Reads schedule.json written by sync.sh

SCHEDULE_FILE="/home/pi/sitestream/schedule.json"
VIDEO_DIR="/home/pi/sitestream/videos"
LOG_PREFIX="[PLAYER $(date '+%H:%M:%S')]"

log() { echo "$LOG_PREFIX $1"; }

CURRENT_VIDEO_PATH=""
VLC_PID=""

stop_vlc() {
  if [ -n "$VLC_PID" ] && kill -0 "$VLC_PID" 2>/dev/null; then
    kill "$VLC_PID"
    wait "$VLC_PID" 2>/dev/null
    VLC_PID=""
    CURRENT_VIDEO_PATH=""
  fi
  pkill -f "vlc" 2>/dev/null || true
}

start_vlc() {
  local video_path="$1"
  stop_vlc
  log "Starting VLC: $video_path"
  DISPLAY=:0 vlc \
    --fullscreen \
    --loop \
    --no-video-title-show \
    --no-osd \
    --quiet \
    "$video_path" &
  VLC_PID=$!
  CURRENT_VIDEO_PATH="$video_path"
}

# Returns the local file path that should be playing right now, or empty string
get_current_video() {
  [ -f "$SCHEDULE_FILE" ] || return

  local now_hhmm
  now_hhmm=$(date '+%H:%M')
  local now_dow
  now_dow=$(date '+%w')  # 0=Sun, 6=Sat
  local now_date
  now_date=$(date '+%Y-%m-%dT00:00:00.000Z')

  # Use jq to find the highest-priority schedule entry active right now
  jq -r --arg now "$now_hhmm" --argjson dow "$now_dow" --arg today "$now_date" '
    .schedule
    | map(select(
        (.startTime <= $now) and (.endTime > $now)
        and ((.daysOfWeek | length) == 0 or (.daysOfWeek[] | . == $dow) )
        and ((.validFrom == null) or (.validFrom <= $today))
        and ((.validUntil == null) or (.validUntil >= $today))
        and (.localPath | ltrimstr("/") | ("/" + .) | test("^/") )
      ))
    | sort_by(.priority)
    | reverse
    | first
    | .localPath // empty
  ' "$SCHEDULE_FILE" 2>/dev/null
}

log "SiteStream player started."

# ── Main loop ─────────────────────────────────────────────────────────────────
while true; do
  WANTED=$(get_current_video)

  if [ -z "$WANTED" ]; then
    # Nothing scheduled right now
    if [ -n "$VLC_PID" ] && kill -0 "$VLC_PID" 2>/dev/null; then
      log "No video scheduled — stopping player."
      stop_vlc
    fi
  elif [ ! -f "$WANTED" ]; then
    log "WARN: Scheduled video not found locally: $WANTED (waiting for sync)"
  elif [ "$WANTED" != "$CURRENT_VIDEO_PATH" ]; then
    log "Switching to: $WANTED"
    start_vlc "$WANTED"
  elif ! kill -0 "$VLC_PID" 2>/dev/null; then
    # VLC died unexpectedly — restart it
    log "VLC not running, restarting: $WANTED"
    start_vlc "$WANTED"
  fi

  # Also re-read schedule if sync.sh flagged an update
  if [ -f /home/pi/sitestream/.schedule_updated ]; then
    rm -f /home/pi/sitestream/.schedule_updated
    log "Schedule updated — re-evaluating."
    # Force re-evaluation next loop without waiting
  fi

  sleep 30
done
