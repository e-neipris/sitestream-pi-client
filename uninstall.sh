#!/bin/bash
# SiteStream Pi Client — uninstall
# Reverses everything install.sh set up, so the Pi is back to exactly the
# state it was in before install.sh ever ran.
# Usage: sudo bash uninstall.sh [--purge-all-packages]
#
# By default, removes only the packages install.sh actually installed on
# this specific Pi — recorded at install time in .packages_added_by_install,
# since some of these (curl, cron especially) are very likely already on a
# stock Raspberry Pi OS image. Blindly removing the whole list regardless of
# origin wouldn't restore the prior state, it would go BELOW it — uninstalling
# things that predate SiteStream entirely.
#
# --purge-all-packages: remove the FULL package list (vlc jq curl cron
#                        logrotate qrencode imagemagick fonts-dejavu-core
#                        nodejs npm) regardless of whether they pre-date
#                        this install — for when you genuinely want them
#                        gone either way.

set -e

PURGE_ALL_PACKAGES=false
[ "$1" = "--purge-all-packages" ] && PURGE_ALL_PACKAGES=true

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

# Read BEFORE anything below deletes the directory this file lives in — see
# install.sh for how/why this is recorded. Missing entirely (an install from
# before this file existed) just means "nothing to remove," the safe default.
PACKAGES_ADDED_BY_INSTALL=$(cat "$PI_HOME/sitestream/.packages_added_by_install" 2>/dev/null || echo "")

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

# ── Stop and remove the realtime push listener service ────────────────────────
if systemctl list-unit-files 2>/dev/null | grep -q '^sitestream-listen.service'; then
  echo "Stopping sitestream-listen.service…"
  systemctl stop sitestream-listen.service 2>/dev/null || true
  systemctl disable sitestream-listen.service 2>/dev/null || true
fi
rm -f /etc/systemd/system/sitestream-listen.service
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

# ── Stop and remove the standalone-mode local portal service ──────────────────
if systemctl list-unit-files 2>/dev/null | grep -q '^sitestream-portal.service'; then
  echo "Stopping sitestream-portal.service…"
  systemctl stop sitestream-portal.service 2>/dev/null || true
  systemctl disable sitestream-portal.service 2>/dev/null || true
fi
rm -f /etc/systemd/system/sitestream-portal.service
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

# ── Stop and remove the Wi-Fi ad-hoc setup fallback service ───────────────────
if systemctl list-unit-files 2>/dev/null | grep -q '^sitestream-wifi-ap.service'; then
  echo "Stopping sitestream-wifi-ap.service…"
  systemctl stop sitestream-wifi-ap.service 2>/dev/null || true
  systemctl disable sitestream-wifi-ap.service 2>/dev/null || true
fi
rm -f /etc/systemd/system/sitestream-wifi-ap.service
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true
# In case a setup hotspot happened to be active — leaving it running after
# uninstall would be a stray open Wi-Fi network broadcasting indefinitely.
nmcli connection down SiteStream-Setup >/dev/null 2>&1 || true

# listen.sh spawns sync.sh as a backgrounded child whenever it reacts to a
# push (see trigger_sync() in listen.sh) — `systemctl stop` above only
# signals the main listen.sh process (KillMode=process, same reasoning as
# install.sh), so a sync.sh that happened to be mid-run survives that. A full
# uninstall is a much more final action than a routine restart, so clean any
# of those up directly rather than leaving them to finish into a directory
# that's about to be deleted out from under them.
pkill -f "sitestream/sync.sh" 2>/dev/null || true

# ── Restore desktop boot mode ──────────────────────────────────────────────────
# install.sh switches to Console Autologin + disables lightdm so VLC's own
# DRM output isn't fighting a desktop session for the display plane. B4
# (Desktop Autologin) is the stock Raspberry Pi OS default for basically every
# general-purpose image — reasonable to restore unconditionally rather than
# tracking whatever the prior setting was, same tradeoff already accepted for
# the package list below.
if command -v raspi-config >/dev/null 2>&1; then
  raspi-config nonint do_boot_behaviour B4 || true
fi
systemctl enable lightdm 2>/dev/null || true

# consoleblank=0 was appended as a single token to cmdline.txt by install.sh —
# safe to remove as long as nothing else on the line depends on it (it never
# takes a value, so there's nothing for a neighboring option to have merged
# with).
for candidate in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
  [ -f "$candidate" ] && sed -i 's/ consoleblank=0//' "$candidate"
done

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
if [ -n "$PI_USER" ] && [ "$PI_USER" != "root" ]; then
  (crontab -u "$PI_USER" -l 2>/dev/null | grep -v "sitestream/sync.sh") | crontab -u "$PI_USER" - 2>/dev/null || true
fi

# ── Remove sudoers grant ───────────────────────────────────────────────────────
# install.sh's scoped NOPASSWD grants (restart player/listener, reboot) —
# leaving this behind after uninstall is a stale passwordless-root grant for
# services that no longer exist.
echo "Removing sudoers grant…"
rm -f /etc/sudoers.d/sitestream

# ── Remove log rotation config ─────────────────────────────────────────────────
echo "Removing logrotate config…"
rm -f /etc/logrotate.d/sitestream

# ── Remove runtime directory (config, cached videos, logs, schedule state) ───
echo "Removing $PI_HOME/sitestream (config, cached videos, logs)…"
rm -rf "$PI_HOME/sitestream"

# ── Remove packages — exactly what install.sh added, by default ───────────────
if [ "$PURGE_ALL_PACKAGES" = true ]; then
  echo "Removing packages: vlc jq curl cron logrotate qrencode imagemagick fonts-dejavu-core nodejs npm (forced, regardless of origin)…"
  apt-get remove -y -q vlc jq curl cron logrotate qrencode imagemagick fonts-dejavu-core nodejs npm
  apt-get autoremove -y -q
elif [ -n "$PACKAGES_ADDED_BY_INSTALL" ]; then
  echo "Removing packages install.sh added on this Pi:$PACKAGES_ADDED_BY_INSTALL…"
  apt-get remove -y -q $PACKAGES_ADDED_BY_INSTALL
  apt-get autoremove -y -q
else
  echo "No packages to remove — everything install.sh depends on was already present before it ran"
  echo "(or this install predates package tracking; pass --purge-all-packages to remove the full list anyway)."
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
