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
STATUS_FILE="$SITESTREAM_DIR/status.json"
# Counts only *unexpected* restarts (death/freeze recovery) — not normal
# schedule-driven video switches. A rising count signals real instability;
# reported to the API via sync.sh's heartbeat so it shows up in the admin UI.
VLC_RESTART_COUNT=0
HEALTH_URGENT_FILE="$SITESTREAM_DIR/.health_urgent"

# player.sh has no network access of its own by design (see write_status
# below) — this breadcrumb is how an unexpected restart reaches the API
# within seconds instead of waiting up to the zone's full sync interval.
# listen.sh (a separate always-on process) watches for this file and, on
# seeing it, triggers an immediate sync.sh run — which is what actually
# reports it, same as any other heartbeat.
signal_urgent_health() {
  touch "$HEALTH_URGENT_FILE"
}

# Most recent ERROR-level line from vlc.log, if any — cheap enough to tail
# every loop tick given vlc.log is capped by logrotate.
get_last_vlc_error() {
  [ -f "$SITESTREAM_DIR/logs/vlc.log" ] || return
  tail -n 50 "$SITESTREAM_DIR/logs/vlc.log" 2>/dev/null | grep -i 'error:' | tail -1
}

# Written every loop tick so sync.sh can fold live playback state into its
# heartbeat — player.sh has no network access of its own by design (keeps it
# focused on local playback; sync.sh already owns all API communication).
write_status() {
  local current_video=""
  [ -n "$CURRENT_VIDEO_PATH" ] && current_video=$(basename "$CURRENT_VIDEO_PATH")
  local last_error
  last_error=$(get_last_vlc_error)

  jq -n \
    --arg currentVideo "$current_video" \
    --arg lastVideoError "$last_error" \
    --argjson vlcRestartCount "$VLC_RESTART_COUNT" \
    --arg updatedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{
      currentVideo: (if $currentVideo == "" then null else $currentVideo end),
      lastVideoError: (if $lastVideoError == "" then null else $lastVideoError end),
      vlcRestartCount: $vlcRestartCount,
      updatedAt: $updatedAt
    }' > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"
}

# VLC's local HTTP status interface — used only to poll actual playback
# health for the stall watchdog below. Bound to 127.0.0.1 so it's never
# reachable off the device; the password only needs to satisfy VLC's "won't
# start http intf without one" requirement, not guard against a real attacker.
VLC_HTTP_PORT=8090
VLC_HTTP_PASSWORD="sitestream"
LAST_VLC_TIME=""
# Baselined at "0", not "" — displayedpictures is monotonically increasing
# starting from 0, so "0" is a real, meaningful baseline (a stall reads as
# genuinely equal to it) rather than a sentinel that always looks like
# "progress" the first time a real reading comes in. By the time the first
# steady-state poll happens (a full 30s after start_vlc), a healthy player
# has displayed far more than 0 frames, so this never mistakes a normal
# startup for a stall.
LAST_DISPLAYED_PICTURES="0"
STALL_COUNT=0

# Single poll of VLC's HTTP status interface per loop tick — one curl call,
# both fields below are pulled from the same response. Empty output means
# the interface isn't responding at all (still starting, or actually dead).
get_vlc_status_xml() {
  curl -s --max-time 5 -u ":$VLC_HTTP_PASSWORD" \
    "http://127.0.0.1:$VLC_HTTP_PORT/requests/status.xml" 2>/dev/null
}

# Playback position (seconds) — kept only for the WARN log line's context now,
# NOT for the restart decision. Confirmed via a live mmal_codec decoder
# failure ("Pic has no attached buffer") that <time> keeps advancing normally
# — it's driven by the audio/demux clock, not by successful video decode —
# while the screen was fully black. A stall-detector built on this alone
# never fires for a video-only failure like that one.
extract_vlc_time() {
  echo "$1" | grep -o '<time>[0-9]*</time>' | grep -o '[0-9]*'
}

# Cumulative count of frames actually handed to the display, straight from
# VLC's own stats block (populated by default on this VLC build — no --stats
# flag needed, confirmed against real hardware). This is the actual signal
# that matters: whether it's advancing is a direct answer to "is video
# reaching the screen," unlike playback time. It reset to 0 for the entire
# duration of the mmal_codec failure that motivated this — <time> looked
# completely healthy throughout.
extract_vlc_displayed_pictures() {
  echo "$1" | grep -o '<displayedpictures>[0-9]*</displayedpictures>' | grep -o '[0-9]*'
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
  # Record the target state immediately, even when it resolves to "disabled" —
  # otherwise stop_multicast's reset to "" never gets superseded when the
  # guard below returns early, and the main loop's config-changed check keeps
  # re-triggering this function every tick forever, starving out the `else`
  # branch (the VLC stall/freeze watchdog) below it.
  CURRENT_MULTICAST_TARGET="$MULTICAST_ENABLED:$MULTICAST_ADDRESS:$MULTICAST_PORT"
  if [ "$MULTICAST_ENABLED" != "true" ] || [ -z "$MULTICAST_ADDRESS" ] || [ -z "$MULTICAST_PORT" ]; then
    return
  fi
  log "Starting multicast output: udp://$MULTICAST_ADDRESS:$MULTICAST_PORT"
  # No transcode{} stanza — this remuxes the existing H.264 MP4 into MPEG-TS
  # rather than re-encoding it, which is what sync.sh downloads today. Revisit
  # this once you have the tuner manufacturer's exact ingest spec.
  #
  # --aout alsa: VLC opens a local audio output for the input's audio track
  # even on a pure remux with no display branch — confirmed by testing, not
  # assumed. Left at its default (PulseAudio auto-probe), that open fails in
  # this context (a systemd system service has no desktop session for
  # PulseAudio's socket), the same failure seen on the display process.
  # ALSA talks to the kernel sound driver directly and doesn't need one.
  # Logging added here for the first time (this process previously had none)
  # specifically so an audio failure on the path that actually matters — the
  # multicast stream a hospitality TV system ingests — is visible instead of
  # silent.
  cvlc \
    --intf dummy \
    --vout dummy \
    --aout alsa \
    --loop \
    --sout "#std{access=udp,mux=ts,dst=$MULTICAST_ADDRESS:$MULTICAST_PORT}" \
    --sout-keep \
    --extraintf logger \
    --file-logging \
    --logfile "$SITESTREAM_DIR/logs/vlc-multicast.log" \
    --verbose 1 \
    "$video_path" &
  MULTICAST_PID=$!
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

  # --aout alsa: without this, VLC auto-probes and lands on PulseAudio, which
  # fails here ("PulseAudio server connection failure: Connection refused")
  # since this runs as a systemd system service with no desktop session for
  # PulseAudio's socket. ALSA talks to the kernel sound driver directly and
  # doesn't need one. Audio over HDMI is required even though nothing local
  # is listening — this feeds a hospitality TV system, not a room speaker.
  # --intf dummy: this was never set before, which meant VLC loaded its full
  # default interface (Qt on Raspberry Pi OS Desktop) despite --fullscreen/
  # --no-osd already hiding its chrome — the Qt event loop and its QTimers
  # were still live in the background. On a `systemctl restart` (e.g. after
  # a pushed update), systemd's default KillMode sends SIGTERM to this
  # process abruptly; tearing down Qt's timers from outside their owning
  # thread during that abrupt shutdown is exactly what produced
  # "QObject::~QObject: Timers cannot be stopped from another thread" in
  # journalctl and made restarts slow. --extraintf (http status server,
  # logger) are additional interfaces layered on top and are unaffected —
  # confirmed locally that the HTTP status interface still comes up fine
  # with --intf dummy set.
  # --image-duration -1: only relevant when $video_path is a still image (the
  # onboarding screen — see the unconfigured branch above), where VLC's image
  # demuxer otherwise advances/reloads it every few seconds by default,
  # producing a visible flash/reload loop instead of a steady display. No
  # effect on an actual video file — that path never touches the image
  # demuxer at all.
  DISPLAY=:0 vlc \
    --intf dummy \
    --fullscreen \
    --loop \
    --image-duration -1 \
    --no-video-title-show \
    --no-osd \
    --quiet \
    --aout alsa \
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
  LAST_DISPLAYED_PICTURES="0"
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

# Graceful shutdown on `systemctl stop`/`restart` — paired with KillMode=process
# in the systemd unit (systemd then only signals this process directly, not
# every process in its cgroup) so shutdown goes through our own stop_vlc
# (which also stops multicast) in order, instead of systemd blasting SIGTERM
# at player.sh and VLC simultaneously and uncoordinated. Without this, a
# restart (e.g. after a pushed self-update) killed VLC abruptly mid-Qt-event-
# loop, which produced "QObject::~QObject: Timers cannot be stopped from
# another thread" in journalctl and made restarts slow.
trap 'log "Shutting down…"; stop_vlc; exit 0' TERM INT

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

  # Not yet claimed — show the onboarding screen (serial + QR code) instead
  # of the normal schedule logic below, entirely bypassing it. Generating is
  # idempotent/cheap (skips if it already exists — see
  # generate-onboarding-screen.sh), so it's simplest to just call it every
  # tick rather than tracking whether it's already been done. The moment
  # sync.sh claims this device and writes a real DEVICE_TOKEN into
  # config.env, the very next loop tick (re-sourced above) sees that and
  # falls through to normal playback on its own — no separate transition
  # logic needed.
  if [ -z "$DEVICE_TOKEN" ]; then
    "$SITESTREAM_DIR/generate-onboarding-screen.sh" 2>>"$SITESTREAM_DIR/logs/vlc.log" || true
    ONBOARDING_IMAGE="$SITESTREAM_DIR/onboarding.png"
    if [ -f "$ONBOARDING_IMAGE" ] && { [ "$CURRENT_VIDEO_PATH" != "$ONBOARDING_IMAGE" ] || ! kill -0 "$VLC_PID" 2>/dev/null; }; then
      log "Not yet claimed — showing onboarding screen (serial + QR code)."
      start_vlc "$ONBOARDING_IMAGE"
    fi
    write_status
    sleep 30
    continue
  fi

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
    VLC_RESTART_COUNT=$((VLC_RESTART_COUNT + 1))
    log "VLC not running, restarting: $WANTED"
    signal_urgent_health
    start_vlc "$WANTED"
  elif [ "$MULTICAST_ENABLED:$MULTICAST_ADDRESS:$MULTICAST_PORT" != "$CURRENT_MULTICAST_TARGET" ]; then
    # Same video, same display process — only the multicast config changed
    # (or was toggled on/off). Restarting just that process doesn't touch
    # the live display at all. Logged only when it's actually enabled —
    # otherwise this fires every tick for a device with multicast off
    # (nothing to report; start_multicast() no-ops) and reads as if a
    # stream is being started when none ever is.
    if [ "$MULTICAST_ENABLED" = "true" ] && [ -n "$MULTICAST_ADDRESS" ] && [ -n "$MULTICAST_PORT" ]; then
      log "Multicast config changed — restarting multicast output for: $WANTED"
    fi
    start_multicast "$WANTED"
  elif [ -n "$MULTICAST_PID" ] && ! kill -0 "$MULTICAST_PID" 2>/dev/null; then
    log "Multicast output died, restarting: $WANTED"
    start_multicast "$WANTED"
  else
    # Steady state — same video, VLC process alive, multicast unchanged. A
    # frozen decoder or dead X connection still passes kill -0, so cross-check
    # actual playback health via VLC's HTTP interface.
    #
    # The health signal is displayedpictures (frames actually handed to the
    # display), NOT playback time — confirmed against a real mmal_codec
    # decoder failure ("Pic has no attached buffer") that left the screen
    # fully black for 5+ minutes with zero restarts: <time> climbed normally
    # the entire time (it tracks the audio/demux clock, which kept running
    # fine) while <displayedpictures> sat frozen at 0 and <lostpictures>
    # climbed instead. A watchdog built on time alone is structurally blind
    # to a video-only decode failure like that one — it was never going to
    # fire no matter how long the freeze lasted.
    #
    # Two consecutive identical readings (60s of zero new displayed frames)
    # is treated as frozen; a healthy player always displays more frames
    # between 30s polls, --loop wrap included (the counter is cumulative for
    # the process's lifetime and doesn't reset at the loop boundary).
    STATUS_XML=$(get_vlc_status_xml)
    CURRENT_TIME=$(extract_vlc_time "$STATUS_XML")
    CURRENT_DISPLAYED=$(extract_vlc_displayed_pictures "$STATUS_XML")

    if [ -n "$CURRENT_DISPLAYED" ] && [ "$CURRENT_DISPLAYED" != "$LAST_DISPLAYED_PICTURES" ]; then
      # New frames actually reached the display since the last poll — healthy.
      STALL_COUNT=0
      LAST_DISPLAYED_PICTURES="$CURRENT_DISPLAYED"
      [ -n "$CURRENT_TIME" ] && LAST_VLC_TIME="$CURRENT_TIME"
    else
      # Either the HTTP interface didn't respond at all, or displayedpictures
      # hasn't moved since last poll — both mean "can't confirm video is
      # actually reaching the screen," and both count toward the same
      # restart trigger.
      STALL_COUNT=$((STALL_COUNT + 1))
      if [ -z "$STATUS_XML" ]; then
        log "WARN: VLC HTTP status interface not responding — stall check $STALL_COUNT/2"
      else
        log "WARN: VLC displayedpictures unchanged ($CURRENT_DISPLAYED, time=$CURRENT_TIME) — stall check $STALL_COUNT/2"
      fi
      if [ "$STALL_COUNT" -ge 2 ]; then
        VLC_RESTART_COUNT=$((VLC_RESTART_COUNT + 1))
        log "VLC appears frozen or unresponsive (60s+) — restarting: $WANTED"
        signal_urgent_health
        start_vlc "$WANTED"
      fi
    fi
  fi

  # Also re-read schedule if sync.sh flagged an update
  if [ -f "$SITESTREAM_DIR/.schedule_updated" ]; then
    rm -f "$SITESTREAM_DIR/.schedule_updated"
    log "Schedule updated — re-evaluating."
    # Force re-evaluation next loop without waiting
  fi

  write_status

  sleep 30
done
