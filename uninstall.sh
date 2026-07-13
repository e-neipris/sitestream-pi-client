#!/bin/bash
# SiteStream Pi Client — uninstall
# Reverses everything install.sh set up, so the Pi is back to a clean state.
# Usage: sudo bash uninstall.sh [--purge-packages]
#
# --purge-packages: also apt-get remove vlc/jq/curl/cron, the packages
#                    install.sh installed. Off by default — these are common
#                    Raspberry Pi OS utilities other things on the box may
#                    already depend on (cron in particular), so removing them
#                    is opt-in rather than automatic.

set -e

PURGE_PACKAGES=false
[ "$1" = "--purge-packages" ] && PURGE_PACKAGES=true

# ── Figure out whose home directory this was installed into ──────────────────
# Same detection install.sh uses — modern Raspberry Pi OS has no default "pi"
# user, so this must match whoever install.sh actually ran as, not a hardcoded
# "pi". Falls back to the deprecated /home/pi path for setups from before this
# fix, so old installs can still be cleaned up.
PI_USER="${SUDO_USER:-}"
if [ -n "$PI_USER" ] && [ "$PI_USER" != "root" ]; then
  PI_HOME=$(getent passwd "$PI_USER" | cut -d: -f6)
fi
PI_HOME="${PI_HOME:-/home/pi}"

echo "=== SiteStream Pi Client Uninstall ==="
echo "Target: $PI_HOME/sitestream"

# ── Stop and remove the player service ────────────────────────────────────────
if systemctl list-unit-files 2>/dev/null | grep -q '^sitestream-player.service'; then
  echo "Stopping sitestream-player.service…"
  systemctl stop sitestream-player.service 2>/dev/null || true
  systemctl disable sitestream-player.service 2>/dev/null || true
fi
rm -f /etc/systemd/system/sitestream-player.service
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

# Safety net in case VLC is running outside systemd's tracking (e.g. player.sh
# was started by hand rather than via the service)
pkill -f "vlc .*--fullscreen" 2>/dev/null || true

# ── Remove the Wi-Fi power-save-off unit ──────────────────────────────────────
if systemctl list-unit-files 2>/dev/null | grep -q '^wifi-powersave-off.service'; then
  echo "Removing wifi-powersave-off.service…"
  systemctl disable wifi-powersave-off.service 2>/dev/null || true
fi
rm -f /etc/systemd/system/wifi-powersave-off.service
systemctl daemon-reload

# ── Remove cron job ────────────────────────────────────────────────────────────
echo "Removing cron job…"
rm -f /etc/cron.d/sitestream-sync

# ── Remove runtime directory (config, cached videos, logs, schedule state) ───
echo "Removing $PI_HOME/sitestream (config, cached videos, logs)…"
rm -rf "$PI_HOME/sitestream"

# ── Optionally remove packages install.sh installed ───────────────────────────
if [ "$PURGE_PACKAGES" = true ]; then
  echo "Removing packages: vlc jq curl cron…"
  apt-get remove -y -q vlc jq curl cron
  apt-get autoremove -y -q
else
  echo "Leaving vlc/jq/curl/cron installed (common system utilities — pass --purge-packages to also remove them)."
fi

echo ""
echo "=== Uninstall complete ==="
echo "This Pi no longer syncs or plays anything for SiteStream."
echo ""
echo "Note: this only cleans up the device itself. The Device record in the"
echo "admin UI (with its serial number / token) is untouched — remove it there"
echo "too (Devices page -> Remove) if you don't want it claimable again as-is."
echo ""
echo "If you cloned the source repo to set this up (e.g. $PI_HOME/sitestream-src),"
echo "this script is running from inside it, so remove it yourself once this exits:"
echo "  rm -rf $PI_HOME/sitestream-src"
