#!/bin/bash
# SiteStream Pi Client — Sync Script
# Runs every 15 minutes via cron.
#
# What it does:
#   1. Fetches the manifest (schedule + video list) from the API
#   2. Downloads any videos not yet cached locally (compares ETags)
#   3. Deletes videos that are no longer in the schedule (frees SD card space)
#   4. Writes /home/pi/sitestream/schedule.json for the player to read
#   5. Reports back to the API (heartbeat) with confirmed manifest hash

set -e

CONFIG="/home/pi/sitestream/config.env"
[ -f "$CONFIG" ] && source "$CONFIG"

API_URL="${API_URL:-https://api.sitestream.app}"
VIDEO_DIR="${VIDEO_DIR:-/home/pi/sitestream/videos}"
SCHEDULE_FILE="/home/pi/sitestream/schedule.json"
MANIFEST_HASH_FILE="/home/pi/sitestream/.manifest_hash"
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')]"

log() { echo "$LOG_PREFIX $1"; }

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

    curl -sf \
      -o "$TEMP_PATH" \
      --max-time 600 \
      --progress-bar \
      "$DOWNLOAD_URL" && {
        mv "$TEMP_PATH" "$LOCAL_PATH"
        echo "$ETAG" > "$LOCAL_ETAG_FILE"
        log "Downloaded $FILENAME successfully."
      } || {
        log "ERROR: Failed to download $FILENAME. Keeping old copy if present."
        rm -f "$TEMP_PATH"
      }
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
echo "$MANIFEST" | jq '{
  manifestVersion: .manifestVersion,
  generatedAt: .generatedAt,
  schedule: [.schedule[] | {
    videoId, filename, etag, startTime, endTime, daysOfWeek,
    validFrom, validUntil, priority, label,
    localPath: ("/home/pi/sitestream/videos/" + .videoId + ".mp4")
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
touch /home/pi/sitestream/.schedule_updated
