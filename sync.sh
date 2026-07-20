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
#   1d. Adjusts its own cron schedule if the zone's configured interval changed
#   2. Downloads any videos not yet cached locally (compares ETags)
#   3. Deletes videos that are no longer in the schedule (frees SD card space)
#   4. Writes schedule.json (in this script's own directory) for the player to read
#   5. Reports back to the API (heartbeat) with confirmed manifest hash + health
#      telemetry (player.sh's live status, CPU temp, disk, uptime)
#   6. Signals player.sh to re-read the schedule
#   7. Applies a pending pi-client update, if the manifest targets a release
#      different from what's installed — see the self-update section below

set -e

SITESTREAM_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SITESTREAM_DIR/config.env"
[ -f "$CONFIG" ] && source "$CONFIG"

API_URL="${API_URL:-https://api.sitestream.app}"
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

# At a fast sync interval (as low as 1 minute), a large in-progress download
# can easily still be running when the next tick fires. flock -n on an fd
# tied to a lock file makes a second invocation exit immediately instead of
# starting a competing download into the same temp file.
exec 200>"$SITESTREAM_DIR/.sync.lock"
if ! flock -n 200; then
  log "Previous sync.sh still running — skipping this run."
  exit 0
fi

# Jitter: every device on the same zone typically shares the same cron
# cadence, and cron fires all of them at the same wall-clock second — so
# without this they'd all hit the API in the same instant, every cycle, not
# just during an outage-recovery burst. A small random delay before any
# network call spreads that out. Kept short (not scaled to the sync
# interval) so it doesn't meaningfully delay time-sensitive things like a
# pending reboot or schedule push — worst case a few tens of seconds, not
# minutes.
sleep $((RANDOM % 46))

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

grep -vE '^(MULTICAST_ENABLED|MULTICAST_ADDRESS|MULTICAST_PORT)=' "$CONFIG" 2>/dev/null > "$CONFIG.tmp" || true
{
  echo "MULTICAST_ENABLED=$MULTICAST_ENABLED"
  echo "MULTICAST_ADDRESS=$MULTICAST_ADDRESS"
  echo "MULTICAST_PORT=$MULTICAST_PORT"
} >> "$CONFIG.tmp"
mv "$CONFIG.tmp" "$CONFIG"
chmod 600 "$CONFIG"

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
SCHEDULE=$(echo "$MANIFEST" | jq -c '.schedule[]')
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
done <<< "$(echo "$MANIFEST" | jq -c '.schedule[]')"

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
# Known limitation: this only replaces the three script files. It does NOT
# re-run install.sh's system-level setup (new apt packages, new systemd
# units, new sudoers rules) — those still need a manual install.sh re-run.
# This mechanism is for script-logic fixes (like the ones made this session),
# not changes that touch the Pi's system configuration.
UPDATE_VERSION=$(echo "$MANIFEST" | jq -r '.update.version // empty')
UPDATE_URL=$(echo "$MANIFEST" | jq -r '.update.downloadUrl // empty')

if [ -n "$UPDATE_VERSION" ] && [ "$UPDATE_VERSION" != "$INSTALLED_VERSION" ]; then
  log "Update available: '${INSTALLED_VERSION:-none}' -> '$UPDATE_VERSION'. Downloading…"
  UPDATE_TMP_DIR=$(mktemp -d)
  UPDATE_TARBALL="$UPDATE_TMP_DIR/release.tar.gz"

  download_with_retries "$UPDATE_URL" "$UPDATE_TARBALL" "pi-client update $UPDATE_VERSION"

  if [ "$DOWNLOAD_OK" = true ] && tar -xzf "$UPDATE_TARBALL" -C "$UPDATE_TMP_DIR" 2>>"$SITESTREAM_DIR/logs/sync.log"; then
    APPLY_OK=true
    for f in sync.sh player.sh install.sh listen.sh; do
      if [ ! -f "$UPDATE_TMP_DIR/$f" ]; then
        log "ERROR: update tarball for $UPDATE_VERSION is missing $f — aborting update, staying on '${INSTALLED_VERSION:-none}'."
        APPLY_OK=false
        break
      fi
    done

    if [ "$APPLY_OK" = true ]; then
      chmod +x "$UPDATE_TMP_DIR/sync.sh" "$UPDATE_TMP_DIR/player.sh" "$UPDATE_TMP_DIR/install.sh" "$UPDATE_TMP_DIR/listen.sh"
      # mv (rename), not copy-in-place — this process keeps its already-open
      # fd on the old sync.sh inode via the still-running interpreter, so
      # replacing the filename out from under it is safe. The one rule is
      # not to try to re-exec/source the new file from this same process —
      # we just exit right after, and cron's next tick starts fresh from it.
      mv "$UPDATE_TMP_DIR/sync.sh" "$SITESTREAM_DIR/sync.sh"
      mv "$UPDATE_TMP_DIR/player.sh" "$SITESTREAM_DIR/player.sh"
      mv "$UPDATE_TMP_DIR/install.sh" "$SITESTREAM_DIR/install.sh"
      mv "$UPDATE_TMP_DIR/listen.sh" "$SITESTREAM_DIR/listen.sh"
      echo "$UPDATE_VERSION" > "$INSTALLED_VERSION_FILE"

      log "Updated to $UPDATE_VERSION. Restarting player and listener services."
      sudo systemctl restart sitestream-player.service 2>>"$SITESTREAM_DIR/logs/sync.log" \
        || log "WARN: could not restart sitestream-player.service (sudoers rule missing? see install.sh)"
      # Older devices updating for the first time past this release won't have
      # this unit yet (self-update never re-runs install.sh's system-level
      # setup — see the header note above) — that's expected, not an error;
      # it'll exist after their next manual install.sh re-run.
      sudo systemctl restart sitestream-listen.service 2>>"$SITESTREAM_DIR/logs/sync.log" \
        || log "WARN: could not restart sitestream-listen.service (not installed yet? re-run install.sh)"

      rm -rf "$UPDATE_TMP_DIR"
      log "Update to $UPDATE_VERSION complete. Exiting — next cron tick runs the new sync.sh."
      exit 0
    fi
  else
    log "ERROR: update $UPDATE_VERSION failed to download or extract — staying on '${INSTALLED_VERSION:-none}'."
  fi

  rm -rf "$UPDATE_TMP_DIR"
fi
