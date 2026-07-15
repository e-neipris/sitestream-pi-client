#!/bin/bash
# SiteStream Pi Client — Sync Script
# Runs every minute via cron (overlap-safe — see the flock guard below).
#
# What it does:
#   0. If not yet provisioned (no DEVICE_TOKEN), checks in with the API using
#      this Pi's hardware serial and either gets a token back (continues below)
#      or logs that it's still waiting to be claimed and exits until next run.
#   1. Fetches the manifest (schedule + video list) from the API
#   2. Downloads any videos not yet cached locally (compares ETags)
#   3. Deletes videos that are no longer in the schedule (frees SD card space)
#   4. Writes schedule.json (in this script's own directory) for the player to read
#   5. Reports back to the API (heartbeat) with confirmed manifest hash

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

# With cron firing every minute, a large in-progress download can easily still
# be running when the next tick fires. flock -n on an fd tied to a lock file
# makes a second invocation exit immediately instead of starting a competing
# download into the same temp file.
exec 200>"$SITESTREAM_DIR/.sync.lock"
if ! flock -n 200; then
  log "Previous sync.sh still running — skipping this run."
  exit 0
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

    # -C - resumes from the partial file already on disk — but curl's own
    # --retry does NOT reliably re-apply that resume point between its
    # internal retry attempts within a single invocation (long-standing curl
    # quirk), so a dropped connection mid-transfer can reset to byte 0 instead
    # of resuming. Retrying as separate curl invocations from bash instead
    # avoids that — each fresh invocation correctly picks up the current
    # on-disk size.
    DOWNLOAD_OK=false
    for attempt in 1 2 3 4 5; do
      CURL_EXIT=0
      CURL_LOG=$(curl -sS -f \
        -o "$TEMP_PATH" \
        -C - \
        --max-time 1800 \
        -w 'http_code=%{http_code} bytes_this_attempt=%{size_download} elapsed=%{time_total}s avg_speed=%{speed_download}B/s' \
        "$DOWNLOAD_URL" 2>&1) || CURL_EXIT=$?

      if [ "$CURL_EXIT" -eq 0 ]; then
        DOWNLOAD_OK=true
        break
      fi

      ON_DISK_BYTES=$(stat -c%s "$TEMP_PATH" 2>/dev/null || echo 0)
      log "Download attempt $attempt for $FILENAME failed (curl exit $CURL_EXIT: $(curl_exit_reason "$CURL_EXIT")) — on-disk so far: ${ON_DISK_BYTES} bytes. ${CURL_LOG//$'\n'/ } — retrying in 5s…"
      sleep 5
    done

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

# ── 5. Heartbeat — report confirmed manifest hash ─────────────────────────────
IP_ADDRESS=$(hostname -I | awk '{print $1}')

curl -sf \
  -X POST \
  -H "Authorization: Bearer $DEVICE_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"confirmedManifestHash\":\"$MANIFEST_VERSION\",\"ipAddress\":\"$IP_ADDRESS\"}" \
  --max-time 15 \
  "$API_URL/api/devices/$(echo "$MANIFEST" | jq -r '.deviceId')/heartbeat" \
  > /dev/null || log "WARN: Heartbeat failed (non-fatal)"

echo "$MANIFEST_VERSION" > "$MANIFEST_HASH_FILE"
log "Sync complete. Manifest: $MANIFEST_VERSION"

# ── 6. Signal the player to re-read the schedule ──────────────────────────────
touch "$SITESTREAM_DIR/.schedule_updated"
