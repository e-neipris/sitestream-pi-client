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
MULTICAST_PID=""

# VLC's local HTTP status interface — used only to poll actual playback
# progress for the stall watchdog below. Bound to 127.0.0.1 so it's never
# reachable off the device; the password only needs to satisfy VLC's "won't
# start http intf without one" requirement, not guard against a real attacker.
VLC_HTTP_PORT=8090
VLC_HTTP_PASSWORD="sitestream"
LAST_VLC_TIME=""
STALL_COUNT=0

# Polls VLC's HTTP status interface for current playback position (ms).
# Empty output means VLC's http interface isn't responding (still starting,
# or actually dead) — callers should treat that as "no data" rather than a
# stall, since kill -0 already covers the fully-dead case separately.
get_vlc_time() {
  curl -s --max-time 5 -u ":$VLC_HTTP_PASSWORD" \
    "http://127.0.0.1:$VLC_HTTP_PORT/requests/status.xml" 2>/dev/null \
    | grep -o '<time>[0-9]*</time>' | grep -o '[0-9]*'
}

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

# Multicast runs as a fully separate, headless VLC process from the display
# one below — NOT combined via `--sout '#duplicate{dst=display,...}'` in a
# single process. That was tried first and caused periodic HDMI blanking:
# once --sout is active, VLC forks video through one shared pipeline that has
# to serve both a decoded-frames branch (display) and an encoded-packets
# branch (the TS remux), and a stall at each keyframe boundary in the muxer
# stalled the shared pipeline enough to blank the live display, even though
# the network side absorbed it invisibly in its own buffer. Two independent
# processes means a hiccup in one can never touch the other.
stop_multicast() {
  if [ -n "$MULTICAST_PID" ] && kill -0 "$MULTICAST_PID" 2>/dev/null; then
    kill "$MULTICAST_PID"
    wait "$MULTICAST_PID" 2>/dev/null
  fi
  MULTICAST_PID=""
  CURRENT_MULTICAST_TARGET=""
}

start_multicast() {
  local video_path="$1"
  stop_multicast
  if [ "$MULTICAST_ENABLED" != "true" ] || [ -z "$MULTICAST_ADDRESS" ] || [ -z "$MULTICAST_PORT" ]; then
    return
  fi
  log "Starting multicast output: udp://$MULTICAST_ADDRESS:$MULTICAST_PORT"
  # No transcode{} stanza — this remuxes the existing H.264 MP4 into MPEG-TS
  # rather than re-encoding it, which is what sync.sh downloads today. Revisit
  # this once you have the tuner manufacturer's exact ingest spec.
  cvlc \
    --intf dummy \
    --vout dummy \
    --loop \
    --sout "#std{access=udp,mux=ts,dst=$MULTICAST_ADDRESS:$MULTICAST_PORT}" \
    --sout-keep \
    "$video_path" &
  MULTICAST_PID=$!
  CURRENT_MULTICAST_TARGET="$MULTICAST_ENABLED:$MULTICAST_ADDRESS:$MULTICAST_PORT"
}

stop_vlc() {
  if [ -n "$VLC_PID" ] && kill -0 "$VLC_PID" 2>/dev/null; then
    kill "$VLC_PID"
    wait "$VLC_PID" 2>/dev/null
  fi
  VLC_PID=""
  CURRENT_VIDEO_PATH=""
  stop_multicast
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

  DISPLAY=:0 vlc \
    --fullscreen \
    --loop \
    --no-video-title-show \
    --no-osd \
    --quiet \
    --extraintf http,logger \
    --http-host 127.0.0.1 \
    --http-port "$VLC_HTTP_PORT" \
    --http-password "$VLC_HTTP_PASSWORD" \
    --file-logging \
    --logfile "$SITESTREAM_DIR/logs/vlc.log" \
    --verbose 0 \
    "$video_path" &
  VLC_PID=$!
  CURRENT_VIDEO_PATH="$video_path"
  LAST_VLC_TIME=""
  STALL_COUNT=0

  start_multicast "$video_path"
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
    if { [ -n "$VLC_PID" ] && kill -0 "$VLC_PID" 2>/dev/null; } || { [ -n "$MULTICAST_PID" ] && kill -0 "$MULTICAST_PID" 2>/dev/null; }; then
      log "No video scheduled — stopping player."
      stop_vlc
    fi
  elif [ ! -f "$WANTED" ]; then
    log "WARN: Scheduled video not found locally: $WANTED (waiting for sync)"
  elif [ "$WANTED" != "$CURRENT_VIDEO_PATH" ]; then
    log "Switching to: $WANTED"
    start_vlc "$WANTED"
  elif ! kill -0 "$VLC_PID" 2>/dev/null; then
    # VLC died unexpectedly — restart it (and multicast alongside it)
    log "VLC not running, restarting: $WANTED"
    start_vlc "$WANTED"
  elif [ "$MULTICAST_ENABLED:$MULTICAST_ADDRESS:$MULTICAST_PORT" != "$CURRENT_MULTICAST_TARGET" ]; then
    # Same video, same display process — only the multicast config changed
    # (or was toggled on/off). Restarting just that process doesn't touch
    # the live display at all.
    log "Multicast config changed — restarting multicast output for: $WANTED"
    start_multicast "$WANTED"
  elif [ -n "$MULTICAST_PID" ] && ! kill -0 "$MULTICAST_PID" 2>/dev/null; then
    log "Multicast output died, restarting: $WANTED"
    start_multicast "$WANTED"
  else
    # Steady state — same video, VLC process alive, multicast unchanged. A
    # frozen decoder or dead X connection still passes kill -0, so cross-check
    # actual playback progress via VLC's HTTP interface. Two consecutive
    # identical readings (60s of zero progress) is treated as frozen; --loop
    # means normal playback always produces a *different* time between polls,
    # including right after it wraps back to the start.
    CURRENT_TIME=$(get_vlc_time)
    if [ -n "$CURRENT_TIME" ]; then
      if [ "$CURRENT_TIME" = "$LAST_VLC_TIME" ]; then
        STALL_COUNT=$((STALL_COUNT + 1))
        log "WARN: VLC playback time unchanged ($CURRENT_TIME) — stall check $STALL_COUNT/2"
        if [ "$STALL_COUNT" -ge 2 ]; then
          log "VLC appears frozen (no progress for 60s+) — restarting: $WANTED"
          start_vlc "$WANTED"
        fi
      else
        STALL_COUNT=0
      fi
      LAST_VLC_TIME="$CURRENT_TIME"
    fi
  fi

  # Also re-read schedule if sync.sh flagged an update
  if [ -f "$SITESTREAM_DIR/.schedule_updated" ]; then
    rm -f "$SITESTREAM_DIR/.schedule_updated"
    log "Schedule updated — re-evaluating."
    # Force re-evaluation next loop without waiting
  fi

  sleep 30
done
