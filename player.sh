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
# Fixed local port for the persistent multicast VLC instance's RC (remote
# control) interface — see start_multicast's own comment for why this
# process now stays alive across a video change instead of being killed and
# relaunched. Loopback-only (bound to 127.0.0.1 explicitly below), same
# trust boundary as the HDMI VLC's existing --http-host 127.0.0.1 interface;
# RC has no password option (confirmed via `vlc -H --advanced` — HTTP does,
# RC doesn't), so this relies on that binding alone.
MULTICAST_RC_PORT=9090
# Which playlist item id, inside the persistent multicast VLC instance's own
# internal playlist, is the one currently playing — needed to delete the OLD
# item after a live swap (see swap_multicast_video). Reset alongside
# MULTICAST_PID whenever the process itself restarts, since a fresh process
# starts its own id numbering over from scratch.
CURRENT_MULTICAST_PLID=""
# The video path the persistent multicast VLC instance is actually playing
# right now — distinct from CURRENT_MULTICAST_TARGET (config: enabled/
# address/port/interface only, see start_multicast) so the two can be
# compared independently: a config change needs a full process restart (the
# --sout target is baked in at launch), but a video-only change can use the
# much gentler live swap instead.
CURRENT_MULTICAST_VIDEO_PATH=""
# The enabled:address:port:interface signature the CURRENTLY RUNNING
# multicast process was actually launched with — compared against a fresh
# computation of the same fields each call to decide whether the process can
# stay alive (video-only change, or nothing changed) or needs a full restart
# (any of those four actually changed). Deliberately separate from
# CURRENT_MULTICAST_TARGET above, which the main loop uses for a different
# purpose (whether to call start_multicast at all) and includes the video
# path — this one deliberately doesn't, since a video-only change is exactly
# the case that should NOT force a restart.
MULTICAST_PROCESS_CONFIG=""
# What VLC was actually last started with — "disconnected" or "" — so a
# transition can be detected and acted on (see is_disconnected below), same
# tracked-vs-desired-state pattern as CURRENT_MULTICAST_TARGET above.
CURRENT_OVERLAY_STATE=""
# Same tracked-vs-desired-state pattern as CURRENT_OVERLAY_STATE above, for
# the same reason: HEADLESS_MODE flipping while VLC is already running is
# otherwise invisible to every branch below, since none of them treat the
# flag itself changing as a reason to re-evaluate — they only react to the
# wanted *video* changing, VLC dying, etc. Without this, turning Headless on
# for a device that's actively playing never actually stops the HDMI output
# already running; it only prevents a *future* start. See the main loop's
# own HEADLESS_MODE-changed check.
CURRENT_HEADLESS_STATE=""
VLC_PID=""
MULTICAST_PID=""
# PID of the backgrounded `sleep 30 & wait $!` (see the loop's own comment),
# tracked so the shutdown trap can reap it directly instead of leaving it to
# outlive the service and log a "left-over process... Ignoring" warning on
# the next start.
LOOP_SLEEP_PID=""
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
  MULTICAST_PROCESS_CONFIG=""
  CURRENT_MULTICAST_VIDEO_PATH=""
  CURRENT_MULTICAST_PLID=""
  # Backstop, same reasoning as stop_vlc's own `pkill -f "vlc"` below —
  # $MULTICAST_PID only ever tracks a process THIS instance of player.sh
  # itself started. Confirmed live as a real incident, not theoretical: a
  # multicast stream kept running with no trace of it in the SaaS or in
  # config.env at all, because the broadcast process was orphaned by a
  # PREVIOUS instance of player.sh that didn't exit through the graceful
  # trap below (crash, OOM-kill, anything that skips it) — Restart=always
  # brought player.sh back with a fresh, empty $MULTICAST_PID that had no
  # way to ever know that old process existed. This catches it regardless of
  # which instance started it.
  #
  # Matches on "--sout" specifically, not just "vlc" — cvlc is a wrapper
  # script that execs `vlc -I dummy "$@"` (confirmed live: ps shows the
  # actual running process as plain `vlc`, never `cvlc`), so a broad "vlc"
  # pattern would ALSO match the completely separate HDMI-display VLC
  # process stop_vlc below manages, and kill it by accident every time this
  # runs. --sout only ever appears on the multicast broadcast invocation.
  pkill -f "vlc.*--sout" 2>/dev/null || true
}

# Sends $1 as a command to the persistent multicast VLC's RC interface and
# prints back whatever it responds with. Uses bash's own /dev/tcp facility
# rather than depending on nc/netcat being installed fleet-wide — confirmed
# live this works fine against VLC's RC protocol. Returns non-zero (with no
# output) if the connection itself fails, e.g. the process died or the RC
# interface isn't up yet — callers treat that as "swap failed, fall back to
# a full restart" rather than trusting a response that never arrived.
send_multicast_rc() {
  local cmd="$1"
  local rc_fd
  local err_tmp="/tmp/.rc_connect_err.$$"
  exec {rc_fd}<>"/dev/tcp/127.0.0.1/$MULTICAST_RC_PORT" 2>"$err_tmp"
  local connect_rc=$?
  local connect_err
  connect_err=$(cat "$err_tmp" 2>/dev/null)
  rm -f "$err_tmp"
  # >&2, not stdout: this function's stdout IS its return value (the RC
  # response text), captured via $(...) at every call site. A plain `log`
  # here would silently splice this debug text into that captured value —
  # confirmed live this is exactly what broke the `= "ok"` check below.
  log "DEBUG rc: cmd=[$cmd] connect_rc=$connect_rc connect_err=[$connect_err] fd=$rc_fd openfds=$(ls /proc/self/fd 2>/dev/null | wc -l)" >&2
  if [ "$connect_rc" -ne 0 ]; then return 1; fi
  # VLC writes its own banner ("VLC media player ... Command Line Interface
  # initialized...") the instant a new RC connection opens, unprompted and
  # before it has even seen our command. Confirmed live: without draining
  # this first, that banner is what a subsequent read actually returns —
  # the real command response either never gets read at all (still sitting
  # unread in the socket when we give up) or arrives concatenated after it,
  # and either way the "new input:" match below silently fails every time.
  local banner
  banner=$(timeout 0.5 cat <&"$rc_fd")
  log "DEBUG rc: cmd=[$cmd] drained banner=[$banner]" >&2
  printf '%s\n' "$cmd" >&"$rc_fd"
  local write_rc=$?
  local out
  out=$(timeout 2 cat <&"$rc_fd")
  local read_rc=$?
  log "DEBUG rc: cmd=[$cmd] write_rc=$write_rc read_rc=$read_rc out=[$out]" >&2
  exec {rc_fd}<&-
  exec {rc_fd}>&-
  printf '%s' "$out"
}

# The actual mechanism this whole persistent-process design exists for:
# switch the currently-scheduled video WITHOUT tearing down the UDP stream
# to SMARTBOX, unlike the old kill-and-relaunch-ffmpeg/cvlc approach every
# earlier release used. Confirmed live: SMARTBOX froze on the last frame and
# needed a manual reset every time a schedule change killed and restarted
# the broadcast process — a receiver-side re-acquisition problem that a
# fresh process/fresh UDP source port makes worse, not better.
#
# --sout-keep (already on the persistent process — see start_multicast) is
# VLC's own documented mechanism for exactly this: "keep an unique stream
# output instance across multiple playlist items." The RC `add` command
# queues a new item and starts playing it immediately without stopping the
# current one first — confirmed live via tcpdump/tshark this is dramatically
# gentler than `clear` (which stops the current item outright before adding
# the new one): `add` measured a ~44ms max gap at the transition, `clear`
# measured ~460ms for the exact same swap. The playlist is then explicitly
# pruned back down to one item (deleting the old one) so --loop only ever
# has the new video to cycle — confirmed live this is what actually happens
# if the old item is left in place: --loop eventually wraps back around to
# it and undoes the whole swap.
#
# Echoes "ok" on confirmed success, nothing on failure — the caller falls
# back to a full restart on anything other than "ok", since a half-completed
# swap (new item added but old one never confirmed/removed) is worse than
# just paying the restart cost this one time.
swap_multicast_video() {
  local new_path="$1"
  local new_filename
  new_filename=$(basename "$new_path")

  local add_response
  add_response=$(send_multicast_rc "add file://$new_path")
  local add_rc=$?
  # >&2 — same reason as send_multicast_rc's DEBUG lines: this function's
  # stdout is its "ok"/empty return value, captured via $(...) by the caller.
  log "DEBUG swap: add_rc=$add_rc add_response=[$add_response]" >&2
  if [ "$add_rc" -ne 0 ]; then return 1; fi

  # Deliberately NOT gating on "new input:" appearing in add_response above.
  # Confirmed live: that text is an async status notification, not a
  # synchronous reply to `add` — VLC can (and does) still be printing the RC
  # banner or simply hasn't gotten to it yet by the time our read window
  # closes, even seconds later. Gating on it made this fail almost every
  # time regardless of whether the add itself actually worked. The playlist
  # query below is authoritative either way (it reflects queue state, not a
  # timing-dependent event), so confirming success there is both sufficient
  # and far more reliable. A short retry loop covers the (much smaller) lag
  # between `add` returning and the item actually showing up in `playlist`.
  local playlist_response new_plid attempt
  for attempt in 1 2 3 4 5; do
    playlist_response=$(send_multicast_rc "playlist")
    local playlist_rc=$?
    log "DEBUG swap: attempt=$attempt playlist_rc=$playlist_rc playlist_response=[$playlist_response]" >&2
    if [ "$playlist_rc" -eq 0 ]; then
      # Only ever trust the line VLC itself marks as currently playing (*),
      # not just any line containing the filename. Confirmed live: matching
      # on filename alone breaks the moment the same video gets swapped in
      # more than once (completely normal for real scheduling — alternating
      # between two videos through the day) — a stale leftover entry from an
      # earlier swap has the exact same filename, and `head -1` could just
      # as easily grab that dead entry's id as the real new one. When that
      # happens, CURRENT_MULTICAST_PLID gets set to the wrong id, its delete
      # below never removes the real old item, and orphaned entries pile up
      # in the playlist forever — which --loop eventually wraps around into,
      # undoing the swap. The `*` marker is unambiguous regardless of how
      # many stale same-named entries are already sitting in the playlist.
      new_plid=$(printf '%s' "$playlist_response" | grep -E '^\| *\*[0-9]+' | grep -F "$new_filename" | sed -nE 's/^\| *\*([0-9]+).*/\1/p' | head -1)
      [ -n "$new_plid" ] && break
    fi
    sleep 0.3
  done
  if [ -z "$new_plid" ]; then
    return 1
  fi

  # Delete every OTHER item in the playlist, not just the single previously-
  # tracked CURRENT_MULTICAST_PLID — self-heals any stale leftovers from an
  # earlier swap whose own delete silently failed (or, before the `*`-marker
  # fix above, from new_plid itself having been wrong), instead of letting
  # them silently compound across every future swap. Filtered to lines
  # containing ".mpg" — our multicast files are always named
  # "*-multicast.mpg" — so this only ever matches real playlist entries,
  # never the "Playlist"/"Media Library" root nodes RC's listing also
  # includes (those have no file extension in their own text).
  local old_plids
  old_plids=$(printf '%s' "$playlist_response" | grep -F '.mpg' | sed -nE 's/^\| *\*?([0-9]+) - .*/\1/p' | grep -v "^${new_plid}\$")
  local old_plid
  for old_plid in $old_plids; do
    send_multicast_rc "delete $old_plid" >/dev/null || true
  done

  CURRENT_MULTICAST_PLID="$new_plid"
  echo ok
}

start_multicast() {
  # The MPEG-2 Program Stream variant sync.sh downloaded for the currently-
  # scheduled video (schedule.json's multicastLocalPath — see get_current_video)
  # — NOT the H.264 file VLC plays over HDMI. Empty whenever the SaaS side
  # hasn't finished transcoding it yet (or the file simply doesn't need one —
  # see services/multicastTranscode.ts), which is the common case for most
  # of a device's uptime right after multicast gets newly enabled.
  local multicast_video_path="$1"
  # Record the target state immediately, even when it resolves to "disabled"
  # or "not ready yet" — otherwise the main loop's config-changed check keeps
  # re-triggering this function every tick forever, starving out the `else`
  # branch (the VLC stall/freeze watchdog) below it. Must match the main
  # loop's own copy of this exact string field-for-field, or the two can
  # never agree and this restarts on every single tick forever — see the
  # MULTICAST_INTERFACE comment lower down in this file for the exact bug
  # that happens when they drift out of sync. This is purely the "should the
  # main loop even call start_multicast" signal — separate from
  # MULTICAST_PROCESS_CONFIG below, which is what THIS function uses to
  # decide whether the already-running process (if any) can keep going.
  CURRENT_MULTICAST_TARGET="$MULTICAST_ENABLED:$MULTICAST_ADDRESS:$MULTICAST_PORT:$MULTICAST_INTERFACE:$multicast_video_path"
  if [ "$MULTICAST_ENABLED" != "true" ] || [ -z "$MULTICAST_ADDRESS" ] || [ -z "$MULTICAST_PORT" ]; then
    stop_multicast
    return
  fi
  if [ -z "$multicast_video_path" ]; then
    log "Multicast enabled but no MPEG-2 variant is ready yet for the current video — waiting for the SaaS transcode to finish (see the Media page)."
    return
  fi
  if [ ! -f "$multicast_video_path" ]; then
    log "Multicast enabled and the SaaS says a variant is ready, but it's not on disk yet — waiting for sync.sh to finish downloading it."
    return
  fi
  if ! command -v cvlc >/dev/null 2>&1; then
    log "ERROR: cvlc not installed — cannot start multicast output. Re-run install.sh (or apply a firmware update) to pick it up."
    return
  fi

  local config_signature="$MULTICAST_ENABLED:$MULTICAST_ADDRESS:$MULTICAST_PORT:$MULTICAST_INTERFACE"
  local process_alive="false"
  [ -n "$MULTICAST_PID" ] && kill -0 "$MULTICAST_PID" 2>/dev/null && process_alive="true"

  # Steady state: same process, same video already playing — nothing to do.
  # The main loop only calls start_multicast when ITS OWN copy of the target
  # string changed, but that string includes fields (MULTICAST_ENABLED
  # toggling back to the same value some other way, headless-mode-driven
  # calls, etc.) that don't always mean the video itself actually changed.
  if [ "$process_alive" = "true" ] && [ "$config_signature" = "$MULTICAST_PROCESS_CONFIG" ] \
    && [ "$multicast_video_path" = "$CURRENT_MULTICAST_VIDEO_PATH" ]; then
    return
  fi

  # Video-only change against an already-running, correctly-configured
  # process — the gentle path this whole redesign exists for. Address/port/
  # interface changes still fall through to the full restart below: those
  # are baked into --sout at launch and can't be changed on a live process.
  if [ "$process_alive" = "true" ] && [ "$config_signature" = "$MULTICAST_PROCESS_CONFIG" ]; then
    log "Switching multicast output to: $multicast_video_path (live, no stream interruption)"
    if [ "$(swap_multicast_video "$multicast_video_path")" = "ok" ]; then
      CURRENT_MULTICAST_VIDEO_PATH="$multicast_video_path"
      return
    fi
    log "WARN: live multicast swap failed — falling back to a full restart."
    # Falls through to the full restart below.
  fi

  # Full restart: first launch, config changed, process died, or the live
  # swap above failed and needs a clean slate to retry from.
  stop_multicast

  # --miface takes an interface NAME directly (unlike ffmpeg's udp muxer,
  # which needed an IP resolved via `ip addr` — see the git history on this
  # function for that version). Confirmed live this is a real, global VLC
  # option (`vlc -H --advanced` lists it under core network options), NOT a
  # sub-option of the #std{access=udp{...}} chain the way it's commonly
  # written online — `udp{miface=eth0}` was tried first and rejected
  # outright ("option miface is unknown"). Omitted entirely when
  # MULTICAST_INTERFACE is unset, same "let the OS decide" behavior as
  # before.
  MIFACE_ARGS=()
  if [ -n "$MULTICAST_INTERFACE" ]; then
    MIFACE_ARGS=(--miface "$MULTICAST_INTERFACE")
  fi

  # Confirmed live (manual testing against real SMARTBOX hardware) that a
  # cold start's burst — invisible as a sustained-average bitrate problem in
  # packet-capture analysis at 50ms granularity, but real at a finer
  # timescale than that could resolve — overwhelms the receiver's ingest
  # hardware and locks it up until power-cycled. A kernel-level token-bucket
  # queueing discipline on the outgoing interface caps any burst regardless
  # of how VLC internally paces its own output, closing a gap a purely
  # application-side fix can't. `replace`, not `add`: safe to re-run every
  # time this function reaches a cold start (idempotent — a second
  # application just re-asserts the same rule), so this is always in place
  # before a cold start can happen, including the very first one after boot,
  # without needing separate one-time setup plumbing anywhere else.
  # rate: MULTICAST_MAX_BITRATE_KBPS if set (see sync.sh/pi-portal's own
  # comments on that field), else 5600 — the exact value confirmed live to
  # let SMARTBOX recover reliably, deliberately a little under the encode's
  # own 6000k maxrate so the cap actually bites instead of never engaging.
  # burst/latency are TBF tuning constants, not per-device config — 32kb is
  # roughly one video frame's worth of data at this bitrate (how much can
  # leave in a single instantaneous burst before throttling kicks in); 250ms
  # latency is how long TBF may hold a packet queued before dropping it
  # rather than delaying it further. Interface matches whatever
  # MULTICAST_INTERFACE/--miface above is already sending on, not
  # necessarily eth0 — defaults to eth0 only when that's unset, same
  # fallback the OS itself would otherwise pick.
  local tc_rate_kbit="${MULTICAST_MAX_BITRATE_KBPS:-5600}"
  local tc_iface="${MULTICAST_INTERFACE:-eth0}"
  if command -v tc >/dev/null 2>&1; then
    sudo tc qdisc replace dev "$tc_iface" root tbf rate "${tc_rate_kbit}kbit" burst 32kb latency 250ms \
      >>"$SITESTREAM_DIR/logs/vlc-multicast.log" 2>&1 \
      || log "WARN: failed to apply tc rate-limit on $tc_iface — cold-start bitrate burst protection not active this launch."
  else
    log "WARN: tc not installed — cold-start bitrate burst protection not active. Re-run install.sh to pick it up."
  fi

  log "Starting multicast output: udp://$MULTICAST_ADDRESS:$MULTICAST_PORT${MULTICAST_INTERFACE:+ via $MULTICAST_INTERFACE} ($multicast_video_path)"
  # The SMARTBOX-class hardware these feeds only decodes MPEG-2, not the
  # H.264 everything else in the fleet uses — reported "Input Present: No
  # PSI data" (a misleading error) against every H.264 approach tried here.
  # See services/multicastTranscode.ts on the SaaS side for the actual
  # transcode command — this device just downloads the finished MPEG-2 file
  # (sync.sh) and loops it out; no re-encode happens here, this is a remux.
  #
  # cvlc, not ffmpeg -c copy -muxrate (tried first, in earlier releases) —
  # confirmed live via tcpdump/tshark on the real device that ffmpeg's
  # output, even with -muxrate padding, stayed bursty around every keyframe
  # (200+ ms gaps against a <40ms spec, tuning the rate higher didn't help)
  # and that was enough to make SMARTBOX give up after ~20s. cvlc's
  # steady-state output measured completely clean by comparison — 0 gaps
  # over 40ms in multiple captures, max ~25ms — once past a brief (~1-2s)
  # burst right at startup while sout-keep does its initial buffer fill;
  # that startup burst appears to be a one-time thing, not a recurring
  # per-loop artifact (confirmed by capturing across an actual loop
  # wraparound with clean, monotonically increasing PCR the whole way
  # through — see the note on --loop below).
  #
  # --loop: this is the same flag an EARLIER attempt at cvlc broadcasting
  # was abandoned over — confirmed live at the time that VLC's --loop
  # corrupted the TS mux's PCR/DTS at every wraparound for H.264 content
  # ("putting two PCRs at once", "packet with too strange dts"). Retested
  # specifically for that regression with this MPEG-2 content by capturing
  # PCR values across a real loop boundary (the source is ~272s) and
  # checking for any backward jump — none found across 375 samples spanning
  # the wraparound. Whatever caused the original bug does not reproduce
  # here; if it ever does, the field symptom would be a receiver glitch
  # roughly once per video-length interval, not a constant problem.
  # --sout-keep: keeps the stream-output chain alive/warm across BOTH the
  # --loop restart AND a live video swap (see swap_multicast_video above) —
  # the entire reason a video change no longer needs to kill this process.
  # --ttl 32: multicast packets default to TTL 1 (one hop) on most stacks,
  # which silently dies at the first router/VLAN boundary between this
  # device and whatever's watching — set explicitly rather than relying on
  # a default that only works when sender and receiver share one L2 segment.
  # --extraintf rc --rc-host 127.0.0.1:$MULTICAST_RC_PORT: the control
  # channel swap_multicast_video drives. Loopback-only, no password option
  # exists for RC (see MULTICAST_RC_PORT's own comment above).
  cvlc -I dummy \
    "$multicast_video_path" \
    --sout="#std{access=udp,mux=ts,dst=$MULTICAST_ADDRESS:$MULTICAST_PORT}" \
    --sout-keep \
    --loop \
    --ttl 32 \
    --extraintf rc \
    --rc-host "127.0.0.1:$MULTICAST_RC_PORT" \
    "${MIFACE_ARGS[@]}" \
    >>"$SITESTREAM_DIR/logs/vlc-multicast.log" 2>&1 &
  MULTICAST_PID=$!
  MULTICAST_PROCESS_CONFIG="$config_signature"
  CURRENT_MULTICAST_VIDEO_PATH="$multicast_video_path"

  # Discover the id VLC assigned the initial command-line video, the same
  # way swap_multicast_video finds a freshly-added one — needed so the
  # FIRST live swap later has a valid old-id to delete. A few short retries
  # rather than one fixed sleep: the RC interface needs a brief moment to
  # come up after the process forks, and the exact delay isn't worth
  # over-tuning since this only runs once per process lifetime.
  local new_filename discovered_plid attempt
  new_filename=$(basename "$multicast_video_path")
  for attempt in 1 2 3 4 5; do
    sleep 1
    discovered_plid=$(send_multicast_rc "playlist" | grep -F "$new_filename" | sed -nE 's/^\| *\*?([0-9]+).*/\1/p' | head -1)
    if [ -n "$discovered_plid" ]; then
      CURRENT_MULTICAST_PLID="$discovered_plid"
      break
    fi
  done
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
  # Deliberately does NOT touch multicast (no stop_multicast call here) —
  # start_vlc calls this unconditionally on every single call, including a
  # plain schedule-driven video change, which is exactly the case the
  # persistent-multicast-process redesign exists to NOT interrupt (see
  # start_multicast/swap_multicast_video). The two processes' lifecycles are
  # deliberately independent now: callers that actually want multicast
  # stopped too (nothing scheduled at all, real shutdown) call
  # stop_multicast explicitly alongside this, not through it.
  #
  # Matches on "--vout drm_vout" specifically, not just "vlc" — the
  # multicast process is also plain `vlc` under the hood now (cvlc is a
  # wrapper — see stop_multicast's own comment), and stop_vlc runs on every
  # single schedule-driven video change. A broad "vlc" pattern here would
  # kill the persistent multicast process on every one of those calls,
  # silently undoing the entire point of the live-swap redesign (see
  # start_multicast/swap_multicast_video) via this backstop alone, even
  # after removing the direct stop_multicast call above. --vout drm_vout
  # only ever appears on the HDMI-display invocation.
  pkill -f "vlc.*--vout drm_vout" 2>/dev/null || true
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
  # The MPEG-2 variant of $video_path (schedule.json's multicastLocalPath),
  # if the current schedule entry has one — see get_current_video and
  # start_multicast's own comment for why this is a separate file rather
  # than a flag on $video_path.
  local multicast_video_path="${4:-}"
  stop_vlc
  # Explicit, not a side effect of stop_vlc (which deliberately no longer
  # touches multicast at all — see its own comment) — a static onboarding/
  # idle/rescue screen means there's no real video to broadcast, so any
  # multicast stream already running from before this transition needs to
  # actually stop here. Real scheduled video (skip_multicast unset) never
  # takes this path — start_multicast below decides on its own whether that
  # case needs a restart, a live swap, or nothing at all.
  if [ "$skip_multicast" = "no-multicast" ]; then
    stop_multicast
  fi

  # HEADLESS_MODE (from config.env, pushed via Device.headlessMode — see
  # sync.sh) — this device has no HDMI display attached at all. VLC's DRM/KMS
  # output can't acquire a connector with no cable/EDID detected (confirmed
  # live: "Failed to find output <auto>", not in BENIGN_VOUT_LINES) without
  # hdmi_force_hotplug, which isn't set anywhere in this fleet — every launch
  # attempt fails, reads as a crashed VLC, and restarts in a loop forever.
  # Skipping the actual launch here — while still updating the bookkeeping
  # below and still calling start_multicast exactly as normal — means every
  # other branch in the main loop that reacts to "did the wanted video
  # change" keeps working unchanged; only the parts that assume a running
  # VLC process is the expected steady state need their own guard (see
  # HEADLESS_MODE checks further down in the main loop).
  if [ "${HEADLESS_MODE:-}" = "true" ]; then
    log "Headless mode — skipping HDMI output for: $video_path"
    CURRENT_VIDEO_PATH="$video_path"
    CURRENT_VIDEO_MTIME=$(get_mtime "$video_path")
    CURRENT_OVERLAY_STATE="$show_disconnected"
    CURRENT_HEADLESS_STATE="true"
    if [ "$skip_multicast" != "no-multicast" ]; then
      start_multicast "$multicast_video_path"
    fi
    return
  fi

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
  CURRENT_HEADLESS_STATE="${HEADLESS_MODE:-}"
  LAST_VLC_TIME=""
  LAST_DISPLAYED_PICTURES="0"
  STALL_COUNT=0

  if [ "$skip_multicast" != "no-multicast" ]; then
    start_multicast "$multicast_video_path"
  fi
}

# Prints two lines for the schedule entry that should be playing right now:
# localPath (H.264, VLC/HDMI), then multicastLocalPath (MPEG-2, may be empty —
# see get_current_video's own comment on the two paths' relationship). Both
# read from a single jq call/single selected entry rather than two separate
# lookups, so a schedule-boundary tick can never see the two disagree about
# which entry is "current."
get_current_video() {
  [ -f "$SCHEDULE_FILE" ] || return

  local now_hhmm
  now_hhmm=$(date '+%H:%M')
  local now_dow
  now_dow=$(date '+%w')  # 0=Sun, 6=Sat
  local now_date
  now_date=$(date '+%Y-%m-%dT00:00:00.000Z')

  # Use jq to find the highest-priority schedule entry active right now.
  #
  # .endTime >= $now, NOT >: confirmed live as the actual root cause of two
  # SMARTBOX-feeding devices restarting VLC at fixed times every day (00:00
  # and 06:00) — a schedule entry ending at "23:59" (the standard "all day"
  # pattern: startTime 00:00, endTime 23:59) stopped matching the instant
  # the clock read "23:59" under a strict >, since now_hhmm is minute-
  # granularity (date +%H:%M, no seconds) — "23:59" > "23:59" is false —
  # leaving the entire 23:59 minute with nothing scheduled at all, every
  # single day, for what is likely the most common schedule shape in the
  # product. That "nothing scheduled" state is what triggers start_vlc's own
  # no-multicast path to stop the multicast process outright (see its own
  # comment) — so the following minute's video reappearing forces a full
  # cold-start restart instead of a live swap, right at the schedule
  # boundary. Measured live via packet capture: a full restart on this
  # hardware produces an ~9s (up to ~30s+ worst case, bounded by this same
  # loop's own poll interval) complete gap in multicast output — long enough
  # to lock up SMARTBOX's receiver and require a manual power-cycle to
  # recover, which is the actual production symptom this was chasing.
  # >= does allow two back-to-back entries sharing an exact boundary (one
  # ending "12:00", the next starting "12:00") to both match for that one
  # minute — resolved the same way any other priority tie already is (see
  # sort_by priority below); a strictly smaller, more benign edge case than
  # guaranteeing a real gap once every 24 hours for the single most common
  # schedule pattern there is.
  jq -r --arg now "$now_hhmm" --argjson dow "$now_dow" --arg today "$now_date" '
    .schedule
    | map(select(
        (.startTime <= $now) and (.endTime >= $now)
        and ((.daysOfWeek | length) == 0 or (.daysOfWeek[] | . == $dow) )
        and ((.validFrom == null) or (.validFrom <= $today))
        and ((.validUntil == null) or (.validUntil >= $today))
        and (.localPath | ltrimstr("/") | ("/" + .) | test("^/") )
      ))
    | sort_by(.priority)
    | reverse
    | first
    | (.localPath // "") + "\n" + (.multicastLocalPath // "")
  ' "$SCHEDULE_FILE" 2>/dev/null
}

log "SiteStream player started."

# Sweep for anything left multicasting by a previous, non-gracefully-exited
# instance of this script — MULTICAST_PID above is freshly "" and has no way
# to know about a process an earlier crashed/killed instance started. Cheap,
# one-shot, and safe to run unconditionally: if nothing's there, this is a
# no-op; if something is, it's stale by definition (this instance hasn't
# decided to start multicasting yet at this point in the script).
if pkill -f "vlc.*--sout" 2>/dev/null; then
  log "Cleaned up a multicast stream orphaned by a previous run."
fi

# Graceful shutdown on `systemctl stop`/`restart` — paired with KillMode=process
# in the systemd unit (systemd then only signals this process directly, not
# every process in its cgroup) so shutdown goes through our own stop_vlc +
# stop_multicast in order, instead of systemd blasting SIGTERM at player.sh
# and VLC simultaneously and uncoordinated. Without this, a restart (e.g.
# after a pushed self-update) killed VLC abruptly mid-Qt-event-loop, which
# produced "QObject::~QObject: Timers cannot be stopped from another thread"
# in journalctl and made restarts slow. Both calls listed explicitly here,
# not just stop_vlc alone — the two are deliberately independent now (see
# stop_vlc's own comment) so a real shutdown needs both.
trap 'log "Shutting down…"; [ -n "$LOOP_SLEEP_PID" ] && kill "$LOOP_SLEEP_PID" 2>/dev/null; stop_vlc; stop_multicast; exit 0' TERM INT

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
      if [ "$CURRENT_VIDEO_PATH" != "$SCREEN_IMAGE" ] || [ "$SCREEN_MTIME" != "$CURRENT_STATIC_IMAGE_MTIME" ] \
        || [ "${HEADLESS_MODE:-}" != "$CURRENT_HEADLESS_STATE" ] \
        || { [ "${HEADLESS_MODE:-}" != "true" ] && ! kill -0 "$VLC_PID" 2>/dev/null; }; then
        log "$SCREEN_LOG_MSG"
        start_vlc "$SCREEN_IMAGE" no-multicast
        CURRENT_STATIC_IMAGE_MTIME="$SCREEN_MTIME"
      fi
    fi
    write_status
    # Backgrounded + wait, not a plain `sleep 30`: KillMode=process means only
    # this script's PID gets SIGTERM, not children like sleep — and bash
    # defers a pending trap until the current foreground command exits. A
    # foreground sleep silently ate the TERM for up to 30s (confirmed live:
    # exceeded TimeoutStopSec=15s and forced systemd's SIGKILL fallback).
    # `wait` is interruptible mid-sleep, so the trap fires immediately.
    sleep 30 &
    LOOP_SLEEP_PID=$!
    wait "$LOOP_SLEEP_PID"
    LOOP_SLEEP_PID=""
    continue
  fi

  CURRENT_SELECTION=$(get_current_video)
  WANTED=$(printf '%s' "$CURRENT_SELECTION" | sed -n '1p')
  WANTED_MULTICAST=$(printf '%s' "$CURRENT_SELECTION" | sed -n '2p')

  # Nothing real scheduled (or scheduled but not transcoded for multicast
  # yet) with multicast actually enabled — fall back to the "No Scheduled
  # Content" placeholder (see generate-no-schedule-multicast.sh) instead of
  # leaving WANTED_MULTICAST empty. Paired with the idle branch below no
  # longer stopping multicast outright: the process now always has SOME
  # video to broadcast whenever it's enabled at all, so every transition —
  # including into and out of "nothing scheduled" — goes through the same
  # live RC swap real content changes already use, never a cold restart.
  # Confirmed live this matters: a full restart measured ~9-30s of complete
  # multicast silence, long enough to lock up SMARTBOX's receiver and
  # require a manual power-cycle to recover. Only generated/substituted when
  # actually needed — a claimed device with real content scheduled, or any
  # device with multicast off, never touches this.
  if [ -z "$WANTED_MULTICAST" ] && [ "${MULTICAST_ENABLED:-}" = "true" ]; then
    "$SITESTREAM_DIR/generate-no-schedule-multicast.sh" 2>>"$SITESTREAM_DIR/logs/vlc.log" || true
    [ -f "$SITESTREAM_DIR/no-schedule-multicast.mpg" ] && WANTED_MULTICAST="$SITESTREAM_DIR/no-schedule-multicast.mpg"
  fi

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
      if [ "$CURRENT_VIDEO_PATH" != "$IDLE_IMAGE" ] || [ "$IDLE_MTIME" != "$CURRENT_STATIC_IMAGE_MTIME" ] \
        || [ "${HEADLESS_MODE:-}" != "$CURRENT_HEADLESS_STATE" ] \
        || { [ "${HEADLESS_MODE:-}" != "true" ] && ! kill -0 "$VLC_PID" 2>/dev/null; }; then
        log "$IDLE_LOG_MSG"
        # NOT "no-multicast" — WANTED_MULTICAST already resolved to the
        # no-schedule placeholder above when multicast is enabled, so this
        # takes the normal path and start_vlc's own call to start_multicast
        # keeps the stream alive (live-swapping into the placeholder if
        # something was already broadcasting) instead of stopping it. See
        # this loop's own comment on WANTED_MULTICAST for why.
        start_vlc "$IDLE_IMAGE" "" "" "$WANTED_MULTICAST"
        CURRENT_STATIC_IMAGE_MTIME="$IDLE_MTIME"
      fi
    else
      # Couldn't generate the idle screen (missing qrencode/imagemagick?) —
      # fall back to the old blank-screen behavior rather than show nothing
      # at all while also leaving a stale video frozen on screen.
      if { [ -n "$VLC_PID" ] && kill -0 "$VLC_PID" 2>/dev/null; } || { [ -n "$MULTICAST_PID" ] && kill -0 "$MULTICAST_PID" 2>/dev/null; }; then
        log "No video scheduled — stopping player."
        stop_vlc
        stop_multicast
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
    start_vlc "$WANTED" "" "$OVERLAY_WANT" "$WANTED_MULTICAST"
  elif [ "${HEADLESS_MODE:-}" != "$CURRENT_HEADLESS_STATE" ]; then
    # Headless flag flipped since VLC was last (re)started — same video,
    # nothing else changed, so no other branch here would ever notice this
    # on its own. Confirmed live as a real gap: turning Headless on for a
    # device that was actively playing never stopped the HDMI output already
    # running, because every other trigger only reacts to the wanted video
    # changing, VLC dying, etc. — not to this flag itself. start_vlc handles
    # both directions correctly: skips the launch if now headless, or
    # actually (re)starts it if headless just got turned off.
    if [ "${HEADLESS_MODE:-}" = "true" ]; then
      log "Headless mode enabled — stopping HDMI output for: $WANTED"
    else
      log "Headless mode disabled — resuming HDMI output for: $WANTED"
    fi
    start_vlc "$WANTED" "" "$OVERLAY_WANT" "$WANTED_MULTICAST"
  elif [ "${HEADLESS_MODE:-}" != "true" ] && ! kill -0 "$VLC_PID" 2>/dev/null; then
    # VLC died unexpectedly — restart it (and multicast alongside it).
    # Excluded in headless mode: VLC_PID is deliberately never set there
    # (start_vlc skips the actual launch — see its own comment), so this
    # would otherwise read as "dead" and fire every single tick forever.
    VLC_RESTART_COUNT=$((VLC_RESTART_COUNT + 1))
    log "VLC not running, restarting: $WANTED"
    signal_urgent_health
    start_vlc "$WANTED" "" "$OVERLAY_WANT" "$WANTED_MULTICAST"
  elif [ "${HEADLESS_MODE:-}" != "true" ] && [ "$OVERLAY_WANT" != "$CURRENT_OVERLAY_STATE" ]; then
    # Same video, but connectivity state flipped since VLC was last started —
    # the marq flag is startup-only (no live control channel for it — see
    # is_disconnected's comment), so this is a deliberate, infrequent
    # (minutes-scale) restart, same tradeoff already accepted for a
    # multicast-config change below. Excluded in headless mode: the overlay
    # is purely visual (nobody's looking at HDMI), and without this exclusion
    # every connectivity flip would trigger a pointless real multicast
    # restart — a small but real viewer-visible glitch for zero benefit.
    if [ "$OVERLAY_WANT" = "disconnected" ]; then
      log "Connectivity lost — adding on-screen indicator."
    else
      log "Connectivity restored — removing on-screen indicator."
    fi
    start_vlc "$WANTED" "" "$OVERLAY_WANT" "$WANTED_MULTICAST"
  elif [ "$MULTICAST_ENABLED:$MULTICAST_ADDRESS:$MULTICAST_PORT:$MULTICAST_INTERFACE:$WANTED_MULTICAST" != "$CURRENT_MULTICAST_TARGET" ]; then
    # Was missing ":$MULTICAST_INTERFACE" on this side of the comparison —
    # CURRENT_MULTICAST_TARGET is always stored as every field
    # start_multicast itself assigns, so this could never match as long as
    # multicast was enabled at all, even with no config change and no
    # interface selected (the trailing ":" alone made the strings differ).
    # :$WANTED_MULTICAST added for the same reason — an MPEG-2 transcode
    # finishing (or a schedule swap to a different video) with everything
    # else here unchanged must still trigger a restart, since start_multicast
    # includes that same field in its own copy. Keep both sides of this
    # comparison in sync field-for-field whenever either one changes — this
    # exact drift is what silently force-restarted multicast on every single
    # tick, forever, the first time it happened.
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
    start_multicast "$WANTED_MULTICAST"
  elif [ -n "$MULTICAST_PID" ] && ! kill -0 "$MULTICAST_PID" 2>/dev/null; then
    log "Multicast output died, restarting: $WANTED"
    start_multicast "$WANTED_MULTICAST"
  elif [ "${HEADLESS_MODE:-}" = "true" ]; then
    # Steady state, headless — there's no VLC process and no HDMI display to
    # watchdog at all here (the checks below poll VLC's own HTTP interface,
    # which nothing is listening on). Multicast's own health is already
    # covered by the "process died, restart" branch above, independent of
    # this. Deliberately a no-op, not an error.
    :
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
        start_vlc "$WANTED" "" "$OVERLAY_WANT" "$WANTED_MULTICAST"
      fi
    fi
  fi

  # Also re-read schedule if sync.sh flagged an update
  if [ -f "$SITESTREAM_DIR/.schedule_updated" ]; then
    rm -f "$SITESTREAM_DIR/.schedule_updated"
    log "Schedule updated — re-evaluating."
    # Force re-evaluation next loop without waiting
  fi

  # Multicast playback-state watchdog — independent of the whole if/elif
  # chain above (checked every tick, regardless of which branch fired this
  # time around), because the failure it catches isn't tied to any one of
  # them. Confirmed live: VLC's own --loop can leave a freshly swapped-in
  # video (see swap_multicast_video) STOPPED after its first playthrough
  # finishes, instead of correctly restarting it — reproduced specifically
  # when the new video is short enough that its first natural loop boundary
  # lands close to when the swap's own add+delete RC sequence is still
  # settling, but not on later loops once things have settled (a plain RC
  # `play` resumes it instantly and it then loops correctly on its own from
  # there). The multicast process stays alive throughout (passes kill -0)
  # and the video is still correctly loaded, so nothing else here notices —
  # the stream just goes silent until something explicitly tells VLC to play
  # again. Cheap to check every tick: one RC round-trip, and `play` against
  # an already-playing stream is a harmless no-op.
  if [ -n "$MULTICAST_PID" ] && kill -0 "$MULTICAST_PID" 2>/dev/null; then
    MULTICAST_STATUS=$(send_multicast_rc "status")
    if ! printf '%s' "$MULTICAST_STATUS" | grep -q "state playing"; then
      log "WARN: multicast output not playing (state check) — resuming."
      send_multicast_rc "play" >/dev/null
    fi
  fi

  write_status

  # See the other `sleep 30 & wait $!` above for why this can't be a plain
  # sleep — same shutdown-hang risk on the service's main steady-state loop.
  sleep 30 &
  LOOP_SLEEP_PID=$!
  wait "$LOOP_SLEEP_PID"
  LOOP_SLEEP_PID=""
done
