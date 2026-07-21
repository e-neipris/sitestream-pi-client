#!/bin/bash
# SiteStream Pi Client — Factory Reset
#
# Restores this device to exactly the state it was in the moment install.sh
# finished — NOT a full uninstall/reinstall. install.sh's one-time setup
# (systemd units, sudoers grants, apt packages, the cron mechanism itself) is
# left completely alone; this only clears what sync.sh/player.sh/listen.sh
# have accumulated SINCE then: device token, multicast config, cached videos,
# schedule, every local state file — and resets cron back to the 1-minute
# zero-touch default new/unclaimed devices start on.
#
# Two audiences for this, same script: (1) repeatedly re-testing the
# unclaimed/onboarding flow without a full install.sh re-run, and (2) a real
# customer factory-resetting their device (reselling it, starting over,
# etc.) — devices in the field come with install.sh already baked in from
# the factory, so THIS is what "factory reset" means for them, not install.sh.
#
# IMPORTANT: this only resets the Pi. It cannot and does not un-claim the
# device server-side — the Device record stays exactly as it is in the API's
# database until an admin removes it from the portal. That's a deliberate
# boundary, not an oversight: a device being able to erase its own claim
# record on request would let anyone with physical/SSH access to a Pi
# deregister it from its owner's account. Remove it from the portal first if
# you want this serial to show up as unclaimed again afterward.
#
# Usage: bash factory-reset.sh [--yes]
#   --yes: skip the confirmation prompt (for scripted/remote use)
#
# Deliberately run as the normal Pi user, NOT via sudo — same privilege model
# as sync.sh: crontab operations need to run as the actual owning user (a
# bare `crontab -l`/`crontab -` under sudo would target root's crontab, not
# this user's, silently doing nothing useful), and the two systemctl restarts
# below reuse the exact sudoers grants install.sh already set up for
# sync.sh's own self-update restarts — no new privileges needed.

SITESTREAM_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SITESTREAM_DIR/config.env"

if [ "$1" != "--yes" ]; then
  echo "This will erase this device's claim, cached videos, and all local state —"
  echo "resetting it to look freshly installed. It will NOT un-claim it server-side;"
  echo "remove it from the portal separately first if you want this serial number"
  echo "to show up as unclaimed again afterward."
  echo ""
  read -r -p "Continue? [y/N] " confirm
  case "$confirm" in
    y|Y) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

echo "Clearing device identity and multicast config from config.env…"
if [ -f "$CONFIG" ]; then
  sed -i '/^DEVICE_TOKEN=/d; /^MULTICAST_ENABLED=/d; /^MULTICAST_ADDRESS=/d; /^MULTICAST_PORT=/d' "$CONFIG"
fi

echo "Clearing local provisioning/state files…"
rm -f "$SITESTREAM_DIR/.manifest_hash" "$SITESTREAM_DIR/.sync_interval" \
      "$SITESTREAM_DIR/.installed_version" "$SITESTREAM_DIR/schedule.json" \
      "$SITESTREAM_DIR/status.json" "$SITESTREAM_DIR/.health_urgent" \
      "$SITESTREAM_DIR/.sync.lock" "$SITESTREAM_DIR/onboarding.png"

echo "Clearing cached videos…"
rm -f "$SITESTREAM_DIR"/videos/*.mp4 "$SITESTREAM_DIR"/videos/*.etag "$SITESTREAM_DIR"/videos/*.tmp 2>/dev/null

echo "Clearing logs…"
: > "$SITESTREAM_DIR/logs/sync.log" 2>/dev/null
: > "$SITESTREAM_DIR/logs/vlc.log" 2>/dev/null
: > "$SITESTREAM_DIR/logs/vlc-multicast.log" 2>/dev/null

echo "Resetting cron to the zero-touch default (every 1 minute)…"
CRON_LINE="* * * * * $SITESTREAM_DIR/sync.sh >> $SITESTREAM_DIR/logs/sync.log 2>&1"
(crontab -l 2>/dev/null | grep -v "sitestream/sync.sh"; echo "$CRON_LINE") | crontab -

echo "Restarting player and listener services…"
sudo systemctl restart sitestream-player.service 2>/dev/null \
  || echo "WARN: could not restart sitestream-player.service"
sudo systemctl restart sitestream-listen.service 2>/dev/null \
  || echo "WARN: could not restart sitestream-listen.service"

echo ""
echo "=== Factory reset complete ==="
echo "This device will show the onboarding screen now, and check in as"
echo "unclaimed within a minute (or run 'bash sync.sh' to trigger it now)."
echo "If it still shows up as already claimed, remove its old Device record"
echo "from the portal — this script only resets the Pi, not the server."
