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
# sync.sh handles the check-in loop automatically via its normal 15-min cron.

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
apt-get install -y -q vlc jq curl cron

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

cp "$SCRIPT_DIR/sync.sh"   "$PI_HOME/sitestream/sync.sh"
cp "$SCRIPT_DIR/player.sh" "$PI_HOME/sitestream/player.sh"
chmod +x "$PI_HOME/sitestream/sync.sh"
chmod +x "$PI_HOME/sitestream/player.sh"
chown -R "$PI_USER:$PI_GROUP" "$PI_HOME/sitestream"

# ── Cron job: sync every 15 minutes ──────────────────────────────────────────
CRON_LINE="*/15 * * * * $PI_USER $PI_HOME/sitestream/sync.sh >> $PI_HOME/sitestream/logs/sync.log 2>&1"
CRON_FILE="/etc/cron.d/sitestream-sync"
echo "$CRON_LINE" > "$CRON_FILE"
chmod 644 "$CRON_FILE"

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

[Install]
WantedBy=graphical.target
EOF

systemctl daemon-reload
systemctl enable sitestream-player.service

# ── Run an initial sync right now so the serial shows up immediately ─────────
SERIAL=$(awk -F': ' '/^Serial/ {print $2}' /proc/cpuinfo | tr -d ' \n')
sudo -u "$PI_USER" "$PI_HOME/sitestream/sync.sh" >> "$PI_HOME/sitestream/logs/sync.log" 2>&1 || true

echo ""
echo "=== Setup complete ==="
echo "Device serial: $SERIAL"
echo "Go to the SiteStream admin UI -> Devices -> Claim Device, enter that serial,"
echo "and assign it to a Zone. This Pi will pick up its token within 15 minutes"
echo "(or immediately, next time sync.sh runs)."
echo ""
echo "Reboot the Pi to start the player: sudo reboot"
echo "Logs: tail -f $PI_HOME/sitestream/logs/sync.log"
