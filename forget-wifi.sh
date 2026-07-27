#!/bin/bash
# SiteStream Pi Client — Forget Wi-Fi Network(s)
#
# Deletes every saved 802-11-wireless NetworkManager connection profile on
# this device except its own ad-hoc setup hotspot. Split out of
# factory-reset.sh into its own script so sync.sh's remote-triggered factory
# reset flow can defer THIS specific step until after it has confirmed
# completion to the API — see sync.sh's factory-reset handling for why: this
# step, by design, severs whatever network connection is currently active
# (that's the entire point of forgetting the network), and running it before
# the API confirm call meant that same success silently broke the very
# connection the confirm call needed to reach the API over. Confirmed live:
# a factory reset with --forget-wifi genuinely dropped the device's Wi-Fi (as
# intended) but the device never got released server-side, because the
# confirm call that ran right after it had no network left to reach the API
# with.
#
# Standalone factory-reset.sh --forget-wifi still calls this in the same
# single run (a human resetting a device by hand has no API confirm call to
# race against) — this file has no behavior of its own beyond what it did
# inline before; it's an extraction, not a new feature.
#
# Usage: bash forget-wifi.sh

set -u

HOTSPOT_CONN_NAME="SiteStream-Setup"

if ! command -v nmcli >/dev/null 2>&1; then
  echo "nmcli not present — nothing to forget."
  exit 0
fi

echo "Forgetting saved Wi-Fi network(s)…"
while IFS=: read -r conn_name conn_type; do
  # nmcli connection show's TYPE column uses NetworkManager's internal
  # settings-type names (802-11-wireless, 802-3-ethernet, ...), NOT the
  # generic "wifi"/"ethernet" nmcli device show uses — confirmed live
  # against a real device that "wifi" here never matched anything, so this
  # loop silently deleted nothing at all, every single time, regardless of
  # the sudo fix below. That's why forget-wifi never actually worked, the
  # first time this bug was chased down.
  [ "$conn_type" = "802-11-wireless" ] || continue
  [ "$conn_name" = "$HOTSPOT_CONN_NAME" ] && continue
  # sudo -n, not a plain call — confirmed live that deleting a
  # NetworkManager connection profile from a non-interactive systemd service
  # context (no logind session) hits the same polkit permission denial
  # wifi-ap-fallback.sh's own nmcli calls already had to route around.
  # Without this, the delete silently failed every time (the || WARN below
  # swallowed it into a log nobody was watching in real time). Needs the
  # matching sudoers grant for `nmcli connection delete` specifically — see
  # install.sh.
  sudo -n nmcli connection delete "$conn_name" >/dev/null 2>&1 \
    || echo "WARN: could not delete Wi-Fi connection '$conn_name'"
done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null)
