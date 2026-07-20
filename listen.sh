#!/bin/bash
# SiteStream Pi Client — Realtime Push Listener
#
# Runs as a systemd service (Restart=always). Holds a long-lived
# Server-Sent-Events connection open to the API so schedule/firmware/reboot/
# zone changes reach this device within seconds, instead of waiting for
# sync.sh's next cron tick (up to the zone's configured interval, as slow as
# an hour). Purely a latency shortcut layered on top of that existing polling
# model, never a replacement for it — sync.sh keeps running on its normal
# cadence regardless, so any gap here (not yet provisioned, network down, API
# unreachable, this service itself crash-looping) just falls back to normal
# poll latency, never silence. That's also why this script never uses `set
# -e` or exits permanently on an error — a persistent daemon that gives up
# after one bad connection defeats the entire point.
#
# Also watches for player.sh's urgent-health trigger file and, on seeing it,
# triggers sync.sh immediately too — so something like a VLC stall/restart
# gets reported upstream within seconds instead of waiting up to the zone's
# full sync interval. player.sh itself has no network access by design (see
# player.sh), so this is the mechanism that turns "something bad just
# happened locally" into an immediate report.

# Deliberately no `set -e` — see header above.

SITESTREAM_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SITESTREAM_DIR/config.env"
HEALTH_URGENT_FILE="$SITESTREAM_DIR/.health_urgent"
log() { echo "[LISTEN $(date '+%H:%M:%S')] $1"; }

# Runs the pipeline's tail (the `while read` below) in the current shell
# instead of a subshell — without this, BACKOFF resets inside that loop
# would be invisible outside it (classic bash pipeline-subshell gotcha).
shopt -s lastpipe

# sync.sh has its own flock guard (.sync.lock), so firing this from more than
# one place (cron ticks, a server push, an urgent local health signal) is
# always safe — a call that lands while another is already running just
# becomes a no-op "skip, already running" instead of a competing run.
trigger_sync() {
  local reason="$1"
  log "Triggering immediate sync ($reason)…"
  "$SITESTREAM_DIR/sync.sh" >> "$SITESTREAM_DIR/logs/sync.log" 2>&1 &
}

# Runs alongside the SSE read loop below, polling for player.sh's urgent-
# health breadcrumb every 5s. Backgrounded because the SSE loop's `read` is
# blocking — this is the simplest way to watch both signals without a second
# full daemon/service.
watch_urgent_health() {
  while true; do
    if [ -f "$HEALTH_URGENT_FILE" ]; then
      rm -f "$HEALTH_URGENT_FILE"
      trigger_sync "urgent health signal from player.sh"
    fi
    sleep 5
  done
}
watch_urgent_health &
WATCHER_PID=$!
trap 'log "Shutting down…"; kill "$WATCHER_PID" 2>/dev/null; pkill -f "devices/me/events" 2>/dev/null; exit 0' TERM INT

BACKOFF=2
MAX_BACKOFF=60

while true; do
  [ -f "$CONFIG" ] && source "$CONFIG"
  API_URL="${API_URL:-https://api.sitestream.app}"

  if [ -z "$DEVICE_TOKEN" ]; then
    log "Not yet provisioned — waiting for sync.sh to claim this device…"
    sleep 15
    continue
  fi

  log "Connecting to $API_URL/api/devices/me/events…"

  # -N: disable curl's output buffering — SSE needs each line delivered as it
  # arrives, not batched once an internal buffer fills.
  # --keepalive-time: TCP-level keepalive, so a silently-dropped connection
  # (no FIN — common on some NAT/firewall setups) gets noticed at the socket
  # level too, not solely relying on the app-level read timeout below.
  curl -N -s --keepalive-time 30 \
    -H "Authorization: Bearer $DEVICE_TOKEN" \
    -H "Accept: text/event-stream" \
    "$API_URL/api/devices/me/events" | \
  while IFS= read -r -t 90 line; do
    case "$line" in
      "event: wake"*)
        # The data: payload arrives in the same flush right behind the event:
        # line (see writeEvent in the API's devicePush.ts) — consume it here
        # so it isn't misread as an unrelated line on the next iteration.
        read -r -t 5 data_line
        log "Push received: $data_line"
        trigger_sync "server push"
        BACKOFF=2
        ;;
      ": connected"*)
        log "Connected."
        BACKOFF=2
        ;;
      ": keepalive"*)
        BACKOFF=2
        ;;
    esac
  done
  # A `read -t` timeout (no line for 90s — well beyond the server's 20s
  # keepalive cadence) drops out of the loop above with curl potentially
  # still running; make sure it's actually gone before reconnecting.
  pkill -f "devices/me/events" 2>/dev/null || true

  log "Disconnected — reconnecting in ${BACKOFF}s…"
  sleep "$BACKOFF"
  BACKOFF=$(( BACKOFF * 2 > MAX_BACKOFF ? MAX_BACKOFF : BACKOFF * 2 ))
done
