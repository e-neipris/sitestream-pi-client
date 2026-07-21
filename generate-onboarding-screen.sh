#!/bin/bash
# SiteStream Pi Client — Onboarding Screen Generator
#
# Produces a static PNG (serial number, instructions, QR code) that player.sh
# displays instead of normal schedule-driven playback whenever this device
# hasn't been claimed yet (no DEVICE_TOKEN in config.env) — replacing a blank/
# idle desktop with something a first-time buyer can actually act on.
#
# Idempotent by design: skips regenerating if the output already exists,
# since the serial number never changes and APP_URL essentially never does
# either. Pass FORCE=1 to regenerate anyway (e.g. after changing APP_URL).
# Safe to call on every player.sh loop tick — the common case is just a fast
# "already exists" no-op.

set -e

SITESTREAM_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SITESTREAM_DIR/config.env"
[ -f "$CONFIG" ] && source "$CONFIG"

APP_URL="${APP_URL:-https://app.sitestream.app}"
OUTPUT="$SITESTREAM_DIR/onboarding.png"

if [ -f "$OUTPUT" ] && [ "$FORCE" != "1" ]; then
  exit 0
fi

SERIAL=$(awk -F': ' '/^Serial/ {print $2}' /proc/cpuinfo | tr -d ' \n')
if [ -z "$SERIAL" ]; then
  echo "ERROR: could not read hardware serial from /proc/cpuinfo. Cannot generate onboarding screen." >&2
  exit 1
fi

# Matches the ?claim=<serial> query param the web portal's Devices page reads
# to auto-open the Claim Device modal pre-filled with this serial — see
# packages/web/src/pages/Devices.tsx.
CLAIM_URL="$APP_URL/devices?claim=$SERIAL"

QR_PNG="$SITESTREAM_DIR/.onboarding_qr.png"
BASE_PNG="$SITESTREAM_DIR/.onboarding_base.png"

# -m 2: quiet margin wide enough for phone cameras to reliably lock on at a
# few feet from the screen, not just up close.
qrencode -o "$QR_PNG" -s 10 -m 2 "$CLAIM_URL"

# 1920x1080 — the common case for HDMI output this runs on. VLC scales
# whatever it's given to fit the actual display, so this doesn't need to
# match exactly.
convert -size 1920x1080 xc:'#0f172a' \
  -gravity North \
  -fill '#e2e8f0' -font DejaVu-Sans-Bold -pointsize 72 -annotate +0+70  'SiteStream' \
  -fill '#94a3b8' -font DejaVu-Sans      -pointsize 34 -annotate +0+170 'This device is not yet connected' \
  -fill '#e2e8f0' -font DejaVu-Sans-Bold -pointsize 46 -annotate +0+250 "Serial Number: $SERIAL" \
  -fill '#94a3b8' -font DejaVu-Sans      -pointsize 30 -annotate +0+330 "1. Go to $APP_URL and claim this serial number" \
  -fill '#94a3b8' -font DejaVu-Sans      -pointsize 30 -annotate +0+370 '2. Or scan the QR code below with your phone' \
  "$BASE_PNG"

convert "$BASE_PNG" "$QR_PNG" -gravity South -geometry +0+80 -composite "$OUTPUT"

rm -f "$QR_PNG" "$BASE_PNG"
