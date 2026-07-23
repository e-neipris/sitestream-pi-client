#!/bin/bash
# SiteStream Pi Client — Sync Script
# Runs on a cron schedule (default every 15 min, admin-configurable per zone —
# overlap-safe regardless of interval, see the flock guard below).
#
# What it does:
#   0. If not yet provisioned (no DEVICE_TOKEN), checks in with the API using
#      this Pi's hardware serial and either gets a token back (continues below)
#      or logs that it's still waiting to be claimed and exits until next run.
#   1. Fetches the manifest (schedule + video list) from the API — on failure,
#      falls back to a fast 1-minute retry cadence until it reconnects (see
#      apply_sync_interval), rather than staying silent for up to a full hour
#      at the slowest configured interval
#   1c. Reboots if an admin requested it (acknowledges first, then reboots)
#   1c-bis. Factory-resets if an admin requested it (acknowledges first, then
#      runs factory-reset.sh — see that script for what it actually clears)
#   1d. Adjusts its own cron schedule if the zone's configured interval changed
#   2. Downloads any videos not yet cached locally (compares ETags)
#   3. Deletes videos that are no longer in the schedule (frees SD card space)
#   4. Writes schedule.json (in this script's own directory) for the player to read
#   5. Reports back to the API (heartbeat) with confirmed manifest hash + health
#      telemetry (player.sh's live status, CPU temp, disk, uptime)
#   6. Signals player.sh to re-read the schedule
#   7. Applies a pending pi-client update, if the manifest targets a release
#      different from what's installed — copies the whole release through and
#      re-runs install.sh unattended (as root, via a scoped sudo grant) to
#      apply anything system-level the release needs, not just script files

set -e

SITESTREAM_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SITESTREAM_DIR/config.env"
[ -f "$CONFIG" ] && source "$CONFIG"

API_URL="${API_URL:-https://api.sitestream.app}"
# Needed so self-update can re-invoke install.sh unattended with the right
# value (see step 7 below) — same fallback pattern as API_URL above.
APP_URL="${APP_URL:-https://app.sitestream.app}"
VIDEO_DIR="${VIDEO_DIR:-$SITESTREAM_DIR/videos}"
SCHEDULE_FILE="$SITESTREAM_DIR/schedule.json"
MANIFEST_HASH_FILE="$SITESTREAM_DIR/.manifest_hash"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

# Translates a curl exit code into a human-readable reason, since -f/-s alone
# give no indication of *why* a transfer failed (timeout vs reset vs HTTP error).
curl_exit_reason() {
  case "$1" in
    6) echo "couldn't resolve host (DNS)" ;;
    7) echo "couldn't connect to host" ;;
    18) echo "partial file — transfer closed early" ;;
    22) echo "HTTP error response (expired presigned URL, 403/404/5xx?)" ;;
    23) echo "local write error (disk full?)" ;;
    28) echo "timed out (exceeded --max-time)" ;;
    35) echo "SSL/TLS connect error" ;;
    52) echo "server returned empty response" ;;
    55) echo "failed sending network data" ;;
    56) echo "connection reset while receiving data (dropped Wi-Fi?)" ;;
    *) echo "unrecognized — see curl.se/libcurl/c/libcurl-errors.html" ;;
  esac
}

# Downloads $1 (URL) to $2 (dest path, resumable via -C -), retrying up to 5
# times with rich failure logging labeled with $3. Sets DOWNLOAD_OK rather
# than returning a value — used by both the per-video download loop and the
# pi-client self-update tarball download below.
download_with_retries() {
  local url="$1" dest="$2" label="$3"
  DOWNLOAD_OK=false
  for attempt in 1 2 3 4 5; do
    local curl_exit=0
    local curl_log
    # -C - resumes from the partial file already on disk — but curl's own
    # --retry does NOT reliably re-apply that resume point between its
    # internal retry attempts within a single invocation (long-standing curl
    # quirk), so a dropped connection mid-transfer can reset to byte 0 instead
    # of resuming. Retrying as separate curl invocations from bash instead
    # avoids that — each fresh invocation correctly picks up the current
    # on-disk size.
    curl_log=$(curl -sS -f \
      -o "$dest" \
      -C - \
      --max-time 1800 \
      -w 'http_code=%{http_code} bytes_this_attempt=%{size_download} elapsed=%{time_total}s avg_speed=%{speed_download}B/s' \
      "$url" 2>&1) || curl_exit=$?

    if [ "$curl_exit" -eq 0 ]; then
      DOWNLOAD_OK=true
      return
    fi

    local on_disk_bytes
    on_disk_bytes=$(stat -c%s "$dest" 2>/dev/null || echo 0)
    log "Download attempt $attempt for $label failed (curl exit $curl_exit: $(curl_exit_reason "$curl_exit")) — on-disk so far: ${on_disk_bytes} bytes. ${curl_log//$'\n'/ } — retrying in 5s…"
    sleep 5
  done
}

SYNC_INTERVAL_FILE="$SITESTREAM_DIR/.sync_interval"

# Rewrites this Pi's own crontab to run sync.sh every $1 minutes (no-op if
# that's already the active interval). Uses $PI_USER's own crontab (see
# install.sh), so this needs no sudo/root — a user's own crontab entries can
# only ever run as that user.
#
# Used two ways: (1) the zone's configured interval on a normal successful
# cycle, and (2) forced to 1 minute whenever the manifest fetch fails
# outright, so a device on e.g. a 1-hour interval doesn't stay silent for up
# to an hour after a transient outage before even trying again. Both share
# this one function/state file on purpose — the next successful fetch just
# reports the zone's real interval again and case (1) naturally restores it,
# so recovery needs no separate code path.
apply_sync_interval() {
  local minutes="$1"
  local last_interval
  last_interval=$(cat "$SYNC_INTERVAL_FILE" 2>/dev/null || echo "")
  [ "$minutes" = "$last_interval" ] && return

  local cron_schedule=""
  case "$minutes" in
    1)  cron_schedule="* * * * *" ;;
    5)  cron_schedule="*/5 * * * *" ;;
    15) cron_schedule="*/15 * * * *" ;;
    30) cron_schedule="*/30 * * * *" ;;
    60) cron_schedule="0 * * * *" ;;  # top of every hour — */60 isn't valid in the minute field
    *)  log "WARN: unrecognized sync interval '$minutes' — leaving cron schedule unchanged."; return ;;
  esac

  local new_cron_line="$cron_schedule $SITESTREAM_DIR/sync.sh >> $SITESTREAM_DIR/logs/sync.log 2>&1"
  if (crontab -l 2>/dev/null | grep -v "sync.sh"; echo "$new_cron_line") | crontab -; then
    echo "$minutes" > "$SYNC_INTERVAL_FILE"
    log "Sync interval changed to every ${minutes} min — cron schedule updated (takes effect next tick)."
  else
    log "WARN: failed to update crontab for new sync interval — will retry next cycle."
  fi
}

# listen.sh sets SYNC_TRIGGER=push when it invokes this script in response to
# a server-sent "wake up now" event — see trigger_sync() in listen.sh. That's
# a specific, one-time "something changed, act now" request with no
# automatic follow-up if it gets dropped, unlike a cron tick (where a missed
# run doesn't matter — the next one is only 1-15 min away regardless). The
# two invocation modes need different lock and jitter handling below because
# of that difference.
exec 200>"$SITESTREAM_DIR/.sync.lock"
if [ "$SYNC_TRIGGER" = "push" ]; then
  # Block and wait for any in-flight run to finish rather than skipping —
  # dropping a push-triggered sync silently defeats the entire point of
  # having it (the whole reason it exists is to avoid waiting up to the
  # zone's full sync interval for a change to take effect).
  flock 200
else
  # At a fast sync interval (as low as 1 minute), a large in-progress download
  # can easily still be running when the next tick fires. flock -n on an fd
  # tied to a lock file makes a second invocation exit immediately instead of
  # starting a competing download into the same temp file — fine here since
  # the next tick will just try again shortly.
  if ! flock -n 200; then
    log "Previous sync.sh still running — skipping this run."
    exit 0
  fi

  # Jitter: every device on the same zone typically shares the same cron
  # cadence, and cron fires all of them at the same wall-clock second — so
  # without this they'd all hit the API in the same instant, every cycle, not
  # just during an outage-recovery burst. A small random delay before any
  # network call spreads that out. Only applies to cron-triggered runs — a
  # push-triggered run's entire purpose is to react immediately, so jittering
  # it would silently reintroduce the exact latency this feature exists to
  # remove (confirmed: a real push-triggered run measured ~38s from trigger
  # to confirmed heartbeat, almost entirely this sleep).
  sleep $((RANDOM % 46))
fi

# ── 0. Zero-touch provisioning ─────────────────────────────────────────────────
# No token baked in at install time — the Pi identifies itself by hardware
# serial and waits for a Tenant Admin (or Super Admin) to claim it in the
# admin UI. Nothing to copy onto the device by hand.
if [ -z "$DEVICE_TOKEN" ]; then
  SERIAL=$(awk -F': ' '/^Serial/ {print $2}' /proc/cpuinfo | tr -d ' \n')

  if [ -z "$SERIAL" ]; then
    log "ERROR: could not read hardware serial from /proc/cpuinfo. Cannot provision."
    exit 0
  fi

  log "Not yet provisioned (serial: $SERIAL). Checking claim status…"

  CHECKIN_RESPONSE=$(curl -sf \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{\"serialNumber\":\"$SERIAL\"}" \
    --max-time 15 \
    "$API_URL/api/devices/checkin") || {
    log "Checkin failed (API unreachable). Will retry next run."
    exit 0
  }

  CLAIMED=$(echo "$CHECKIN_RESPONSE" | jq -r '.claimed')

  if [ "$CLAIMED" != "true" ]; then
    log "Still waiting to be claimed. Serial: $SERIAL"
    exit 0
  fi

  DEVICE_TOKEN=$(echo "$CHECKIN_RESPONSE" | jq -r '.token')
  log "Claimed! Saving device token and continuing with this sync."

  # Preserve any other config values already in the file; just set DEVICE_TOKEN.
  grep -v '^DEVICE_TOKEN=' "$CONFIG" 2>/dev/null > "$CONFIG.tmp" || true
  echo "DEVICE_TOKEN=$DEVICE_TOKEN" >> "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  chmod 600 "$CONFIG"
fi

# ── 1. Fetch manifest ─────────────────────────────────────────────────────────
log "Fetching manifest from $API_URL/api/manifest"

MANIFEST=$(curl -sf \
  -H "Authorization: Bearer $DEVICE_TOKEN" \
  -H "Accept: application/json" \
  --max-time 30 \
  "$API_URL/api/manifest") || {
  log "ERROR: Failed to fetch manifest. Retaining existing schedule."
  # Fall back to a fast retry cadence until we successfully reach the API
  # again — otherwise a device on a slow interval (up to 1 hour) could stay
  # unreachable for that whole window after a transient failure before even
  # trying again. The next successful fetch reports the zone's real interval
  # and apply_sync_interval restores it automatically — no separate
  # "recovery" logic needed.
  apply_sync_interval 1
  exit 0
}

MANIFEST_VERSION=$(echo "$MANIFEST" | jq -r '.manifestVersion')
LAST_CONFIRMED=$(cat "$MANIFEST_HASH_FILE" 2>/dev/null || echo "")

log "Manifest version: $MANIFEST_VERSION"

# ── 1b. Persist multicast output config for player.sh to pick up ─────────────
MULTICAST_ENABLED=$(echo "$MANIFEST" | jq -r '.multicastEnabled // false')
MULTICAST_ADDRESS=$(echo "$MANIFEST" | jq -r '.multicastAddress // empty')
MULTICAST_PORT=$(echo "$MANIFEST" | jq -r '.multicastPort // empty')
# Which NIC actually carries the multicast stream (e.g. "eth0") — only set
# when this device also needs a different interface (e.g. "wlan0") for its
# own SaaS traffic. Empty means "let VLC/the OS pick," same as before this
# existed — see player.sh's start_multicast for where this is consumed.
MULTICAST_INTERFACE=$(echo "$MANIFEST" | jq -r '.multicastInterface // empty')

grep -vE '^(MULTICAST_ENABLED|MULTICAST_ADDRESS|MULTICAST_PORT|MULTICAST_INTERFACE)=' "$CONFIG" 2>/dev/null > "$CONFIG.tmp" || true
{
  echo "MULTICAST_ENABLED=$MULTICAST_ENABLED"
  echo "MULTICAST_ADDRESS=$MULTICAST_ADDRESS"
  echo "MULTICAST_PORT=$MULTICAST_PORT"
  echo "MULTICAST_INTERFACE=$MULTICAST_INTERFACE"
} >> "$CONFIG.tmp"
mv "$CONFIG.tmp" "$CONFIG"
chmod 600 "$CONFIG"

# ── 1b2. Apply cloud-pushed system config (timezone, hostname, Wi-Fi) ────────
# Unlike multicast above (which player.sh reads and acts on itself), nothing
# else in this codebase applies these — sync.sh has to actually call the
# same sudo-granted commands the standalone portal's System tab uses (see
# install.sh's sudoers.d/sitestream). Applied in this specific order:
# timezone/hostname first (harmless either way), Wi-Fi LAST — joining a
# different network can drop THIS device's own connectivity immediately,
# so everything else useful in this run happens before that risk, same
# "riskiest step last" reasoning as the self-update section further down.
NEW_TIMEZONE=$(echo "$MANIFEST" | jq -r '.timezone // empty')
NEW_HOSTNAME=$(echo "$MANIFEST" | jq -r '.hostname // empty')
NEW_WIFI_SSID=$(echo "$MANIFEST" | jq -r '.wifiSsid // empty')
NEW_WIFI_PASSWORD=$(echo "$MANIFEST" | jq -r '.wifiPassword // empty')

grep -vE '^(WIFI_SSID|WIFI_PASSWORD)=' "$CONFIG" 2>/dev/null > "$CONFIG.tmp" || true
{
  echo "WIFI_SSID=$NEW_WIFI_SSID"
  echo "WIFI_PASSWORD=$NEW_WIFI_PASSWORD"
} >> "$CONFIG.tmp"
mv "$CONFIG.tmp" "$CONFIG"
chmod 600 "$CONFIG"

if [ -n "$NEW_TIMEZONE" ]; then
  CURRENT_TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "")
  if [ "$NEW_TIMEZONE" != "$CURRENT_TIMEZONE" ]; then
    log "Applying timezone from cloud config: $NEW_TIMEZONE"
    sudo -n timedatectl set-timezone "$NEW_TIMEZONE" 2>>"$SITESTREAM_DIR/logs/sync.log" || log "WARN: could not set timezone to $NEW_TIMEZONE"
  fi
fi

if [ -n "$NEW_HOSTNAME" ]; then
  CURRENT_HOSTNAME=$(hostname)
  if [ "$NEW_HOSTNAME" != "$CURRENT_HOSTNAME" ]; then
    log "Applying hostname from cloud config: $NEW_HOSTNAME"
    sudo -n hostnamectl set-hostname "$NEW_HOSTNAME" 2>>"$SITESTREAM_DIR/logs/sync.log" || log "WARN: could not set hostname to $NEW_HOSTNAME"
  fi
fi

# Tracked via a cache file, not a live "what network are we actually on"
# check — querying that reliably means parsing `iw`/`nmcli` output keyed to
# a specific interface name, the exact fragility already hit (and fixed) in
# the portal's own Wi-Fi scan. Same idea as .sync_interval below: only act
# when the CLOUD value actually changes from what was last applied.
WIFI_SSID_CACHE_FILE="$SITESTREAM_DIR/.wifi_ssid_applied"
LAST_APPLIED_SSID=$(cat "$WIFI_SSID_CACHE_FILE" 2>/dev/null || echo "")
if [ -n "$NEW_WIFI_SSID" ] && [ "$NEW_WIFI_SSID" != "$LAST_APPLIED_SSID" ]; then
  log "Applying Wi-Fi credentials from cloud config: joining '$NEW_WIFI_SSID'"
  if sudo -n raspi-config nonint do_wifi_ssid_passphrase "$NEW_WIFI_SSID" "$NEW_WIFI_PASSWORD" 2>>"$SITESTREAM_DIR/logs/sync.log"; then
    echo "$NEW_WIFI_SSID" > "$WIFI_SSID_CACHE_FILE"
  else
    log "WARN: could not join Wi-Fi network $NEW_WIFI_SSID"
  fi
fi

# ── 1c. Handle a pending reboot request ───────────────────────────────────────
# One-shot admin command, not a persistent target state like the update
# mechanism above. Checked early (before video downloads) so an explicit
# "reboot this device" click isn't sitting behind a slow transfer. Only
# actually reboots once the server has confirmed the ack — if we rebooted
# unconditionally and the ack request just happened to fail (flaky network,
# which is plausible on exactly the kind of device someone's trying to
# recover), the flag would stay set server-side and next boot would see
# reboot:true again, straight into a reboot loop. Skipping and retrying next
# cycle is the safe failure mode.
REBOOT_REQUESTED=$(echo "$MANIFEST" | jq -r '.reboot // false')
if [ "$REBOOT_REQUESTED" = "true" ]; then
  DEVICE_ID=$(echo "$MANIFEST" | jq -r '.deviceId')
  log "Reboot requested via admin panel — acknowledging…"
  if curl -sf -X POST -H "Authorization: Bearer $DEVICE_TOKEN" --max-time 15 \
       "$API_URL/api/devices/$DEVICE_ID/reboot/ack" > /dev/null; then
    log "Acknowledged. Rebooting now."
    sudo systemctl reboot
    exit 0
  else
    log "WARN: could not reach API to acknowledge reboot — skipping this cycle, will retry."
  fi
fi

# ── 1c-bis. Handle a pending factory-reset request ────────────────────────────
# Same one-shot ack-before-acting reasoning as the reboot handling above —
# only acts once the server has confirmed the ack, so a flaky-network ack
# failure means retrying next cycle instead of factory-resetting again on
# every subsequent one. factory-reset.sh itself restarts both services (and,
# thanks to KillMode=process on sitestream-listen.service, safely survives
# restarting its own parent if this particular run was itself push-triggered
# — see install.sh) — so this process's own remaining steps below would
# otherwise run against a config.env/state that's already been wiped out from
# under them. Exiting right after is deliberate, not just tidy.
FACTORY_RESET_REQUESTED=$(echo "$MANIFEST" | jq -r '.factoryReset // false')
if [ "$FACTORY_RESET_REQUESTED" = "true" ]; then
  DEVICE_ID=$(echo "$MANIFEST" | jq -r '.deviceId')
  log "Factory reset requested via admin panel — acknowledging…"
  if curl -sf -X POST -H "Authorization: Bearer $DEVICE_TOKEN" --max-time 15 \
       "$API_URL/api/devices/$DEVICE_ID/factory-reset/ack" > /dev/null; then
    log "Acknowledged. Running factory reset now."
    "$SITESTREAM_DIR/factory-reset.sh" --yes
    exit 0
  else
    log "WARN: could not reach API to acknowledge factory reset — skipping this cycle, will retry."
  fi
fi

# ── 1d. Adjust the cron schedule if the zone's configured interval changed ───
# Set in the zone's Configuration tab (default 15 min; 1 min is dev/testing
# only — see SYNC_INTERVAL_MINUTES in packages/api/src/routes/zones.ts).
# Doesn't exit afterward like the update/reboot handling above — the
# schedule change only affects future cron ticks, so this cycle's normal
# work continues as usual. Also doubles as recovery from the fast 1-minute
# retry cadence apply_sync_interval falls back to on a failed fetch — a
# successful fetch reaching here means we're connected again, so whatever
# the zone actually wants takes over immediately.
apply_sync_interval "$(echo "$MANIFEST" | jq -r '.syncIntervalMinutes // 15')"

# ── 2. Download missing / updated videos ──────────────────────────────────────
NEEDED_IDS=()

while IFS= read -r entry; do
  VIDEO_ID=$(echo "$entry" | jq -r '.videoId')
  ETAG=$(echo "$entry" | jq -r '.etag')
  FILENAME=$(echo "$entry" | jq -r '.filename')
  DOWNLOAD_URL=$(echo "$entry" | jq -r '.downloadUrl')
  LOCAL_PATH="$VIDEO_DIR/$VIDEO_ID.mp4"

  NEEDED_IDS+=("$VIDEO_ID")

  # Compare local ETag file to expected ETag
  LOCAL_ETAG_FILE="$VIDEO_DIR/${VIDEO_ID}.etag"
  LOCAL_ETAG=$(cat "$LOCAL_ETAG_FILE" 2>/dev/null || echo "")

  if [ "$LOCAL_ETAG" = "$ETAG" ] && [ -f "$LOCAL_PATH" ]; then
    log "Video $VIDEO_ID ($FILENAME) already current."
  else
    log "Downloading $FILENAME ($VIDEO_ID)…"
    TEMP_PATH="$LOCAL_PATH.tmp"
    TEMP_ETAG_FILE="$TEMP_PATH.etag"

    # Discard any partial download left over from a different version of this
    # video — resuming stale bytes onto a new ETag's content would corrupt it.
    if [ -f "$TEMP_PATH" ] && [ "$(cat "$TEMP_ETAG_FILE" 2>/dev/null)" != "$ETAG" ]; then
      rm -f "$TEMP_PATH" "$TEMP_ETAG_FILE"
    fi
    echo "$ETAG" > "$TEMP_ETAG_FILE"

    download_with_retries "$DOWNLOAD_URL" "$TEMP_PATH" "$FILENAME"

    if [ "$DOWNLOAD_OK" = true ]; then
      mv "$TEMP_PATH" "$LOCAL_PATH"
      echo "$ETAG" > "$LOCAL_ETAG_FILE"
      rm -f "$TEMP_ETAG_FILE"
      log "Downloaded $FILENAME successfully."
    else
      log "ERROR: Failed to download $FILENAME after retries. Keeping partial data to resume next run."
    fi
  fi
done < <(echo "$MANIFEST" | jq -c '.schedule[]')
# Process substitution (< <(...)), not a here-string (<<< "$(...)") — a
# here-string always appends a trailing newline to whatever it's given, so
# for a zone with zero schedule entries (jq's .[] produces truly zero bytes
# of output), the old form still fed `read` one lone newline: exactly one
# phantom iteration with every field empty, producing "Downloading  ()…"
# and a doomed download attempt against an empty URL — confirmed live
# against a fresh zone with no schedule at all. Process substitution
# connects the loop directly to the command's real output stream with no
# such injection, so zero bytes in means zero iterations, correctly.

# ── 3. Remove videos no longer in schedule ────────────────────────────────────
for f in "$VIDEO_DIR"/*.mp4; do
  [ -f "$f" ] || continue
  FILE_ID=$(basename "$f" .mp4)
  STILL_NEEDED=false
  for id in "${NEEDED_IDS[@]}"; do
    [ "$id" = "$FILE_ID" ] && STILL_NEEDED=true && break
  done
  if [ "$STILL_NEEDED" = false ]; then
    log "Removing obsolete video $FILE_ID"
    rm -f "$f" "$VIDEO_DIR/${FILE_ID}.etag"
  fi
done

# ── 4. Write schedule.json for the player ─────────────────────────────────────
echo "$MANIFEST" | jq --arg videoDir "$VIDEO_DIR" '{
  manifestVersion: .manifestVersion,
  generatedAt: .generatedAt,
  schedule: [.schedule[] | {
    videoId: .videoId,
    filename: .filename,
    etag: .etag,
    startTime: .startTime,
    endTime: .endTime,
    daysOfWeek: .daysOfWeek,
    validFrom: .validFrom,
    validUntil: .validUntil,
    priority: .priority,
    label: .label,
    localPath: ($videoDir + "/" + .videoId + ".mp4")
  }]
}' > "$SCHEDULE_FILE"

log "Schedule written to $SCHEDULE_FILE"

# ── 5. Heartbeat — report confirmed manifest hash + health telemetry ──────────
IP_ADDRESS=$(hostname -I | awk '{print $1}')
INSTALLED_VERSION_FILE="$SITESTREAM_DIR/.installed_version"
INSTALLED_VERSION=$(cat "$INSTALLED_VERSION_FILE" 2>/dev/null || echo "")

# System vitals — cheap local reads, safe to gather every cycle. vcgencmd is
# Pi-specific and absent off-device (dev/test), hence the fallback to empty.
CPU_TEMP=$(vcgencmd measure_temp 2>/dev/null | grep -o '[0-9.]*' | head -1)
DISK_FREE_PCT=$(df -P "$SITESTREAM_DIR" 2>/dev/null | awk 'NR==2 { gsub("%","",$5); printf "%d", 100-$5 }')
DISK_FREE_MB=$(df -Pm "$SITESTREAM_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
UPTIME_SECONDS=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)

# CPU utilization — 1-min load average / core count, as a percent. Not a true
# instantaneous sample (that needs two /proc/stat reads with a delay, which
# would slow down a script that now runs every minute via cron) but a
# standard, already-smoothed proxy that costs nothing extra to gather.
CPU_CORES=$(nproc 2>/dev/null || echo 1)
LOAD_1MIN=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
CPU_UTIL_PCT=""
if [ -n "$LOAD_1MIN" ] && [ "$CPU_CORES" -gt 0 ] 2>/dev/null; then
  # "load" collides with a gawk builtin (dynamic extension loading) — has to
  # be named something else or awk fails outright.
  CPU_UTIL_PCT=$(awk -v ld="$LOAD_1MIN" -v cores="$CPU_CORES" 'BEGIN { pct = (ld/cores)*100; if (pct > 999) pct = 999; printf "%.0f", pct }')
fi

MEM_UTIL_PCT=$(free 2>/dev/null | awk '/^Mem:/ { if ($2>0) printf "%.0f", ($3/$2)*100 }')

# Network — whichever interface currently holds the default route, and (only
# if it's Wi-Fi) signal quality. Directly relevant given Wi-Fi power-save was
# the root cause of dropped downloads found earlier — a weak/degrading
# signal is real field-troubleshooting signal, not just a nice-to-have.
NET_INTERFACE=$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')
WIFI_SIGNAL_PCT=""
if [ -n "$NET_INTERFACE" ] && [ -f /proc/net/wireless ] && grep -q "^ *${NET_INTERFACE}:" /proc/net/wireless 2>/dev/null; then
  # Quality field (3rd column after the interface name) is out of 70 on the
  # standard Linux wireless-extensions scale.
  RAW_QUALITY=$(awk -v iface="${NET_INTERFACE}:" '$1 == iface { gsub(/\./, "", $3); print $3 }' /proc/net/wireless)
  if [ -n "$RAW_QUALITY" ]; then
    WIFI_SIGNAL_PCT=$(awk -v q="$RAW_QUALITY" 'BEGIN { pct = (q/70)*100; if (pct > 100) pct = 100; if (pct < 0) pct = 0; printf "%.0f", pct }')
  fi
fi

# player.sh writes its live state here every ~30s (see write_status in
# player.sh) — player.sh has no network access of its own by design, so
# sync.sh is what actually reports it upstream.
CURRENT_VIDEO=""
LAST_VIDEO_ERROR=""
VLC_RESTART_COUNT=""
if [ -f "$SITESTREAM_DIR/status.json" ]; then
  CURRENT_VIDEO=$(jq -r '.currentVideo // empty' "$SITESTREAM_DIR/status.json" 2>/dev/null)
  LAST_VIDEO_ERROR=$(jq -r '.lastVideoError // empty' "$SITESTREAM_DIR/status.json" 2>/dev/null)
  VLC_RESTART_COUNT=$(jq -r '.vlcRestartCount // empty' "$SITESTREAM_DIR/status.json" 2>/dev/null)
fi

# Built via jq rather than hand-interpolated into a JSON string — unlike the
# hash/IP this replaced, lastVideoError is free-text pulled from VLC's own
# log output and could contain quotes/backslashes that would otherwise
# produce malformed (or truncated) JSON.
HEARTBEAT_PAYLOAD=$(jq -n \
  --arg confirmedManifestHash "$MANIFEST_VERSION" \
  --arg ipAddress "$IP_ADDRESS" \
  --arg installedVersion "$INSTALLED_VERSION" \
  --arg currentVideoFilename "$CURRENT_VIDEO" \
  --arg lastVideoError "$LAST_VIDEO_ERROR" \
  --arg vlcRestartCount "$VLC_RESTART_COUNT" \
  --arg cpuTempC "$CPU_TEMP" \
  --arg cpuUtilizationPercent "$CPU_UTIL_PCT" \
  --arg memoryUtilizationPercent "$MEM_UTIL_PCT" \
  --arg diskFreePercent "$DISK_FREE_PCT" \
  --arg diskFreeMb "$DISK_FREE_MB" \
  --arg networkInterface "$NET_INTERFACE" \
  --arg wifiSignalPercent "$WIFI_SIGNAL_PCT" \
  --arg uptimeSeconds "$UPTIME_SECONDS" \
  '{confirmedManifestHash: $confirmedManifestHash, ipAddress: $ipAddress}
  + (if $installedVersion == "" then {} else {installedVersion: $installedVersion} end)
  + (if $currentVideoFilename == "" then {} else {currentVideoFilename: $currentVideoFilename} end)
  + (if $lastVideoError == "" then {} else {lastVideoError: $lastVideoError} end)
  + (if $vlcRestartCount == "" then {} else {vlcRestartCount: ($vlcRestartCount | tonumber)} end)
  + (if $cpuTempC == "" then {} else {cpuTempC: ($cpuTempC | tonumber)} end)
  + (if $cpuUtilizationPercent == "" then {} else {cpuUtilizationPercent: ($cpuUtilizationPercent | tonumber)} end)
  + (if $memoryUtilizationPercent == "" then {} else {memoryUtilizationPercent: ($memoryUtilizationPercent | tonumber)} end)
  + (if $diskFreePercent == "" then {} else {diskFreePercent: ($diskFreePercent | tonumber)} end)
  + (if $diskFreeMb == "" then {} else {diskFreeMb: ($diskFreeMb | tonumber)} end)
  + (if $networkInterface == "" then {} else {networkInterface: $networkInterface} end)
  + (if $wifiSignalPercent == "" then {} else {wifiSignalPercent: ($wifiSignalPercent | tonumber)} end)
  + (if $uptimeSeconds == "" then {} else {uptimeSeconds: ($uptimeSeconds | tonumber)} end)
  ')

curl -sf \
  -X POST \
  -H "Authorization: Bearer $DEVICE_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$HEARTBEAT_PAYLOAD" \
  --max-time 15 \
  "$API_URL/api/devices/$(echo "$MANIFEST" | jq -r '.deviceId')/heartbeat" \
  > /dev/null || log "WARN: Heartbeat failed (non-fatal)"

echo "$MANIFEST_VERSION" > "$MANIFEST_HASH_FILE"
log "Sync complete. Manifest: $MANIFEST_VERSION"

# ── 6. Signal the player to re-read the schedule ──────────────────────────────
touch "$SITESTREAM_DIR/.schedule_updated"

# ── 7. Self-update — apply a pinned pi-client release, if targeted ────────────
# Pis in the field (300+ sites) can't be reached by hand, so this is the only
# update path. Runs last so a normal cycle's core job (schedule/video sync)
# always completes first, even on the one cycle that also finds an update.
#
# Copies the WHOLE extracted tarball into place (not a fixed list of named
# files) and then re-runs install.sh itself, unattended, as root — install.sh
# already handles everything a release might need (new apt packages, new/
# changed systemd units, new directories like pi-portal/) and is already
# proven idempotent/safe to re-run, so this is genuinely "do what a human
# re-running it by hand would do," not a second, narrower update mechanism
# to keep in sync with install.sh by hand. Needs the install.sh sudoers
# grant (see install.sh) since sync.sh itself runs unprivileged.
UPDATE_VERSION=$(echo "$MANIFEST" | jq -r '.update.version // empty')
UPDATE_URL=$(echo "$MANIFEST" | jq -r '.update.downloadUrl // empty')

if [ -n "$UPDATE_VERSION" ] && [ "$UPDATE_VERSION" != "$INSTALLED_VERSION" ]; then
  log "Update available: '${INSTALLED_VERSION:-none}' -> '$UPDATE_VERSION'. Downloading…"
  UPDATE_TMP_DIR=$(mktemp -d)
  UPDATE_TARBALL="$UPDATE_TMP_DIR/release.tar.gz"

  download_with_retries "$UPDATE_URL" "$UPDATE_TARBALL" "pi-client update $UPDATE_VERSION"

  if [ "$DOWNLOAD_OK" = true ] && tar -xzf "$UPDATE_TARBALL" -C "$UPDATE_TMP_DIR" 2>>"$SITESTREAM_DIR/logs/sync.log"; then
    # Sanity check against a genuinely broken/empty tarball — not an
    # exhaustive per-file allowlist to keep updating whenever a release
    # adds something new (like pi-portal/ did).
    if [ ! -f "$UPDATE_TMP_DIR/sync.sh" ] || [ ! -f "$UPDATE_TMP_DIR/install.sh" ]; then
      log "ERROR: update tarball for $UPDATE_VERSION is missing sync.sh/install.sh — aborting update, staying on '${INSTALLED_VERSION:-none}'."
    else
      chmod +x "$UPDATE_TMP_DIR"/*.sh
      # cp -rf (not mv) the whole extracted tree — copying everything in one
      # shot, including files/directories this script has never heard of
      # (pi-portal/, or whatever a future release adds), rather than moving
      # a fixed list of names one at a time. This process keeps its
      # already-open fd on the old sync.sh inode via the still-running
      # interpreter (same as before), so overwriting the file out from
      # under it is safe — the one rule is still not to re-exec/source the
      # new file from this same process; we just exit right after.
      cp -rf "$UPDATE_TMP_DIR"/. "$SITESTREAM_DIR"/
      echo "$UPDATE_VERSION" > "$INSTALLED_VERSION_FILE"

      # The regular heartbeat (step 5, above) already fired earlier in this
      # same run — reporting whatever INSTALLED_VERSION was BEFORE this
      # update was applied, since self-update runs after it. Without this,
      # the API (and the admin UI) would show the device stuck on the old
      # version until its next scheduled cycle, even though it's already
      # running the new code — a needless gap, and confusing right after an
      # admin deliberately pushes a firmware update. One more lightweight
      # heartbeat here reports the truth immediately, right after it
      # changes — deliberately BEFORE the install.sh re-run below, which is
      # the riskiest, longest-running step here (apt-get, systemd, npm
      # install for pi-portal): if that step fails or hangs for any reason,
      # the version bump has already been reported successfully regardless.
      curl -sf -X POST -H "Authorization: Bearer $DEVICE_TOKEN" -H "Content-Type: application/json" \
        -d "$(jq -n --arg installedVersion "$UPDATE_VERSION" '{installedVersion: $installedVersion}')" \
        --max-time 15 \
        "$API_URL/api/devices/$(echo "$MANIFEST" | jq -r '.deviceId')/heartbeat" \
        > /dev/null || log "WARN: could not report updated version to API (will report on next cycle instead)"

      log "Updated to $UPDATE_VERSION. Re-running install.sh to apply any system-level changes (packages, systemd units, pi-portal)…"
      # This one call replaces what used to be two separate manual
      # `systemctl restart` calls here — install.sh already restarts/starts
      # every service it manages as part of its own normal setup. If this
      # run was itself push-triggered (a background child of listen.sh —
      # see trigger_sync() in listen.sh), install.sh restarting
      # sitestream-listen.service restarts this process's own parent;
      # KillMode=process on that unit (see install.sh) is what makes that
      # survivable, same as it already was for the old restart call.
      if sudo bash "$SITESTREAM_DIR/install.sh" "$API_URL" "$APP_URL" >> "$SITESTREAM_DIR/logs/sync.log" 2>&1; then
        log "install.sh re-run succeeded."
      else
        log "WARN: install.sh re-run failed (sudoers rule missing? see install.sh) — script files are updated, but any system-level changes this release needed may not have applied. Check logs/sync.log."
      fi

      rm -rf "$UPDATE_TMP_DIR"
      log "Update to $UPDATE_VERSION complete. Exiting — next cron tick runs the new sync.sh."
      exit 0
    fi
  else
    log "ERROR: update $UPDATE_VERSION failed to download or extract — staying on '${INSTALLED_VERSION:-none}'."
  fi

  rm -rf "$UPDATE_TMP_DIR"
fi
