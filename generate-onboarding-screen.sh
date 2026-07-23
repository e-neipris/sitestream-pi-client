#!/bin/bash
# SiteStream Pi Client — Onboarding Screen Generator
#
# Produces a static PNG (serial number, instructions, QR code) that player.sh
# displays instead of normal schedule-driven playback whenever this device
# hasn't been claimed yet (no DEVICE_TOKEN in config.env) — replacing a blank/
# idle desktop with something a first-time buyer can actually act on.
#
# Two distinct screens depending on connectivity, not one:
#   - Has a network already (Ethernet, or Wi-Fi already joined): the
#     original claim-serial screen, QR pointed at the cloud claim URL.
#   - No network at all (wifi-ap-fallback.sh's ad-hoc hotspot is active):
#     a QR that joins a phone directly to THAT hotspot (standard WIFI:
#     QR format modern phone cameras auto-detect), since the claim URL
#     isn't reachable from anywhere yet — there's no internet route out
#     of this device at all in that state, hotspot included.
#
# Idempotent by design: skips regenerating if the output already exists AND
# neither this device's LAN IP nor its hotspot on/off state have changed
# since the last time it was generated. Pass FORCE=1 to regenerate anyway.
# Safe to call on every player.sh loop tick — the common case is a fast no-op.

set -e

SITESTREAM_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SITESTREAM_DIR/config.env"
[ -f "$CONFIG" ] && source "$CONFIG"

APP_URL="${APP_URL:-https://app.sitestream.app}"
OUTPUT="$SITESTREAM_DIR/onboarding.png"

CURRENT_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

# Mirrors wifi-ap-fallback.sh's own hotspot_active() check exactly — this
# has to agree with that script about whether the hotspot is actually up,
# or the QR code below could advertise joining a network that isn't there.
HOTSPOT_CONN_NAME="SiteStream-Setup"
HOTSPOT_ACTIVE=false
if command -v nmcli >/dev/null 2>&1 && nmcli -t -f NAME connection show --active 2>/dev/null | grep -qx "$HOTSPOT_CONN_NAME"; then
  HOTSPOT_ACTIVE=true
fi

STATE_CACHE_FILE="$SITESTREAM_DIR/.onboarding_state"
CACHED_STATE=$(cat "$STATE_CACHE_FILE" 2>/dev/null || echo "")
CURRENT_STATE="$CURRENT_IP:$HOTSPOT_ACTIVE"

if [ -f "$OUTPUT" ] && [ "$FORCE" != "1" ] && [ "$CURRENT_STATE" = "$CACHED_STATE" ]; then
  exit 0
fi

SERIAL=$(awk -F': ' '/^Serial/ {print $2}' /proc/cpuinfo | tr -d ' \n')
if [ -z "$SERIAL" ]; then
  echo "ERROR: could not read hardware serial from /proc/cpuinfo. Cannot generate onboarding screen." >&2
  exit 1
fi

QR_PNG="$SITESTREAM_DIR/.onboarding_qr.png"
BASE_PNG="$SITESTREAM_DIR/.onboarding_base.png"

if [ "$HOTSPOT_ACTIVE" = true ]; then
  # Must derive identically to wifi-ap-fallback.sh's own SSID/password —
  # duplicated rather than shared, since it's two lines and both scripts
  # already read $SERIAL independently.
  HOTSPOT_SSID="SiteStream-${SERIAL: -4}"
  HOTSPOT_PASSWORD="${SERIAL: -8}"

  WIFI_IFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
  HOTSPOT_GATEWAY_IP=$(nmcli -g IP4.ADDRESS device show "$WIFI_IFACE" 2>/dev/null | cut -d/ -f1)
  # NetworkManager's own documented default for `nmcli device wifi hotspot`
  # when nothing overrides it — used only if the live query above comes back
  # empty (e.g. nmcli's output format changes), not trusted as the primary source.
  HOTSPOT_GATEWAY_IP="${HOTSPOT_GATEWAY_IP:-10.42.0.1}"

  # Standard Wi-Fi QR format (WIFI:T:<auth>;S:<ssid>;P:<password>;;) — iOS 11+
  # and Android's own camera apps recognize this natively and offer to join
  # directly, no separate QR-scanner app needed. No escaping of S:/P: needed
  # here specifically: both values are always hex digits from the serial,
  # never any of the characters the spec requires escaping (;,:\\).
  qrencode -o "$QR_PNG" -s 10 -m 2 "WIFI:T:WPA;S:$HOTSPOT_SSID;P:$HOTSPOT_PASSWORD;;"

  convert -size 1920x1080 xc:'#0f172a' \
    -gravity North \
    -fill '#e2e8f0' -font DejaVu-Sans-Bold -pointsize 72 -annotate +0+70  'SiteStream' \
    -fill '#94a3b8' -font DejaVu-Sans      -pointsize 34 -annotate +0+170 'This device is not yet connected' \
    -fill '#e2e8f0' -font DejaVu-Sans-Bold -pointsize 46 -annotate +0+250 "Serial Number: $SERIAL" \
    -fill '#94a3b8' -font DejaVu-Sans      -pointsize 30 -annotate +0+330 '1. Scan the QR code below to join this device'"'"'s temporary Wi-Fi' \
    -fill '#94a3b8' -font DejaVu-Sans      -pointsize 26 -annotate +0+370 "   Network: $HOTSPOT_SSID   Password: $HOTSPOT_PASSWORD" \
    -fill '#94a3b8' -font DejaVu-Sans      -pointsize 30 -annotate +0+420 "2. Then open http://$HOTSPOT_GATEWAY_IP:8080 to join your real Wi-Fi network" \
    "$BASE_PNG"
else
  # Matches the ?claim=<serial> query param the web portal's Devices page
  # reads to auto-open the Claim Device modal pre-filled with this serial —
  # see packages/web/src/pages/Devices.tsx.
  CLAIM_URL="$APP_URL/devices?claim=$SERIAL"
  qrencode -o "$QR_PNG" -s 10 -m 2 "$CLAIM_URL"

  # Only mentioned when pi-portal is actually part of this install (older
  # releases, or a device install.sh deliberately skipped it for, won't have
  # the directory at all) — no point pointing someone at a port nothing's
  # listening on.
  STANDALONE_LINE=""
  if [ -d "$SITESTREAM_DIR/pi-portal" ] && [ -n "$CURRENT_IP" ]; then
    STANDALONE_LINE="3. Or skip the cloud entirely — manage this device at http://$CURRENT_IP:8080"
  fi

  convert -size 1920x1080 xc:'#0f172a' \
    -gravity North \
    -fill '#e2e8f0' -font DejaVu-Sans-Bold -pointsize 72 -annotate +0+70  'SiteStream' \
    -fill '#94a3b8' -font DejaVu-Sans      -pointsize 34 -annotate +0+170 'This device is not yet connected' \
    -fill '#e2e8f0' -font DejaVu-Sans-Bold -pointsize 46 -annotate +0+250 "Serial Number: $SERIAL" \
    -fill '#94a3b8' -font DejaVu-Sans      -pointsize 30 -annotate +0+330 "1. Go to $APP_URL and claim this serial number" \
    -fill '#94a3b8' -font DejaVu-Sans      -pointsize 30 -annotate +0+370 '2. Or scan the QR code below with your phone' \
    -fill '#94a3b8' -font DejaVu-Sans      -pointsize 30 -annotate +0+410 "$STANDALONE_LINE" \
    "$BASE_PNG"
fi

# 1920x1080 — the common case for HDMI output this runs on. VLC scales
# whatever it's given to fit the actual display, so this doesn't need to
# match exactly.
convert "$BASE_PNG" "$QR_PNG" -gravity South -geometry +0+80 -composite "$OUTPUT"

rm -f "$QR_PNG" "$BASE_PNG"
echo "$CURRENT_STATE" > "$STATE_CACHE_FILE"
