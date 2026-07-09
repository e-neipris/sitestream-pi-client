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

echo "=== SiteStream Pi Client Setup ==="
echo "API: $API_URL"

# ── Dependencies ──────────────────────────────────────────────────────────────
apt-get update -q
apt-get install -y -q vlc jq curl cron

# ── Directory structure ───────────────────────────────────────────────────────
mkdir -p /home/pi/sitestream/videos
mkdir -p /home/pi/sitestream/logs

# ── Write config (no DEVICE_TOKEN yet — sync.sh provisions it on first run) ──
cat > /home/pi/sitestream/config.env << EOF
API_URL=$API_URL
VIDEO_DIR=/home/pi/sitestream/videos
LOG_FILE=/home/pi/sitestream/logs/sync.log
EOF

chmod 600 /home/pi/sitestream/config.env

# ── Install scripts ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

cp "$SCRIPT_DIR/sync.sh"   /home/pi/sitestream/sync.sh
cp "$SCRIPT_DIR/player.sh" /home/pi/sitestream/player.sh
chmod +x /home/pi/sitestream/sync.sh
chmod +x /home/pi/sitestream/player.sh
chown -R pi:pi /home/pi/sitestream

# ── Cron job: sync every 15 minutes ──────────────────────────────────────────
CRON_LINE="*/15 * * * * pi /home/pi/sitestream/sync.sh >> /home/pi/sitestream/logs/sync.log 2>&1"
CRON_FILE="/etc/cron.d/sitestream-sync"
echo "$CRON_LINE" > "$CRON_FILE"
chmod 644 "$CRON_FILE"

# ── Autostart VLC via systemd service ─────────────────────────────────────────
# Safe to enable even before claiming — player.sh just idles with nothing to
# play until sync.sh has been claimed and produces a real schedule.json.
cat > /etc/systemd/system/sitestream-player.service << 'EOF'
[Unit]
Description=SiteStream Video Player
After=graphical.target

[Service]
User=pi
Environment=DISPLAY=:0
ExecStart=/home/pi/sitestream/player.sh
Restart=always
RestartSec=5

[Install]
WantedBy=graphical.target
EOF

systemctl daemon-reload
systemctl enable sitestream-player.service

# ── Run an initial sync right now so the serial shows up immediately ─────────
SERIAL=$(awk -F': ' '/^Serial/ {print $2}' /proc/cpuinfo | tr -d ' \n')
sudo -u pi /home/pi/sitestream/sync.sh >> /home/pi/sitestream/logs/sync.log 2>&1 || true

echo ""
echo "=== Setup complete ==="
echo "Device serial: $SERIAL"
echo "Go to the SiteStream admin UI -> Devices -> Claim Device, enter that serial,"
echo "and assign it to a Zone. This Pi will pick up its token within 15 minutes"
echo "(or immediately, next time sync.sh runs)."
echo ""
echo "Reboot the Pi to start the player: sudo reboot"
echo "Logs: tail -f /home/pi/sitestream/logs/sync.log"
