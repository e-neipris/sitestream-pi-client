#!/bin/bash
# SiteStream Pi Client — update an already-deployed Pi
# Pulls the latest sync.sh/player.sh from this git checkout and copies them
# into the running ~/sitestream install, then restarts the player service.
# Run this instead of manually `git pull` + `cp` + `systemctl restart`.
# Usage: sudo bash update.sh

set -e

PI_USER="${SUDO_USER:-}"
if [ -z "$PI_USER" ] || [ "$PI_USER" = "root" ]; then
  echo "ERROR: run this via sudo as your normal login user, e.g.: sudo bash update.sh"
  exit 1
fi
PI_HOME=$(getent passwd "$PI_USER" | cut -d: -f6)
PI_GROUP=$(id -gn "$PI_USER")

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -d "$PI_HOME/sitestream" ]; then
  echo "ERROR: $PI_HOME/sitestream doesn't exist — run install.sh first, not update.sh."
  exit 1
fi

echo "Pulling latest from $SCRIPT_DIR…"
sudo -u "$PI_USER" git -C "$SCRIPT_DIR" pull

echo "Copying sync.sh and player.sh into $PI_HOME/sitestream…"
cp "$SCRIPT_DIR/sync.sh" "$PI_HOME/sitestream/sync.sh"
cp "$SCRIPT_DIR/player.sh" "$PI_HOME/sitestream/player.sh"
chmod +x "$PI_HOME/sitestream/sync.sh" "$PI_HOME/sitestream/player.sh"
chown "$PI_USER:$PI_GROUP" "$PI_HOME/sitestream/sync.sh" "$PI_HOME/sitestream/player.sh"

echo "Restarting sitestream-player.service…"
systemctl restart sitestream-player.service

echo ""
echo "Done. player.sh is running the updated code now."
echo "sync.sh will pick up changes on its next cron run — or run it now manually:"
echo "  sudo -u $PI_USER $PI_HOME/sitestream/sync.sh"
