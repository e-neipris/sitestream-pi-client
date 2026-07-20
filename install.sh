#!/bin/bash
# SiteStream Pi Client — first-time setup
# Run this once on a fresh Raspberry Pi OS installation.
# Usage: sudo bash install.sh [API_URL]
#
# API_URL: defaults to https://api.sitestream.app (or your self-hosted URL)
#
# No device token needed here — this Pi identifies itself to the API by its
# hardware serial number and waits to be claimed in the admin UI (Devices page,
# "Claim Device" — enter the serial printed on this unit, pick a Zone, done).
# sync.sh handles the check-in loop automatically via its normal 1-min cron.

set -e

API_URL="${1:-https://api.sitestream.app}"

# ── Figure out who this actually installs for ─────────────────────────────────
# Modern Raspberry Pi OS (Bullseye+) doesn't create a default "pi" user — you
# pick your own username during imaging. Use whoever invoked sudo, not a
# hardcoded "pi", since that's also the account whose desktop/X session VLC
# needs to render into.
PI_USER="${SUDO_USER:-}"
if [ -z "$PI_USER" ] || [ "$PI_USER" = "root" ]; then
  echo "ERROR: could not determine which user to install for."
  echo "Run this via sudo as your normal login user, e.g.: sudo bash install.sh"
  exit 1
fi

PI_HOME=$(getent passwd "$PI_USER" | cut -d: -f6)
if [ -z "$PI_HOME" ] || [ ! -d "$PI_HOME" ]; then
  echo "ERROR: could not resolve a home directory for user '$PI_USER'."
  exit 1
fi
PI_GROUP=$(id -gn "$PI_USER")

echo "=== SiteStream Pi Client Setup ==="
echo "API: $API_URL"
echo "Installing for user: $PI_USER ($PI_HOME)"

# ── Dependencies ──────────────────────────────────────────────────────────────
apt-get update -q
apt-get install -y -q vlc jq curl cron logrotate

# ── Directory structure ───────────────────────────────────────────────────────
mkdir -p "$PI_HOME/sitestream/videos"
mkdir -p "$PI_HOME/sitestream/logs"

# ── Write config (no DEVICE_TOKEN yet — sync.sh provisions it on first run) ──
cat > "$PI_HOME/sitestream/config.env" << EOF
API_URL=$API_URL
VIDEO_DIR=$PI_HOME/sitestream/videos
LOG_FILE=$PI_HOME/sitestream/logs/sync.log
EOF

chmod 600 "$PI_HOME/sitestream/config.env"

# ── Install scripts ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

cp "$SCRIPT_DIR/sync.sh"    "$PI_HOME/sitestream/sync.sh"
cp "$SCRIPT_DIR/player.sh"  "$PI_HOME/sitestream/player.sh"
cp "$SCRIPT_DIR/listen.sh"  "$PI_HOME/sitestream/listen.sh"
cp "$SCRIPT_DIR/install.sh" "$PI_HOME/sitestream/install.sh"
chmod +x "$PI_HOME/sitestream/sync.sh"
chmod +x "$PI_HOME/sitestream/player.sh"
chmod +x "$PI_HOME/sitestream/listen.sh"
chmod +x "$PI_HOME/sitestream/install.sh"
chown -R "$PI_USER:$PI_GROUP" "$PI_HOME/sitestream"

# ── Log rotation ───────────────────────────────────────────────────────────────
# sync.log (cron-appended, now every minute) and vlc.log (held open by VLC for
# the life of the process) both grow unbounded otherwise. copytruncate is
# required, not just convenient — VLC never reopens its log file, so a normal
# rename-based rotation would leave it writing forever into a renamed (or
# deleted) file while the real path stays empty. copytruncate truncates the
# same inode VLC already has open instead, so it needs no cooperation from VLC
# and playback is never interrupted. Verified in a throwaway container: a
# process holding the file open across a forced rotation kept writing
# successfully into the truncated file with the same inode.
cat > /etc/logrotate.d/sitestream << EOF
$PI_HOME/sitestream/logs/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    maxsize 20M
}
EOF

# ── Cron job: sync.sh polls the manifest on a schedule (sync.sh is overlap-
# safe via flock). Starts at 1 minute so zero-touch claiming stays snappy —
# a not-yet-claimed device has no zone yet, so there's nothing to configure
# an interval from. Once claimed, sync.sh transitions itself to whatever
# interval the zone specifies (Zone Configuration tab, default 15 min).
#
# Uses $PI_USER's own crontab, not /etc/cron.d/. sync.sh runs unprivileged as
# $PI_USER and needs to be able to rewrite this itself when the configured
# interval changes — a user's own crontab entries can only ever run as that
# user, whereas /etc/cron.d/ entries carry their own user field per line, so
# granting an unprivileged process write access there would be a straight
# path to root if sync.sh were ever compromised.
rm -f /etc/cron.d/sitestream-sync  # clean up the old mechanism, in case install.sh is being re-run
CRON_LINE="* * * * * $PI_HOME/sitestream/sync.sh >> $PI_HOME/sitestream/logs/sync.log 2>&1"
(crontab -u "$PI_USER" -l 2>/dev/null | grep -v "sitestream/sync.sh"; echo "$CRON_LINE") | crontab -u "$PI_USER" -

# ── Autostart VLC via systemd service ─────────────────────────────────────────
# Safe to enable even before claiming — player.sh just idles with nothing to
# play until sync.sh has been claimed and produces a real schedule.json.
cat > /etc/systemd/system/sitestream-player.service << EOF
[Unit]
Description=SiteStream Video Player
After=graphical.target

[Service]
User=$PI_USER
Environment=DISPLAY=:0
ExecStart=$PI_HOME/sitestream/player.sh
Restart=always
RestartSec=5
# Default KillMode (control-group) sends SIGTERM to player.sh AND its child
# VLC process(es) simultaneously on every stop/restart — uncoordinated with
# player.sh's own trap-driven stop_vlc/stop_multicast sequence, and the
# direct hit to VLC's Qt event loop is what caused slow restarts and the
# "QObject::~QObject: Timers cannot be stopped from another thread" warning
# after a pushed self-update. KillMode=process signals only this process;
# player.sh's trap handles stopping VLC/multicast itself, in order.
KillMode=process
# Also a safety net independent of the above: default is 90s before SIGKILL.
TimeoutStopSec=15

[Install]
WantedBy=graphical.target
EOF

systemctl daemon-reload
systemctl enable sitestream-player.service

# ── Realtime push listener via systemd service ────────────────────────────────
# Holds an SSE connection open to the API so schedule/firmware/reboot/zone
# changes reach this device within seconds instead of waiting for sync.sh's
# next cron tick — see listen.sh for the full design. Runs unprivileged as
# $PI_USER (same as the cron job), needs no sudo grants of its own: it only
# ever invokes sync.sh directly, which already has whatever privileges it
# needs. Safe to enable even before claiming — it just waits for a
# DEVICE_TOKEN to show up in config.env.
cat > /etc/systemd/system/sitestream-listen.service << EOF
[Unit]
Description=SiteStream Realtime Push Listener
After=network-online.target
Wants=network-online.target

[Service]
User=$PI_USER
ExecStart=$PI_HOME/sitestream/listen.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sitestream-listen.service
systemctl start sitestream-listen.service

# ── Sudo grants: let sync.sh restart the player/listener services after a
# self-update, and reboot the device on admin request — each scoped to
# exactly one command via sudoers.d, not blanket sudo access. sync.sh runs as
# $PI_USER, not root (see the cron job below), so without this it can't do
# any of them: the Pi would keep running old code until its next natural
# reboot, and the admin-panel Reboot button would have no way to actually
# reboot it.
SYSTEMCTL_BIN="$(command -v systemctl)"
cat > /etc/sudoers.d/sitestream << EOF
$PI_USER ALL=(root) NOPASSWD: $SYSTEMCTL_BIN restart sitestream-player.service
$PI_USER ALL=(root) NOPASSWD: $SYSTEMCTL_BIN restart sitestream-listen.service
$PI_USER ALL=(root) NOPASSWD: $SYSTEMCTL_BIN reboot
EOF
chmod 440 /etc/sudoers.d/sitestream
if ! visudo -c -f /etc/sudoers.d/sitestream >/dev/null 2>&1; then
  echo "ERROR: generated sudoers rules failed validation — removing them. Self-update and the admin-panel Reboot button won't work until this is fixed."
  rm -f /etc/sudoers.d/sitestream
fi

# ── Disable Wi-Fi power management ────────────────────────────────────────────
# The Pi's Wi-Fi chip periodically drops into a power-save state that kills
# sustained long-lived connections — observed cutting video downloads after
# roughly 90-150s regardless of progress, which is fatal for large files over
# Wi-Fi. A one-off `iw` command doesn't survive reboots (dhcpcd/NetworkManager
# reset it when the interface comes up), so this runs on every boot instead.
# No-op if this Pi has no wlan0 (e.g. wired Ethernet only).
if command -v iw >/dev/null 2>&1 && iw dev wlan0 info >/dev/null 2>&1; then
  IW_BIN="$(command -v iw)"
  iw dev wlan0 set power_save off || true

  cat > /etc/systemd/system/wifi-powersave-off.service << EOF
[Unit]
Description=Disable Wi-Fi power management (prevents dropped downloads)
After=network.target

[Service]
Type=oneshot
ExecStart=$IW_BIN dev wlan0 set power_save off

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable wifi-powersave-off.service
  systemctl start wifi-powersave-off.service
fi

# ── Run an initial sync right now so the serial shows up immediately ─────────
SERIAL=$(awk -F': ' '/^Serial/ {print $2}' /proc/cpuinfo | tr -d ' \n')
# The redirect must happen INSIDE the sudo'd shell, not the outer (root) one —
# otherwise the log file gets created/owned by root, and every subsequent
# cron-fired run (which executes purely as $PI_USER) silently fails to append
# to it, so sync.sh never actually runs again after this first call.
sudo -u "$PI_USER" bash -c "'$PI_HOME/sitestream/sync.sh' >> '$PI_HOME/sitestream/logs/sync.log' 2>&1" || true

echo ""
echo "=== Setup complete ==="
echo "Device serial: $SERIAL"
echo "Go to the SiteStream admin UI -> Devices -> Claim Device, enter that serial,"
echo "and assign it to a Zone. This Pi will pick up its token within 15 minutes"
echo "(or immediately, next time sync.sh runs)."
echo ""
echo "Reboot the Pi to start the player: sudo reboot"
echo "Logs: tail -f $PI_HOME/sitestream/logs/sync.log"
