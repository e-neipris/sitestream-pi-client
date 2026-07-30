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
# mtime of the onboarding/idle PNG the last time we told VLC to load it.
# Those two screens are fixed filenames regenerated in place (new QR/text
# content, same path) whenever connectivity or claim state changes — VLC has
# no idea the bytes under an already-open, --loop'd file changed, so without
# this it just keeps looping whatever it first loaded forever. Tracked
# separately from CURRENT_VIDEO_PATH (which only tells us the path is the
# same, not that the content behind it is still the same).
CURRENT_STATIC_IMAGE_MTIME=""
# Same blind spot as CURRENT_STATIC_IMAGE_MTIME above, but for a real
# scheduled video rather than the onboarding/idle screens: an SFTP re-upload
# overwrites a zone's existing VideoFile in place (see mediaSlot.ts) — same
# VideoFile id, same local path sync.sh downloads it to ($VIDEO_DIR/$videoId.mp4)
# — so WANTED never changes even though the bytes on disk did. Without this,
# VLC (already holding the old file open, --loop'd) just kept looping the
# stale content forever; sync.sh's own atomic `mv` onto that path doesn't
# affect a process that already has the old inode open by fd. Confirmed live:
# the immediate-push feature correctly woke the device and re-downloaded the
# new file within seconds, but the old video kept playing regardless since
# nothing here noticed.
CURRENT_VIDEO_MTIME=""
CURRENT_MULTICAST_TARGET=""
# What VLC was actually last started with — "disconnected" or "" — so a
# transition can be detected and acted on (see is_disconnected below), same
# tracked-vs-desired-state pattern as CURRENT_MULTICAST_TARGET above.
CURRENT_OVERLAY_STATE=""
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
#
# BENIGN_VOUT_LINES below are specific, confirmed-harmless lines from VLC's
# video-output startup. Most of this noise is now prevented at the source —
# start_vlc forces --vout drm_vout so VLC never auto-probes (and rejects)
# backends like xcb that were never going to work on this headless-DRM setup
# (no X server — lightdm is disabled, see install.sh) — so this list should
# stay short: only drm_vout's own internal connection-strategy fallbacks
# remain (atomic-vs-legacy KMS, lease-vs-direct-master), a small, already
# largely-enumerated set specific to that one module, not an open-ended
# category. The xcb line stays listed anyway as a safety net in case some
# code path still touches it despite the forced module. This is a whitelist
# of exact known-benign lines, not a blanket match on module name — a
# *different* error from any of these modules could still be real, so don't
# widen this past exact strings. Add new confirmed-benign lines here only
# after confirming (not assuming) playback actually continued normally:
#   - "drm_vout error: Failed to set atomic cap": the *previous* VLC process
#     (typically the onboarding-screen image) hasn't fully released the DRM
#     device yet when this new one starts — almost always right at the
#     onboarding-screen -> first-real-video transition on a freshly claimed
#     device.
#   - "drm_vout error: Failed to get xlease": tries to lease DRM access from
#     an X server first (the polite way to share DRM when a compositor owns
#     it); there's no X server running at all here, so this always fails
#     before falling through to direct DRM master access.
#   - "xcb error: window not available": VLC auto-probing the X11 backend
#     before reaching drm_vout — should no longer occur at all now that the
#     vout module is forced explicitly; kept as a safety net regardless.
BENIGN_VOUT_LINES='drm_vout error: Failed to set atomic cap|drm_vout error: Failed to get xlease|xcb error: window not available'
get_last_vlc_error() {
  [ -f "$SITESTREAM_DIR/logs/vlc.log" ] || return
  tail -n 50 "$SITESTREAM_DIR/logs/vlc.log" 2>/dev/null \
    | grep -i 'error:' \
    | grep -vE "$BENIGN_VOUT_LINES" \
    | tail -1
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

# Screen blanking is handled once, permanently, at the OS level — see
# install.sh's consoleblank=0 kernel cmdline addition. This used to run
# `xset` here instead, but that only ever worked because an X session was
# running for it to talk to; VLC now renders straight to the display via its
# own DRM/KMS output (see start_vlc), with no desktop session in the way at
# all (lightdm is disabled — same install.sh change).

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
  CURRENT_MULTICAST_TARGET="$MULTICAST_ENABLED:$MULTICAST_ADDRESS:$MULTICAST_PORT:$MULTICAST_INTERFACE"
  if [ "$MULTICAST_ENABLED" != "true" ] || [ -z "$MULTICAST_ADDRESS" ] || [ -z "$MULTICAST_PORT" ]; then
    return
  fi
  if ! command -v ffmpeg >/dev/null 2>&1; then
    log "ERROR: ffmpeg not installed — cannot start multicast output. Re-run install.sh (or apply a firmware update) to pick it up."
    return
  fi

  # localaddr= pins which NIC actually transmits the multicast packets,
  # overriding whatever the kernel's own routing table would otherwise pick
  # — needed the moment this device also uses a different interface (e.g.
  # wlan0) for its own SaaS traffic, so multicast doesn't silently try to go
  # out that one instead of the wired ingestion port. ffmpeg's udp muxer
  # takes a bind IP, not an interface name (unlike VLC's old --miface) — so
  # resolve MULTICAST_INTERFACE to its current IPv4 address here. Empty/unset
  # (the common case), or a lookup failure, just omits the param — same
  # "let the OS decide" behavior as before this existed.
  LOCALADDR_QS=""
  if [ -n "$MULTICAST_INTERFACE" ]; then
    IFACE_IP=$(ip -4 -o addr show "$MULTICAST_INTERFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    if [ -n "$IFACE_IP" ]; then
      LOCALADDR_QS="&localaddr=$IFACE_IP"
    else
      log "WARN: could not resolve an IPv4 address for multicast interface '$MULTICAST_INTERFACE' — letting the OS pick the outgoing interface instead."
    fi
  fi

  log "Starting multicast output: udp://$MULTICAST_ADDRESS:$MULTICAST_PORT${MULTICAST_INTERFACE:+ via $MULTICAST_INTERFACE}"
  # -c copy: remux the existing H.264 MP4 into MPEG-TS rather than
  # re-encoding it, which is what sync.sh downloads today. Revisit this once
  # you have the tuner manufacturer's exact ingest spec.
  #
  # Switched from VLC to ffmpeg here (VLC still drives the HDMI display
  # process above, untouched) after confirming live, on real hardware, that
  # VLC's own loop mechanism — --loop AND --input-repeat both — corrupts the
  # TS mux's PCR/DTS at every wraparound ("putting two PCRs at once", "packet
  # with too strange dts" firing exactly once per video-length interval,
  # reproduced on two different test files). A receiving player got the UDP
  # packets fine but could never demux a valid container out of them. ffmpeg
  # is the standard, purpose-built tool for exactly this "loop a file forever
  # to a live stream" case and regenerates continuous timestamps across the
  # loop boundary instead of restarting the clock.
  #
  # -re: read the input at its native frame rate. Without this, ffmpeg (with
  # no decode step to naturally pace it, same reason VLC needed forcing here
  # too) reads and remuxes the file as fast as disk I/O allows — a burst of
  # the whole video at once instead of paced real-time delivery.
  # -stream_loop -1: loop forever, ffmpeg's own native mechanism (built for
  # this, unlike VLC's) — no --sout-keep-style workaround needed.
  # pkt_size=1316: 7 TS packets (7*188B) per UDP datagram — the standard,
  # widely-used size for MPEG-TS-over-UDP that keeps payloads under typical
  # MTU and aligned to TS packet boundaries; matters for compatibility with
  # real IPTV tuner hardware, the eventual actual consumer of this stream.
  # ttl=32: multicast packets default to TTL 1 (one hop) on most stacks,
  # which silently dies at the first router/VLAN boundary between this
  # device and whatever's watching — set explicitly rather than relying on
  # a default that only works when sender and receiver share one L2 segment.
  ffmpeg -nostdin -hide_banner -loglevel warning \
    -re -stream_loop -1 -i "$video_path" \
    -c copy \
    -f mpegts \
    "udp://$MULTICAST_ADDRESS:$MULTICAST_PORT?ttl=32&pkt_size=1316${LOCALADDR_QS}" \
    >>"$SITESTREAM_DIR/logs/vlc-multicast.log" 2>&1 &
  MULTICAST_PID=$!
}

stop_vlc() {
  if [ -n "$VLC_PID" ] && kill -0 "$VLC_PID" 2>/dev/null; then
    kill "$VLC_PID"
    wait "$VLC_PID" 2>/dev/null
  fi
  VLC_PID=""
  CURRENT_VIDEO_PATH=""
  CURRENT_STATIC_IMAGE_MTIME=""
  CURRENT_OVERLAY_STATE=""
  stop_multicast
  pkill -f "vlc" 2>/dev/null || true
}

# True when this is a cloud-claimed device that hasn't actually reached the
# API in a while — QA feedback: a device losing connectivity mid-playback
# kept showing its cached video with zero on-screen indication anything was
# wrong. Deliberately NOT used for the onboarding/idle/rescue static screens
# above — those already say so explicitly (rescue screen: "Wi-Fi Connection
# Problem"); this is only for the "still playing real scheduled content"
# case those screens don't cover at all.
#
# .wifi_rescue_state (see wifi-ap-fallback.sh) is checked first as an
# immediate, high-confidence signal — it only covers local Wi-Fi association
# failure though, not "Wi-Fi's fine but the API/DNS/token is broken," which
# is why LAST_SYNC_OK_FILE's own age is checked too, not relied on alone.
# Threshold scales with the zone's own configured sync interval (2 missed
# cycles, same STALE_MISSED_SYNCS=2 shape the SaaS's own isDeviceDown uses)
# with a 10-minute floor so a fast 1-minute interval doesn't flap this
# on/off from ordinary jitter.
WIFI_RESCUE_STATE_FILE="$SITESTREAM_DIR/.wifi_rescue_state"
SYNC_INTERVAL_FILE="$SITESTREAM_DIR/.sync_interval"
LAST_SYNC_OK_FILE="$SITESTREAM_DIR/.last_sync_ok"
is_disconnected() {
  [ -n "${DEVICE_TOKEN:-}" ] || return 1
  [ -f "$WIFI_RESCUE_STATE_FILE" ] && return 0

  local last_ok interval_min threshold_min
  last_ok=$(cat "$LAST_SYNC_OK_FILE" 2>/dev/null)
  [[ "$last_ok" =~ ^[0-9]+$ ]] || return 0

  interval_min=$(cat "$SYNC_INTERVAL_FILE" 2>/dev/null)
  [[ "$interval_min" =~ ^[0-9]+$ ]] || interval_min=15
  threshold_min=$(( interval_min * 2 > 10 ? interval_min * 2 : 10 ))

  [ $(( $(date +%s) - last_ok )) -gt $(( threshold_min * 60 )) ]
}

# Used for the onboarding/idle static-image screens AND real scheduled video
# — see CURRENT_STATIC_IMAGE_MTIME/CURRENT_VIDEO_MTIME above for why
# path-equality alone isn't enough to know whether VLC needs to be told to
# reload.
get_mtime() {
  stat -c '%Y' "$1" 2>/dev/null
}

start_vlc() {
  local video_path="$1"
  # "no-multicast": used for the onboarding/idle static-image screens below —
  # start_multicast expects an actual video file to remux into MPEG-TS, and
  # feeding it a static PNG instead would push a broken/garbage stream to
  # whatever IPTV tuner is consuming this device's multicast output for the
  # entire time no real content is scheduled. Real scheduled video playback
  # never passes this.
  local skip_multicast="${2:-}"
  # "disconnected": adds a small bottom-right marquee, for real scheduled
  # video only (see is_disconnected above) — never passed for the
  # onboarding/idle/rescue static screens, which already communicate
  # connectivity problems a different way.
  local show_disconnected="${3:-}"
  stop_vlc
  log "Starting VLC: $video_path"

  MARQ_ARGS=()
  if [ "$show_disconnected" = "disconnected" ]; then
    # marq is a subpicture SOURCE (not a filter VLC applies after the fact),
    # composited by the vout itself — confirmed independent of --no-osd
    # above (that only suppresses VLC's own transient volume/seek popups).
    # --marq-timeout 0: show continuously, not just briefly on start.
    # Position 10 = bottom(8) + right(2).
    MARQ_ARGS=(
      --sub-source marq
      --marq-marquee "Not connected to SiteStream Cloud"
      --marq-position 10
      --marq-size 18
      --marq-opacity 200
      --marq-color 0xFBBF24
      --marq-timeout 0
    )
  fi

  # --vout drm_vout: without this, VLC auto-probes video-output backends in
  # priority order — xcb (X11) first, among others — before ever reaching
  # drm_vout, the one that actually works on this headless-DRM setup (no X
  # server; lightdm is disabled). Every backend it tries and rejects along
  # the way logs its own "error:" line (confirmed: "xcb error: window not
  # available" was VLC trying the X11 backend that was never going to work
  # here, not a real problem), which get_last_vlc_error below then surfaces
  # as a device health issue on a device that was never actually broken.
  # Forcing the module VLC was always going to land on anyway skips that
  # whole probe-and-reject sequence rather than reactively whitelisting each
  # backend's rejection message as it's discovered — see BENIGN_VOUT_LINES
  # below for the (much narrower, and not expected to keep growing) set of
  # messages drm_vout can still log internally even with this set.
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
  vlc \
    --intf dummy \
    --vout drm_vout \
    --fullscreen \
    --loop \
    --image-duration -1 \
    --no-video-title-show \
    --no-osd \
    --quiet \
    --aout alsa \
    "${MARQ_ARGS[@]}" \
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
  CURRENT_VIDEO_MTIME=$(get_mtime "$video_path")
  CURRENT_OVERLAY_STATE="$show_disconnected"
  LAST_VLC_TIME=""
  LAST_DISPLAYED_PICTURES="0"
  STALL_COUNT=0

  if [ "$skip_multicast" != "no-multicast" ]; then
    start_multicast "$video_path"
  fi
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
while true; do
  # Re-read config each loop so a multicast toggle (or the token, if reissued)
  # takes effect without needing to restart this service.
  [ -f "$CONFIG" ] && source "$CONFIG"

  # Not yet claimed AND nothing configured locally either — show the
  # onboarding screen (serial + QR code) instead of the normal schedule logic
  # below, entirely bypassing it. Generating is idempotent/cheap (skips if it
  # already exists — see generate-onboarding-screen.sh), so it's simplest to
  # just call it every tick rather than tracking whether it's already been
  # done. The moment sync.sh claims this device and writes a real
  # DEVICE_TOKEN into config.env, the very next loop tick (re-sourced above)
  # sees that and falls through to normal playback on its own — no separate
  # transition logic needed.
  #
  # The schedule.json check matters just as much as DEVICE_TOKEN: the
  # standalone-mode local portal (pi-portal/) lets someone build a schedule
  # entirely offline, with no cloud claim at all (see its own
  # regenerateScheduleFile, called the moment a schedule is created). Without
  # this check, this branch's unconditional `continue` meant an unclaimed
  # device NEVER reached get_current_video() below no matter what was
  # configured locally — the onboarding screen won permanently, and a
  # standalone device's uploaded video + schedule silently never played.
  if [ -z "$DEVICE_TOKEN" ] && [ ! -f "$SCHEDULE_FILE" ]; then
    # A saved Wi-Fi profile that can't actually connect (wrong/changed
    # password, moved site, ...) takes priority over the normal claim-QR
    # onboarding screen here — see wifi-ap-fallback.sh's "rescue mode" for
    # what writes/clears .wifi_rescue_state. Pointing someone at a claim URL
    # is useless anyway in this state: there's no network route out of this
    # device at all until the Wi-Fi problem is fixed.
    SCREEN_IMAGE=""
    SCREEN_LOG_MSG=""
    # A portal-initiated Wi-Fi join in progress takes priority over
    # everything below — see generate-wifi-connecting-screen.sh's own
    # comment for why this is checked (and ages out) independently of the
    # rescue-mode state right under it.
    if [ -f "$SITESTREAM_DIR/.wifi_connecting" ]; then
      "$SITESTREAM_DIR/generate-wifi-connecting-screen.sh" 2>>"$SITESTREAM_DIR/logs/vlc.log" || true
      [ -f "$SITESTREAM_DIR/wifi-connecting.png" ] && SCREEN_IMAGE="$SITESTREAM_DIR/wifi-connecting.png"
    fi
    if [ -n "$SCREEN_IMAGE" ]; then
      SCREEN_LOG_MSG="Wi-Fi join in progress — showing connecting screen."
    elif [ -f "$SITESTREAM_DIR/.wifi_rescue_state" ]; then
      "$SITESTREAM_DIR/generate-wifi-rescue-screen.sh" 2>>"$SITESTREAM_DIR/logs/vlc.log" || true
      [ -f "$SITESTREAM_DIR/wifi-rescue.png" ] && SCREEN_IMAGE="$SITESTREAM_DIR/wifi-rescue.png"
    fi
    if [ -n "$SCREEN_IMAGE" ] && [ -z "$SCREEN_LOG_MSG" ]; then
      SCREEN_LOG_MSG="Configured Wi-Fi network can't connect — showing rescue screen (hotspot + retry info)."
    elif [ -z "$SCREEN_IMAGE" ]; then
      "$SITESTREAM_DIR/generate-onboarding-screen.sh" 2>>"$SITESTREAM_DIR/logs/vlc.log" || true
      SCREEN_IMAGE="$SITESTREAM_DIR/onboarding.png"
      SCREEN_LOG_MSG="Not yet claimed — showing onboarding screen (serial + QR code)."
    fi
    if [ -f "$SCREEN_IMAGE" ]; then
      SCREEN_MTIME=$(get_mtime "$SCREEN_IMAGE")
      if [ "$CURRENT_VIDEO_PATH" != "$SCREEN_IMAGE" ] || [ "$SCREEN_MTIME" != "$CURRENT_STATIC_IMAGE_MTIME" ] || ! kill -0 "$VLC_PID" 2>/dev/null; then
        log "$SCREEN_LOG_MSG"
        start_vlc "$SCREEN_IMAGE" no-multicast
        CURRENT_STATIC_IMAGE_MTIME="$SCREEN_MTIME"
      fi
    fi
    write_status
    sleep 30
    continue
  fi

  WANTED=$(get_current_video)

  # Only meaningful once there's real scheduled content to show it over —
  # see is_disconnected's own comment for why the onboarding/idle/rescue
  # screens below are excluded.
  OVERLAY_WANT=""
  if [ -n "$WANTED" ] && is_disconnected; then
    OVERLAY_WANT="disconnected"
  fi

  if [ -z "$WANTED" ]; then
    # Nothing scheduled right now — show an idle screen (serial + how to
    # manage this device) instead of leaving the display blank. Same
    # idempotent-regeneration approach as the onboarding screen above: cheap
    # to call every tick, only actually rewrites the PNG when something
    # relevant (this device's IP) has changed. Rescue-mode takes priority
    # here too, same as the onboarding branch above — a claimed device with
    # nothing currently scheduled and unreachable Wi-Fi should tell whoever's
    # looking at the screen how to fix it, not just show the generic
    # "nothing scheduled" idle screen.
    IDLE_IMAGE=""
    IDLE_LOG_MSG=""
    # A portal-initiated Wi-Fi join in progress takes priority over
    # everything below — see generate-wifi-connecting-screen.sh's own
    # comment for why this is checked (and ages out) independently of the
    # rescue-mode state right under it. Mirrors the onboarding branch above.
    if [ -f "$SITESTREAM_DIR/.wifi_connecting" ]; then
      "$SITESTREAM_DIR/generate-wifi-connecting-screen.sh" 2>>"$SITESTREAM_DIR/logs/vlc.log" || true
      [ -f "$SITESTREAM_DIR/wifi-connecting.png" ] && IDLE_IMAGE="$SITESTREAM_DIR/wifi-connecting.png"
    fi
    if [ -n "$IDLE_IMAGE" ]; then
      IDLE_LOG_MSG="Wi-Fi join in progress — showing connecting screen."
    elif [ -f "$SITESTREAM_DIR/.wifi_rescue_state" ]; then
      "$SITESTREAM_DIR/generate-wifi-rescue-screen.sh" 2>>"$SITESTREAM_DIR/logs/vlc.log" || true
      [ -f "$SITESTREAM_DIR/wifi-rescue.png" ] && IDLE_IMAGE="$SITESTREAM_DIR/wifi-rescue.png"
    fi
    if [ -n "$IDLE_IMAGE" ] && [ -z "$IDLE_LOG_MSG" ]; then
      IDLE_LOG_MSG="Configured Wi-Fi network can't connect — showing rescue screen (hotspot + retry info)."
    elif [ -z "$IDLE_IMAGE" ]; then
      "$SITESTREAM_DIR/generate-idle-screen.sh" 2>>"$SITESTREAM_DIR/logs/vlc.log" || true
      IDLE_IMAGE="$SITESTREAM_DIR/idle.png"
      IDLE_LOG_MSG="No video scheduled — showing idle screen."
    fi
    if [ -f "$IDLE_IMAGE" ]; then
      IDLE_MTIME=$(get_mtime "$IDLE_IMAGE")
      if [ "$CURRENT_VIDEO_PATH" != "$IDLE_IMAGE" ] || [ "$IDLE_MTIME" != "$CURRENT_STATIC_IMAGE_MTIME" ] || ! kill -0 "$VLC_PID" 2>/dev/null; then
        log "$IDLE_LOG_MSG"
        start_vlc "$IDLE_IMAGE" no-multicast
        CURRENT_STATIC_IMAGE_MTIME="$IDLE_MTIME"
      fi
    else
      # Couldn't generate the idle screen (missing qrencode/imagemagick?) —
      # fall back to the old blank-screen behavior rather than show nothing
      # at all while also leaving a stale video frozen on screen.
      if { [ -n "$VLC_PID" ] && kill -0 "$VLC_PID" 2>/dev/null; } || { [ -n "$MULTICAST_PID" ] && kill -0 "$MULTICAST_PID" 2>/dev/null; }; then
        log "No video scheduled — stopping player."
        stop_vlc
      fi
    fi
  elif [ ! -f "$WANTED" ]; then
    log "WARN: Scheduled video not found locally: $WANTED (waiting for sync)"
  elif [ "$WANTED" != "$CURRENT_VIDEO_PATH" ] || [ "$(get_mtime "$WANTED")" != "$CURRENT_VIDEO_MTIME" ]; then
    # The mtime half of this catches an SFTP overwrite of the currently-
    # playing video: sync.sh downloads the new content to this exact same
    # path (same VideoFile id — see mediaSlot.ts's in-place update) via an
    # atomic `mv`, which VLC's already-open, --loop'd file handle has no way
    # to notice on its own. Same blind spot CURRENT_STATIC_IMAGE_MTIME
    # already covers for the onboarding/idle screens, extended here to real
    # scheduled video now that SFTP overwrite made "same path, new content"
    # a real case for it too.
    if [ "$WANTED" != "$CURRENT_VIDEO_PATH" ]; then
      log "Switching to: $WANTED"
    else
      log "Content updated for currently-playing video — reloading: $WANTED"
    fi
    start_vlc "$WANTED" "" "$OVERLAY_WANT"
  elif ! kill -0 "$VLC_PID" 2>/dev/null; then
    # VLC died unexpectedly — restart it (and multicast alongside it)
    VLC_RESTART_COUNT=$((VLC_RESTART_COUNT + 1))
    log "VLC not running, restarting: $WANTED"
    signal_urgent_health
    start_vlc "$WANTED" "" "$OVERLAY_WANT"
  elif [ "$OVERLAY_WANT" != "$CURRENT_OVERLAY_STATE" ]; then
    # Same video, but connectivity state flipped since VLC was last started —
    # the marq flag is startup-only (no live control channel for it — see
    # is_disconnected's comment), so this is a deliberate, infrequent
    # (minutes-scale) restart, same tradeoff already accepted for a
    # multicast-config change below.
    if [ "$OVERLAY_WANT" = "disconnected" ]; then
      log "Connectivity lost — adding on-screen indicator."
    else
      log "Connectivity restored — removing on-screen indicator."
    fi
    start_vlc "$WANTED" "" "$OVERLAY_WANT"
  elif [ "$MULTICAST_ENABLED:$MULTICAST_ADDRESS:$MULTICAST_PORT:$MULTICAST_INTERFACE" != "$CURRENT_MULTICAST_TARGET" ]; then
    # Was missing ":$MULTICAST_INTERFACE" on this side of the comparison —
    # CURRENT_MULTICAST_TARGET is always stored as all FOUR fields (see
    # start_multicast's own assignment), so this could never match as long
    # as multicast was enabled at all, even with no config change and no
    # interface selected (the trailing ":" alone made the strings differ).
    # Confirmed live: this silently force-restarted the multicast process on
    # EVERY 30s main-loop tick, forever — invisible on a short test clip
    # (indistinguishable from the video's own normal loop), but very visible
    # on a real multi-minute video, which never got to play past ~30s before
    # being torn down and relaunched from the beginning again. Same video,
    # same display process — only the multicast config changed (or was
    # toggled on/off). Restarting just that process doesn't touch the live
    # display at all. Logged only when it's actually enabled — otherwise
    # this fires every tick for a device with multicast off (nothing to
    # report; start_multicast() no-ops) and reads as if a stream is being
    # started when none ever is.
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
