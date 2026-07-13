#!/bin/bash
# SiteStream Pi Client — Player Script
# Runs as a systemd service. Manages VLC playback based on the current schedule.
#
# Logic:
#   - Every 30 seconds, checks what video should be playing right now
#   - Compares against the currently-playing video
#   - If different (or VLC is not running), starts VLC with the correct file
#   - Reads schedule.json written by sync.sh

SITESTREAM_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEDULE_FILE="$SITESTREAM_DIR/schedule.json"
VIDEO_DIR="$SITESTREAM_DIR/videos"
CONFIG="$SITESTREAM_DIR/config.env"
LOG_PREFIX="[PLAYER $(date '+%H:%M:%S')]"

log() { echo "$LOG_PREFIX $1"; }

CURRENT_VIDEO_PATH=""
CURRENT_MULTICAST_TARGET=""
VLC_PID=""

# Disable screen blanking/DPMS entirely — this is a kiosk display with no
# keyboard/mouse ever attached, so X sees "no activity" forever and blanks
# the screen on its default timeout regardless of whether a video should be
# playing. A schedule-free gap (or just the normal gap between windows) would
# otherwise leave the display asleep with nothing to wake it back up.
disable_screen_blanking() {
  DISPLAY=:0 xset s off 2>/dev/null || true
  DISPLAY=:0 xset s noblank 2>/dev/null || true
  DISPLAY=:0 xset -dpms 2>/dev/null || true
}

stop_vlc() {
  if [ -n "$VLC_PID" ] && kill -0 "$VLC_PID" 2>/dev/null; then
    kill "$VLC_PID"
    wait "$VLC_PID" 2>/dev/null
    VLC_PID=""
    CURRENT_VIDEO_PATH=""
    CURRENT_MULTICAST_TARGET=""
  fi
  pkill -f "vlc" 2>/dev/null || true
}

start_vlc() {
  local video_path="$1"
  stop_vlc
  log "Starting VLC: $video_path"
  # Force-wake in case the display already blanked before this run — the
  # config change above only prevents future blanking, it won't undo a
  # display that's already asleep from before player.sh (re)started.
  DISPLAY=:0 xset dpms force on 2>/dev/null || true

  # Multicast output (in addition to HDMI) — one Pi per site feeding an IPTV
  # tuner. MPEG-TS over UDP is the standard IPTV distribution format; this
  # remuxes rather than transcodes, so it assumes the source is already an
  # H.264 MP4 (true for everything sync.sh downloads). Revisit the mux/codec
  # here once you have the tuner manufacturer's exact ingest spec.
  local sout_args=()
  if [ "$MULTICAST_ENABLED" = "true" ] && [ -n "$MULTICAST_ADDRESS" ] && [ -n "$MULTICAST_PORT" ]; then
    log "Multicast output: udp://$MULTICAST_ADDRESS:$MULTICAST_PORT"
    sout_args=(--sout "#duplicate{dst=display,dst=std{access=udp,mux=ts,dst=$MULTICAST_ADDRESS:$MULTICAST_PORT}}" --sout-keep)
  fi

  DISPLAY=:0 vlc \
    --fullscreen \
    --loop \
    --no-video-title-show \
    --no-osd \
    --quiet \
    "${sout_args[@]}" \
    "$video_path" &
  VLC_PID=$!
  CURRENT_VIDEO_PATH="$video_path"
  CURRENT_MULTICAST_TARGET="$MULTICAST_ENABLED:$MULTICAST_ADDRESS:$MULTICAST_PORT"
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
disable_screen_blanking

# ── Main loop ─────────────────────────────────────────────────────────────────
LOOP_COUNT=0
while true; do
  # Re-assert every ~10 min in case anything else (a package update, a
  # desktop environment restart) re-enables blanking behind our backs.
  if [ $((LOOP_COUNT % 20)) -eq 0 ]; then
    disable_screen_blanking
  fi
  LOOP_COUNT=$((LOOP_COUNT + 1))

  # Re-read config each loop so a multicast toggle (or the token, if reissued)
  # takes effect without needing to restart this service.
  [ -f "$CONFIG" ] && source "$CONFIG"

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
  elif [ "$MULTICAST_ENABLED:$MULTICAST_ADDRESS:$MULTICAST_PORT" != "$CURRENT_MULTICAST_TARGET" ]; then
    # Same video, but multicast settings changed since VLC started — restart
    # to pick up the new sout config rather than waiting for the next switch.
    log "Multicast config changed — restarting VLC for: $WANTED"
    start_vlc "$WANTED"
  elif ! kill -0 "$VLC_PID" 2>/dev/null; then
    # VLC died unexpectedly — restart it
    log "VLC not running, restarting: $WANTED"
    start_vlc "$WANTED"
  fi

  # Also re-read schedule if sync.sh flagged an update
  if [ -f "$SITESTREAM_DIR/.schedule_updated" ]; then
    rm -f "$SITESTREAM_DIR/.schedule_updated"
    log "Schedule updated — re-evaluating."
    # Force re-evaluation next loop without waiting
  fi

  sleep 30
done
