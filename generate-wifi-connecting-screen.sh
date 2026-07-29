#!/bin/bash
# SiteStream Pi Client — Wi-Fi Connecting Screen Generator
#
# Produces a static PNG that player.sh displays while a Wi-Fi join
# requested through the local portal (System tab → Wi-Fi → Join Network) is
# still in progress. Fills the gap between "just submitted a join" and
# "confirmed success or failure" — without this, the screen just sat on the
# plain onboarding/idle screen (or a stale rescue screen) the whole time a
# join was happening, giving zero indication anything was actually
# happening. Confirmed in QA as confusing specifically because a join can
# take a real, human-noticeable amount of time (radio re-association, DHCP)
# and the portal's own response no longer waits for it to finish (see
# system.ts's /wifi/connect — fire-and-forget, for reasons that script
# documents).
#
# pi-portal/server writes the .wifi_connecting state file (see that route)
# the moment a join is requested — this script reads it directly, same
# pattern as generate-wifi-rescue-screen.sh reading .wifi_rescue_state,
# rather than the caller (player.sh) having to thread the SSID through as
# an argument.
#
# Deliberately age-based, not "wait for an explicit clear": there's no
# clean, reliable signal for "the join is now definitively resolved" (the
# underlying nmcli/raspi-config call completing doesn't mean DHCP finished
# or the network is actually reachable — the same ambiguity is why
# wifi-ap-fallback.sh itself waits out a grace period before declaring a
# saved profile stuck, rather than reacting to any single failure
# instantly). Past CONNECTING_FRESH_SECONDS, this stops rendering — by then
# either the join succeeded (this branch of player.sh isn't even reached
# anymore) or wifi-ap-fallback.sh's own rescue-mode detection (a similar
# ~90s grace period) has had time to take over with the fuller "here's
# what's wrong and how to fix it" screen.

set -e

SITESTREAM_DIR="$(cd "$(dirname "$0")" && pwd)"
CONNECTING_STATE_FILE="$SITESTREAM_DIR/.wifi_connecting"
OUTPUT="$SITESTREAM_DIR/wifi-connecting.png"
CONNECTING_FRESH_SECONDS=90

[ -f "$CONNECTING_STATE_FILE" ] || { echo "No connecting state — nothing to generate." >&2; exit 1; }

STATE_MTIME=$(stat -c '%Y' "$CONNECTING_STATE_FILE" 2>/dev/null || echo 0)
NOW=$(date +%s)
if [ $((NOW - STATE_MTIME)) -gt "$CONNECTING_FRESH_SECONDS" ]; then
  # Stale — clean up so this doesn't linger and get mistaken for a fresh
  # attempt later, and so an existence-only check elsewhere doesn't need to
  # separately know about the age threshold used here.
  rm -f "$CONNECTING_STATE_FILE" "$OUTPUT" "$SITESTREAM_DIR/.wifi_connecting_screen_state"
  echo "Connecting state is stale (>${CONNECTING_FRESH_SECONDS}s) — nothing to generate." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONNECTING_STATE_FILE"
CONNECTING_SSID="${SSID:-your network}"

SERIAL=$(awk -F': ' '/^Serial/ {print $2}' /proc/cpuinfo | tr -d ' \n')

STATE_CACHE_FILE="$SITESTREAM_DIR/.wifi_connecting_screen_state"
CACHED_STATE=$(cat "$STATE_CACHE_FILE" 2>/dev/null || echo "")
CURRENT_STATE="$CONNECTING_SSID"

if [ -f "$OUTPUT" ] && [ "$FORCE" != "1" ] && [ "$CURRENT_STATE" = "$CACHED_STATE" ]; then
  exit 0
fi

convert -size 1920x1080 xc:'#0f172a' \
  -gravity North \
  -fill '#e2e8f0' -font DejaVu-Sans-Bold -pointsize 60 -annotate +0+70  'Connecting…' \
  -fill '#94a3b8' -font DejaVu-Sans      -pointsize 40 -annotate +0+190 "Joining \"$CONNECTING_SSID\"" \
  -fill '#94a3b8' -font DejaVu-Sans      -pointsize 30 -annotate +0+260 'This may take a few minutes.' \
  -fill '#e2e8f0' -font DejaVu-Sans-Bold -pointsize 46 -annotate +0+340 "Serial Number: $SERIAL" \
  "$OUTPUT"

echo "$CURRENT_STATE" > "$STATE_CACHE_FILE"
