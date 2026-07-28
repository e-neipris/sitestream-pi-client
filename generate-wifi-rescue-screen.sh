#!/bin/bash
# SiteStream Pi Client — Wi-Fi Rescue Screen Generator
#
# Produces a static PNG that player.sh displays whenever wifi-ap-fallback.sh
# has decided this device's CONFIGURED Wi-Fi network isn't reachable (see
# that script's "rescue mode" — .wifi_rescue_state below is written/cleared
# by it). Distinct from generate-onboarding-screen.sh's claim-serial screen:
# this device already has a saved network, it just can't currently reach
# it — the message here is "here's what's wrong and how to fix it," not
# "here's how to claim this device."
#
# Same idempotent-by-default pattern as the onboarding/idle screens: skips
# regenerating if the output already exists and nothing relevant (hotspot
# on/off, which network is stuck, how long it's been stuck) has changed
# since last time. Pass FORCE=1 to regenerate anyway. Safe to call on every
# player.sh loop tick.

set -e

SITESTREAM_DIR="$(cd "$(dirname "$0")" && pwd)"
RESCUE_STATE_FILE="$SITESTREAM_DIR/.wifi_rescue_state"
OUTPUT="$SITESTREAM_DIR/wifi-rescue.png"

[ -f "$RESCUE_STATE_FILE" ] || { echo "No rescue state — nothing to generate." >&2; exit 1; }
# shellcheck disable=SC1090
source "$RESCUE_STATE_FILE"
RESCUE_SSID="${SSID:-your configured network}"
RESCUE_SINCE="${SINCE:-0}"

SERIAL=$(awk -F': ' '/^Serial/ {print $2}' /proc/cpuinfo | tr -d ' \n')
if [ -z "$SERIAL" ]; then
  echo "ERROR: could not read hardware serial from /proc/cpuinfo. Cannot generate rescue screen." >&2
  exit 1
fi
HOTSPOT_SSID="SiteStream-${SERIAL: -4}"
HOTSPOT_PASSWORD="${SERIAL: -8}"

# Mirrors wifi-ap-fallback.sh's own hotspot_active() check exactly — this
# has to agree with that script about whether the hotspot is actually up
# right now (it toggles off briefly during each retry attempt), or this
# screen could tell someone to join a hotspot that isn't currently there.
HOTSPOT_CONN_NAME="SiteStream-Setup"
HOTSPOT_ACTIVE=false
if command -v nmcli >/dev/null 2>&1 && nmcli -t -f NAME connection show --active 2>/dev/null | grep -qx "$HOTSPOT_CONN_NAME"; then
  HOTSPOT_ACTIVE=true
fi

STATE_CACHE_FILE="$SITESTREAM_DIR/.wifi_rescue_screen_state"
CACHED_STATE=$(cat "$STATE_CACHE_FILE" 2>/dev/null || echo "")
CURRENT_STATE="$RESCUE_SSID:$RESCUE_SINCE:$HOTSPOT_ACTIVE"

if [ -f "$OUTPUT" ] && [ "$FORCE" != "1" ] && [ "$CURRENT_STATE" = "$CACHED_STATE" ]; then
  exit 0
fi

QR_PNG="$SITESTREAM_DIR/.wifi_rescue_qr.png"
BASE_PNG="$SITESTREAM_DIR/.wifi_rescue_base.png"

if [ "$HOTSPOT_ACTIVE" = true ]; then
  qrencode -o "$QR_PNG" -s 10 -m 2 "WIFI:T:WPA;S:$HOTSPOT_SSID;P:$HOTSPOT_PASSWORD;;"
  # Same live query + documented-default fallback as generate-onboarding-
  # screen.sh's own HOTSPOT_GATEWAY_IP — duplicated rather than shared, same
  # reasoning as that file's own SSID/password duplication comment.
  WIFI_IFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
  HOTSPOT_GATEWAY_IP=$(nmcli -g IP4.ADDRESS device show "$WIFI_IFACE" 2>/dev/null | cut -d/ -f1)
  HOTSPOT_GATEWAY_IP="${HOTSPOT_GATEWAY_IP:-10.42.0.1}"
  HOTSPOT_LINES=(
    -fill '#94a3b8' -font DejaVu-Sans -pointsize 30 -annotate +0+460 '2. Scan the QR code below to join its temporary Wi-Fi'
    -fill '#94a3b8' -font DejaVu-Sans -pointsize 26 -annotate +0+500 "   Network: $HOTSPOT_SSID   Password: $HOTSPOT_PASSWORD"
    -fill '#94a3b8' -font DejaVu-Sans -pointsize 30 -annotate +0+550 "3. Open http://$HOTSPOT_GATEWAY_IP:8080 and update the Wi-Fi network/password"
  )
else
  # Between retries, right after this device grabbed the radio back to
  # attempt the real network — the hotspot will reappear within
  # CHECK_INTERVAL_SECONDS if that attempt fails again. No QR code to show
  # in this brief window since there's nothing to join yet.
  HOTSPOT_LINES=(
    -fill '#94a3b8' -font DejaVu-Sans -pointsize 30 -annotate +0+460 '2. Retrying now — the setup hotspot will reappear here shortly if it fails again'
  )

fi

convert -size 1920x1080 xc:'#0f172a' \
  -gravity North \
  -fill '#fbbf24' -font DejaVu-Sans-Bold -pointsize 60 -annotate +0+70  'Wi-Fi Connection Problem' \
  -fill '#e2e8f0' -font DejaVu-Sans-Bold -pointsize 40 -annotate +0+180 "Can't connect to \"$RESCUE_SSID\"" \
  -fill '#94a3b8' -font DejaVu-Sans      -pointsize 30 -annotate +0+240 "This device will keep retrying automatically every 5 minutes." \
  -fill '#e2e8f0' -font DejaVu-Sans-Bold -pointsize 46 -annotate +0+320 "Serial Number: $SERIAL" \
  -fill '#94a3b8' -font DejaVu-Sans      -pointsize 30 -annotate +0+390 "To fix it now:" \
  -fill '#94a3b8' -font DejaVu-Sans      -pointsize 30 -annotate +0+420 "1. On your phone or laptop, look for Wi-Fi network \"$HOTSPOT_SSID\"" \
  "${HOTSPOT_LINES[@]}" \
  "$BASE_PNG"

if [ -f "$QR_PNG" ]; then
  convert "$BASE_PNG" "$QR_PNG" -gravity South -geometry +0+80 -composite "$OUTPUT"
else
  cp "$BASE_PNG" "$OUTPUT"
fi

rm -f "$QR_PNG" "$BASE_PNG"
echo "$CURRENT_STATE" > "$STATE_CACHE_FILE"
