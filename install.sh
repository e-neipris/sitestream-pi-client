#!/bin/bash
# SiteStream Pi Client — first-time setup
# Run this once on a fresh Raspberry Pi OS installation.
# Usage: sudo bash install.sh <DEVICE_TOKEN> [API_URL]
#
# DEVICE_TOKEN: the JWT token shown in the SiteStream admin UI when you register a device
# API_URL:      defaults to https://api.sitestream.app (or your self-hosted URL)

set -e

DEVICE_TOKEN="${1:-}"
API_URL="${2:-https://api.sitestream.app}"

if [ -z "$DEVICE_TOKEN" ]; then
  echo "Usage: sudo bash install.sh <DEVICE_TOKEN> [API_URL]"
  exit 1
fi

echo "=== SiteStream Pi Client Setup ==="
echo "API: $API_URL"

# ── Dependencies ──────────────────────────────────────────────────────────────
apt-get update -q
apt-get install -y -q vlc jq curl cron

# ── Directory structure ───────────────────────────────────────────────────────
mkdir -p /home/pi/sitestream/videos
mkdir -p /home/pi/sitestream/logs

# ── Write config ──────────────────────────────────────────────────────────────
cat > /home/pi/sitestream/config.env << EOF
DEVICE_TOKEN=$DEVICE_TOKEN
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

echo ""
echo "=== Setup complete ==="
echo "Reboot the Pi to start the player: sudo reboot"
echo "Logs: tail -f /home/pi/sitestream/logs/sync.log"
