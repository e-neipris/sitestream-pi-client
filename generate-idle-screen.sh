#!/bin/bash
# SiteStream Pi Client — Idle Screen Generator
#
# Produces a static PNG that player.sh displays whenever this device IS
# claimed and configured but has no schedule entry matching the current
# time — replacing a blank/black screen (the old behavior) with something
# that tells whoever's standing in front of it that this is expected, not
# broken, and how to fix it if it isn't. Counterpart to
# generate-onboarding-screen.sh, which covers the *unclaimed* case; this one
# only ever runs for an already-claimed device, so it never mentions
# claiming.
#
# Idempotent by design, same pattern as generate-onboarding-screen.sh: skips
# regenerating if the output already exists and this device's LAN IP hasn't
# changed since the last time it was generated. Pass FORCE=1 to regenerate
# anyway. Safe to call on every player.sh loop tick — the common case is a
# fast no-op.

set -e

SITESTREAM_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SITESTREAM_DIR/config.env"
[ -f "$CONFIG" ] && source "$CONFIG"

OUTPUT="$SITESTREAM_DIR/idle.png"
CURRENT_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

STATE_CACHE_FILE="$SITESTREAM_DIR/.idle_state"
CACHED_STATE=$(cat "$STATE_CACHE_FILE" 2>/dev/null || echo "")
CURRENT_STATE="$CURRENT_IP"

if [ -f "$OUTPUT" ] && [ "$FORCE" != "1" ] && [ "$CURRENT_STATE" = "$CACHED_STATE" ]; then
  exit 0
fi

SERIAL=$(awk -F': ' '/^Serial/ {print $2}' /proc/cpuinfo | tr -d ' \n')

QR_PNG="$SITESTREAM_DIR/.idle_qr.png"
BASE_PNG="$SITESTREAM_DIR/.idle_base.png"

# Only mentioned/QR'd when pi-portal is actually part of this install (older
# releases, or a device install.sh deliberately skipped it for, won't have
# the directory at all) and this device actually has a LAN IP to point at —
# no point advertising a URL nothing's listening on.
PORTAL_LINE=""
if [ -d "$SITESTREAM_DIR/pi-portal" ] && [ -n "$CURRENT_IP" ]; then
  PORTAL_URL="http://$CURRENT_IP:8080"
  PORTAL_LINE="Manage this device's schedule at $PORTAL_URL"
  qrencode -o "$QR_PNG" -s 10 -m 2 "$PORTAL_URL"
fi

convert -size 1920x1080 xc:'#0f172a' \
  -gravity North \
  -fill '#e2e8f0' -font DejaVu-Sans-Bold -pointsize 72 -annotate +0+70  'SiteStream' \
  -fill '#94a3b8' -font DejaVu-Sans      -pointsize 34 -annotate +0+170 'No content is currently scheduled to play' \
  -fill '#e2e8f0' -font DejaVu-Sans-Bold -pointsize 46 -annotate +0+250 "Serial Number: $SERIAL" \
  -fill '#94a3b8' -font DejaVu-Sans      -pointsize 30 -annotate +0+330 "${PORTAL_LINE:-This is expected outside your configured schedule windows.}" \
  "$BASE_PNG"

if [ -f "$QR_PNG" ]; then
  # 1920x1080 — the common case for HDMI output this runs on. VLC scales
  # whatever it's given to fit the actual display, so this doesn't need to
  # match exactly.
  convert "$BASE_PNG" "$QR_PNG" -gravity South -geometry +0+80 -composite "$OUTPUT"
else
  cp "$BASE_PNG" "$OUTPUT"
fi

rm -f "$QR_PNG" "$BASE_PNG"
echo "$CURRENT_STATE" > "$STATE_CACHE_FILE"
