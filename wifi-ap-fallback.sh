#!/bin/bash
# SiteStream Pi Client — Wi-Fi Ad-Hoc Setup Fallback
# Runs continuously as a systemd service. If this device has no network
# connectivity at all AND hasn't been claimed yet, broadcasts its own
# temporary Wi-Fi hotspot so an installer's phone/laptop can connect
# directly and reach the standalone portal (http://<hotspot-gateway-ip>:8080)
# — its System tab's Wi-Fi section (already built) is what actually scans
# for and joins the real network. This script only manages the hotspot
# on/off decision, not the join itself.
#
# Requires NetworkManager (Raspberry Pi OS Bookworm/Trixie's default, and
# what this repo's own test hardware runs) — `nmcli device wifi hotspot` is
# a one-command AP+DHCP setup. A Bullseye image on dhcpcd+wpa_supplicant has
# no equivalent here; this script detects that and simply exits rather than
# pretending to work.
#
# IMPORTANT hardware limitation, not a bug: a single Wi-Fi radio can only be
# an access point OR a connected client at once, never both. The moment an
# installer uses the portal's Wi-Fi section to join a real network, this
# device's own hotspot drops — including the installer's phone/laptop
# connection to it. That's expected: reconnect to your own normal Wi-Fi
# afterward and confirm the Pi joined via its physical screen (onboarding
# screen disappearing means it's online) or by finding it on the real
# network.

set -u

SITESTREAM_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SITESTREAM_DIR/config.env"
LOG_PREFIX="[WIFI-AP $(date '+%H:%M:%S')]"
HOTSPOT_CONN_NAME="SiteStream-Setup"
CHECK_INTERVAL_SECONDS=30

log() { echo "$LOG_PREFIX $1"; }

if ! command -v nmcli >/dev/null 2>&1; then
  log "nmcli not present (not a NetworkManager system) — ad-hoc Wi-Fi fallback unavailable on this OS. Exiting."
  exit 0
fi

SERIAL=$(awk -F': ' '/^Serial/ {print $2}' /proc/cpuinfo | tr -d ' \n')
if [ -z "$SERIAL" ]; then
  log "ERROR: could not read hardware serial from /proc/cpuinfo. Exiting."
  exit 1
fi
# Last 4 hex chars — short enough to actually read off a phone's Wi-Fi list,
# unique enough that two devices being set up in the same room don't
# collide. Password reuses more of the serial (8 chars, WPA2's practical
# minimum) rather than a fixed string shared across every device ever
# shipped — this hotspot is temporary/setup-only, not meant to be memorable.
SSID="SiteStream-${SERIAL: -4}"
HOTSPOT_PASSWORD="${SERIAL: -8}"

is_connected() {
  [ -f "$CONFIG" ] && source "$CONFIG"
  [ -n "${API_URL:-}" ] || return 1
  curl -sf --max-time 5 "$API_URL/health" >/dev/null 2>&1
}

is_claimed() {
  [ -f "$CONFIG" ] && source "$CONFIG"
  [ -n "${DEVICE_TOKEN:-}" ]
}

hotspot_active() {
  nmcli -t -f NAME connection show --active 2>/dev/null | grep -qx "$HOTSPOT_CONN_NAME"
}

start_hotspot() {
  hotspot_active && return
  log "No network connectivity and not yet claimed — starting setup hotspot '$SSID'"
  # sudo -n, not a plain unprivileged call — creating/activating a
  # NetworkManager connection from a non-interactive systemd service (no
  # logind session) hit real polkit permission denials during testing of
  # the portal's own Wi-Fi scan/join features; routing through the same
  # sudoers-grant pattern avoids repeating that here.
  if ! sudo -n nmcli device wifi hotspot ifname wlan0 con-name "$HOTSPOT_CONN_NAME" ssid "$SSID" password "$HOTSPOT_PASSWORD" \
      >>"$SITESTREAM_DIR/logs/wifi-ap.log" 2>&1; then
    log "WARN: could not start hotspot — see logs/wifi-ap.log"
  fi
}

stop_hotspot() {
  hotspot_active || return
  log "Connectivity present (or device claimed) — stopping setup hotspot"
  sudo -n nmcli connection down "$HOTSPOT_CONN_NAME" >>"$SITESTREAM_DIR/logs/wifi-ap.log" 2>&1 || true
}

log "SiteStream Wi-Fi ad-hoc fallback started (SSID would be: $SSID)."
while true; do
  if is_claimed || is_connected; then
    stop_hotspot
  else
    start_hotspot
  fi
  sleep "$CHECK_INTERVAL_SECONDS"
done
