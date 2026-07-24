#!/bin/bash
# SiteStream Pi Client — Wi-Fi Ad-Hoc Setup Fallback
# Runs continuously as a systemd service. Manages the setup hotspot in TWO
# distinct scenarios:
#
#   1. Never configured at all: no network connectivity and no saved Wi-Fi
#      profile exists yet — broadcasts the hotspot so an installer's
#      phone/laptop can join and reach the standalone portal
#      (http://<hotspot-gateway-ip>:8080) to claim/configure this device.
#
#   2. Configured but unreachable ("rescue mode"): a Wi-Fi profile IS saved
#      (portal Join, or cloud-pushed credentials) but hasn't actually been
#      able to connect for a while — wrong/changed password, device moved
#      to a new site, router replaced, etc. Confirmed live: a device stuck
#      here previously just sat there forever with no hotspot and a stale
#      screen, because `is_claimed` alone used to suppress the hotspot
#      regardless of whether the device could actually reach anything —
#      leaving no recovery path short of physical/Ethernet access. Rescue
#      mode fixes that: it broadcasts the hotspot AND retries the saved
#      network on its own schedule (RETRY_INTERVAL_SECONDS below), so
#      whoever set it up can reconnect via the hotspot and fix the
#      password/SSID without needing anything else.
#
# generate-wifi-rescue-screen.sh (driven by player.sh) reads the state file
# this script writes below to show the right message on the physical
# display — see write_rescue_state/clear_rescue_state.
#
# Requires NetworkManager (Raspberry Pi OS Bookworm/Trixie's default, and
# what this repo's own test hardware runs) — `nmcli device wifi hotspot` is
# a one-command AP+DHCP setup. A Bullseye image on dhcpcd+wpa_supplicant has
# no equivalent here; this script detects that and simply exits rather than
# pretending to work.
#
# IMPORTANT hardware limitation, not a bug: a single Wi-Fi radio can only be
# an access point OR a connected client at once, never both. Rescue mode's
# own retry (below) briefly drops the hotspot to attempt the real network,
# same as any other client-connect attempt would.

set -u

SITESTREAM_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SITESTREAM_DIR/config.env"
LOG_PREFIX="[WIFI-AP $(date '+%H:%M:%S')]"
HOTSPOT_CONN_NAME="SiteStream-Setup"
CHECK_INTERVAL_SECONDS=30

# How long wlan0 may sit in any non-"fully connected" state (still trying,
# flapping, or outright failed — the grace period doesn't care which) while
# a Wi-Fi profile IS configured before this is treated as a persistent
# failure rather than a normal in-progress connection attempt. 90s is a few
# multiples of a normal join's actual connect time, so a fresh/legitimate
# attempt is never mistaken for a stuck one.
FAILURE_GRACE_SECONDS=90

# Requested cadence: retry the configured network every 5 minutes while in
# rescue mode, rather than leaving it to NetworkManager's own autoconnect
# retry loop — confirmed live that letting NM keep retrying on its own
# caused a rapid, disruptive flap between "briefly trying wlan0 as a
# client" and "hotspot up," instead of a predictable, controllable cadence.
RETRY_INTERVAL_SECONDS=300

STRUGGLING_SINCE_FILE="$SITESTREAM_DIR/.wifi_struggling_since"
RESCUE_STATE_FILE="$SITESTREAM_DIR/.wifi_rescue_state"
LAST_RETRY_FILE="$SITESTREAM_DIR/.wifi_rescue_last_retry"

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

is_claimed() {
  [ -f "$CONFIG" ] && source "$CONFIG"
  [ -n "${DEVICE_TOKEN:-}" ]
}

# Any saved 802-11-wireless connection profile other than our own setup
# hotspot means this device has been told to join a specific network
# (portal Join, or cloud-pushed WIFI_SSID/WIFI_PASSWORD) — independent of
# whether that network is currently reachable. Prints the first match.
configured_wifi_profile() {
  nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: -v hotspot="$HOTSPOT_CONN_NAME" \
    '$2 == "802-11-wireless" && $1 != hotspot { print $1; exit }'
}

wifi_profile_configured() {
  [ -n "$(configured_wifi_profile)" ]
}

# True only once wlan0 is FULLY connected (state 100) to a real client
# network of its own — not merely "attempting" (any of NetworkManager's
# in-progress states), and not our own hotspot (broadcasting an AP also
# reads as device state 100/connected, so the state code alone can't tell
# the two apart).
wlan0_fully_connected() {
  local code active
  code=$(nmcli -t -f GENERAL.STATE device show wlan0 2>/dev/null | cut -d: -f2 | grep -o '^[0-9]*')
  [ "$code" = "100" ] || return 1
  active=$(nmcli -t -f GENERAL.CONNECTION device show wlan0 2>/dev/null | cut -d: -f2-)
  [ "$active" != "$HOTSPOT_CONN_NAME" ]
}

# Ethernet has no hotspot-name ambiguity to worry about, so the original
# "busy or connected" (state 40-100) range is still the right check — a
# device already fully reachable over a wired connection, or actively
# getting a DHCP lease, has no need for the WiFi setup hotspot either.
eth0_connected() {
  local code
  code=$(nmcli -t -f GENERAL.STATE device show eth0 2>/dev/null | cut -d: -f2 | grep -o '^[0-9]*')
  [ -n "$code" ] && [ "$code" -ge 40 ] && [ "$code" -le 100 ]
}

hotspot_active() {
  nmcli -t -f NAME connection show --active 2>/dev/null | grep -qx "$HOTSPOT_CONN_NAME"
}

start_hotspot() {
  hotspot_active && return
  log "Starting setup hotspot '$SSID'"
  # A freshly-imaged Raspberry Pi OS install can leave the Wi-Fi radio
  # itself soft-disabled at the NetworkManager level (nmcli radio -> WIFI:
  # disabled), independent of the wlan0 hardware/driver being fine. When
  # that's the case `nmcli device wifi hotspot` fails every single time with
  # "device is not available" and never recovers on its own — confirmed live
  # against a brand-new Pi where this was the entire root cause of the
  # hotspot never appearing. Idempotent/harmless if the radio is already on.
  sudo -n nmcli radio wifi on >>"$SITESTREAM_DIR/logs/wifi-ap.log" 2>&1 || true
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
  log "Stopping setup hotspot — real connectivity available"
  sudo -n nmcli connection down "$HOTSPOT_CONN_NAME" >>"$SITESTREAM_DIR/logs/wifi-ap.log" 2>&1 || true
}

# Rescue mode disables autoconnect on the configured profile(s) so
# NetworkManager stops fighting the hotspot for the radio between this
# script's own deliberate retries (see the RETRY_INTERVAL_SECONDS comment
# above for why that fight was happening). Re-enabled the moment real
# connectivity is confirmed, or the profile is gone (a fresh portal Join
# deletes-and-recreates rather than reusing it — see system.ts's
# forgetExistingProfile — so a new profile always starts back at the
# NetworkManager default of autoconnect=yes regardless of this).
set_configured_profiles_autoconnect() {
  local value="$1" name
  nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: -v hotspot="$HOTSPOT_CONN_NAME" \
    '$2 == "802-11-wireless" && $1 != hotspot { print $1 }' | while IFS= read -r name; do
    sudo -n nmcli connection modify "$name" connection.autoconnect "$value" >>"$SITESTREAM_DIR/logs/wifi-ap.log" 2>&1
  done
}

write_rescue_state() {
  printf 'SSID=%s\nSINCE=%s\n' "$1" "$2" > "$RESCUE_STATE_FILE"
}

clear_rescue_state() {
  rm -f "$RESCUE_STATE_FILE" "$LAST_RETRY_FILE" "$STRUGGLING_SINCE_FILE"
}

log "SiteStream Wi-Fi ad-hoc fallback started (SSID would be: $SSID)."
while true; do
  if eth0_connected || wlan0_fully_connected; then
    stop_hotspot
    if [ -f "$RESCUE_STATE_FILE" ]; then
      log "Configured Wi-Fi network reachable again — leaving rescue mode"
      set_configured_profiles_autoconnect yes
    fi
    clear_rescue_state

  elif wifi_profile_configured; then
    now=$(date +%s)
    [ -f "$STRUGGLING_SINCE_FILE" ] || date +%s > "$STRUGGLING_SINCE_FILE"
    since=$(cat "$STRUGGLING_SINCE_FILE" 2>/dev/null || echo "$now")

    if [ $((now - since)) -lt "$FAILURE_GRACE_SECONDS" ]; then
      # Still within the grace period — this may just be a fresh connection
      # attempt in progress (or a brief blip). Don't touch the hotspot or
      # the profile yet; give it time to succeed on its own.
      :
    else
      profile=$(configured_wifi_profile)
      if [ ! -f "$RESCUE_STATE_FILE" ]; then
        write_rescue_state "$profile" "$now"
        set_configured_profiles_autoconnect no
        log "Configured Wi-Fi network ('$profile') unreachable for over ${FAILURE_GRACE_SECONDS}s — entering rescue mode: hotspot + retry every $((RETRY_INTERVAL_SECONDS / 60)) min"
      fi

      last_retry=$(cat "$LAST_RETRY_FILE" 2>/dev/null || echo 0)
      if [ $((now - last_retry)) -ge "$RETRY_INTERVAL_SECONDS" ]; then
        echo "$now" > "$LAST_RETRY_FILE"
        log "Rescue mode: retrying '$profile'…"
        stop_hotspot
        if [ -n "$profile" ] && sudo -n nmcli connection up "$profile" >>"$SITESTREAM_DIR/logs/wifi-ap.log" 2>&1; then
          log "Reconnected to '$profile' — leaving rescue mode"
          set_configured_profiles_autoconnect yes
          clear_rescue_state
        else
          log "Retry failed — resuming setup hotspot, next retry in $((RETRY_INTERVAL_SECONDS / 60)) min"
          start_hotspot
        fi
      else
        start_hotspot
      fi
    fi

  else
    # No configured Wi-Fi profile at all — the original "never set up"
    # case, unrelated to rescue mode.
    rm -f "$STRUGGLING_SINCE_FILE"
    if is_claimed; then
      # Claimed with no Wi-Fi profile at all (e.g. Ethernet-only site, or
      # the profile was deliberately removed) — nothing a Wi-Fi hotspot can
      # fix, so leave it alone rather than broadcasting pointlessly.
      stop_hotspot
    else
      start_hotspot
    fi
  fi

  sleep "$CHECK_INTERVAL_SECONDS"
done
