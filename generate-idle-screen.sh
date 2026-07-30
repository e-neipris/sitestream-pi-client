#!/bin/bash
# SiteStream Pi Client — Idle Screen Generator
#
# Produces a static PNG that player.sh displays whenever this device has
# something configured (a cloud claim, OR a schedule built locally through
# the standalone-mode portal — see player.sh's own onboarding-vs-idle gate)
# but no schedule entry matching the current time — replacing a blank/black
# screen (the old behavior) with something that tells whoever's standing in
# front of it that this is expected, not broken, and how to fix it if it
# isn't. Counterpart to generate-onboarding-screen.sh, which covers the case
# where NOTHING has been configured yet either way; this one deliberately
# never mentions cloud-claim status since it applies regardless of it.
#
# Idempotent by design, same pattern as generate-onboarding-screen.sh: skips
# regenerating if the output already exists and neither this device's LAN IP
# nor its claim state has changed since the last time it was generated. Pass
# FORCE=1 to regenerate anyway. Safe to call on every player.sh loop tick —
# the common case is a fast no-op.

set -e

SITESTREAM_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SITESTREAM_DIR/config.env"
[ -f "$CONFIG" ] && source "$CONFIG"
APP_URL="${APP_URL:-https://app.sitestream.app}"

OUTPUT="$SITESTREAM_DIR/idle.png"
# Prefer a real address over a stale 169.254.x.x link-local one when an
# interface holds both at once (e.g. eth0 after DHCP comes back — see
# sync.sh's own comment on this same fix) — only fall back to whatever's
# first if nothing else exists, so a genuine no-DHCP device still shows
# something rather than a blank IP.
CURRENT_IP=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^169\.254\.' | head -1)
[ -z "$CURRENT_IP" ] && CURRENT_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

# Claim state now affects rendered content (see PORTAL_LINE below), so it
# has to be part of the cache key too — same reasoning as
# generate-onboarding-screen.sh including HOTSPOT_ACTIVE in its own state
# string. Without this, a device that gets claimed while already idle-
# screen-cached at the same IP wouldn't regenerate until the IP happened to
# change too, leaving the stale local-portal QR up indefinitely.
STATE_CACHE_FILE="$SITESTREAM_DIR/.idle_state"
CACHED_STATE=$(cat "$STATE_CACHE_FILE" 2>/dev/null || echo "")
CURRENT_STATE="$CURRENT_IP:${DEVICE_TOKEN:+claimed}"

if [ -f "$OUTPUT" ] && [ "$FORCE" != "1" ] && [ "$CURRENT_STATE" = "$CACHED_STATE" ]; then
  exit 0
fi

SERIAL=$(awk -F': ' '/^Serial/ {print $2}' /proc/cpuinfo | tr -d ' \n')

QR_PNG="$SITESTREAM_DIR/.idle_qr.png"
BASE_PNG="$SITESTREAM_DIR/.idle_base.png"

# Was unconditional — always pointed at the local portal regardless of claim
# state, even on a device that's fully cloud-managed. Confirmed in QA:
# claimed device, nothing scheduled, idle screen still told the tester to
# manage the schedule at the local portal's LAN IP instead of the SaaS —
# stale standalone-mode messaging on a device that isn't standalone anymore.
# Mirrors generate-onboarding-screen.sh's own claimed-vs-not branching
# (that script needs no such check itself — player.sh only invokes it when
# DEVICE_TOKEN is already empty).
PORTAL_LINE=""
if [ -n "${DEVICE_TOKEN:-}" ]; then
  PORTAL_LINE="Manage this device's schedule at $APP_URL"
  qrencode -o "$QR_PNG" -s 10 -m 2 "$APP_URL/devices"
elif [ -d "$SITESTREAM_DIR/pi-portal" ] && [ -n "$CURRENT_IP" ]; then
  # Only mentioned/QR'd when pi-portal is actually part of this install
  # (older releases, or a device install.sh deliberately skipped it for,
  # won't have the directory at all) and this device actually has a LAN IP
  # to point at — no point advertising a URL nothing's listening on.
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
