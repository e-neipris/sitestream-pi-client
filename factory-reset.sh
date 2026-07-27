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
# Usage: bash factory-reset.sh [--yes] [--forget-wifi]
#   --yes:         skip the confirmation prompt (for scripted/remote use)
#   --forget-wifi: ALSO delete this device's saved Wi-Fi network(s) — see
#                  forget_wifi_networks below. Off by default: a factory
#                  reset that silently dropped a device off its network
#                  would leave it unreachable (no portal, no check-in) until
#                  someone got physical access again, which is a worse
#                  outcome than the previous owner's SSID staying joined.
#                  Opt-in so whoever triggers this (in person, or the
#                  SaaS admin panel — see sync.sh's FACTORY_RESET_REQUESTED)
#                  can choose based on which risk matters more for a given
#                  device: reselling it (forget it) vs. a routine
#                  reset-and-recover on a device staying at the same site
#                  (keep it, so it comes right back up on its own network).
#
# Deliberately run as the normal Pi user, NOT via sudo — same privilege model
# as sync.sh: crontab operations need to run as the actual owning user (a
# bare `crontab -l`/`crontab -` under sudo would target root's crontab, not
# this user's, silently doing nothing useful), and the two systemctl restarts
# below reuse the exact sudoers grants install.sh already set up for
# sync.sh's own self-update restarts — no new privileges needed.

SITESTREAM_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SITESTREAM_DIR/config.env"
HOTSPOT_CONN_NAME="SiteStream-Setup"

SKIP_CONFIRM=false
FORGET_WIFI=false
for arg in "$@"; do
  case "$arg" in
    --yes) SKIP_CONFIRM=true ;;
    --forget-wifi) FORGET_WIFI=true ;;
    *) echo "Unknown option: $arg (expected --yes and/or --forget-wifi)"; exit 1 ;;
  esac
done

if [ "$SKIP_CONFIRM" != "true" ]; then
  echo "This will erase this device's claim, cached videos, and all local state —"
  echo "resetting it to look freshly installed. It will NOT un-claim it server-side;"
  echo "remove it from the portal separately first if you want this serial number"
  echo "to show up as unclaimed again afterward."
  if [ "$FORGET_WIFI" = "true" ]; then
    echo ""
    echo "--forget-wifi was passed: this device's saved Wi-Fi network(s) will ALSO be"
    echo "removed. It will NOT reconnect to this network on its own afterward — you'll"
    echo "need physical/hotspot access to rejoin it to a network again."
  fi
  echo ""
  read -r -p "Continue? [y/N] " confirm
  case "$confirm" in
    y|Y) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

echo "Clearing device identity, Wi-Fi credentials, and multicast config from config.env…"
if [ -f "$CONFIG" ]; then
  # WIFI_SSID/WIFI_PASSWORD (pushed from the cloud manifest — see sync.sh)
  # and MULTICAST_INTERFACE (added after this list was first written) were
  # both missing here: leaving the previous owner's plaintext Wi-Fi password
  # sitting in config.env directly contradicts this script's own reselling
  # use case, and a partial multicast clear (ENABLED/ADDRESS/PORT but not
  # INTERFACE) left a stale NIC pin behind for whichever device claims this
  # serial next.
  sed -i '/^DEVICE_TOKEN=/d; /^MULTICAST_ENABLED=/d; /^MULTICAST_ADDRESS=/d; /^MULTICAST_PORT=/d; /^MULTICAST_INTERFACE=/d; /^WIFI_SSID=/d; /^WIFI_PASSWORD=/d' "$CONFIG"
fi

# Clearing WIFI_SSID/WIFI_PASSWORD above only removes the CLOUD-pushed
# credentials cache in config.env — it was never what actually joined this
# device to a network. The real NetworkManager connection profile (created
# either by the portal's own Wi-Fi Join, see system.ts's wifi/connect route,
# or by sync.sh applying cloud-pushed credentials) stays behind on its own,
# and this device will keep reconnecting to it on every boot regardless of
# anything above. Confirmed live: a factory reset with none of this stayed
# joined to its network the whole time. Opt-in via --forget-wifi (see the
# usage comment at the top of this file for why this defaults off) actually
# removes those saved profiles too, via forget-wifi.sh (extracted into its
# own file so sync.sh's remote-triggered path can run it separately, AFTER
# confirming completion to the API — see that script's own comment on why:
# this step severs whatever network connection is currently active, which
# used to silently break the very confirm call that was supposed to run
# right after it).
if [ "$FORGET_WIFI" = "true" ]; then
  "$SITESTREAM_DIR/forget-wifi.sh"
fi

echo "Clearing local provisioning/state files…"
# .installed_version is deliberately NOT included here (unlike earlier
# versions of this script) — it reflects what code is actually on disk,
# which a factory reset doesn't change. Wiping it just makes the portal
# show "unknown" again and gives sync.sh's own self-update check nothing to
# compare against, triggering a pointless self-update-to-the-same-version
# the moment this device is reclaimed.
rm -f "$SITESTREAM_DIR/.manifest_hash" "$SITESTREAM_DIR/.sync_interval" \
      "$SITESTREAM_DIR/.wifi_ssid_applied" "$SITESTREAM_DIR/schedule.json" \
      "$SITESTREAM_DIR/status.json" "$SITESTREAM_DIR/.health_urgent" \
      "$SITESTREAM_DIR/.sync.lock" "$SITESTREAM_DIR/onboarding.png" \
      "$SITESTREAM_DIR/.wifi_rescue_state" "$SITESTREAM_DIR/.wifi_rescue_last_retry" \
      "$SITESTREAM_DIR/.wifi_struggling_since" "$SITESTREAM_DIR/.wifi_rescue_screen_state" \
      "$SITESTREAM_DIR/wifi-rescue.png"

echo "Clearing standalone-mode local portal database (videos, schedules, admin login)…"
# Deleting the file outright — not just its rows — is what actually resets
# the admin login too: db.ts creates a fresh default admin/SiteStream user
# (must-change-password set) as a side effect of opening the database file
# for the first time (see auth.ts's getAuthRow), the same as any other new
# install. Leaving the file in place would keep the previous owner's portal
# password intact, which is exactly what this reselling use case shouldn't do.
rm -f "$SITESTREAM_DIR/pi-portal.sqlite3" "$SITESTREAM_DIR/pi-portal.sqlite3-shm" \
      "$SITESTREAM_DIR/pi-portal.sqlite3-wal"

echo "Clearing cached videos…"
rm -f "$SITESTREAM_DIR"/videos/*.mp4 "$SITESTREAM_DIR"/videos/*.etag "$SITESTREAM_DIR"/videos/*.tmp 2>/dev/null

echo "Clearing logs…"
: > "$SITESTREAM_DIR/logs/sync.log" 2>/dev/null
: > "$SITESTREAM_DIR/logs/vlc.log" 2>/dev/null
: > "$SITESTREAM_DIR/logs/vlc-multicast.log" 2>/dev/null

echo "Resetting cron to the zero-touch default (every 1 minute)…"
CRON_LINE="* * * * * $SITESTREAM_DIR/sync.sh >> $SITESTREAM_DIR/logs/sync.log 2>&1"
# `|| true` after the grep matters: on every re-run after the first — and
# repeated re-runs are this exact script's own stated use case for retesting
# the onboarding flow — the crontab already contains exactly this one
# sync.sh line, so `grep -v` filters it out completely and exits 1 ("no
# lines selected"). That's the last command in this subshell, which
# inherits the calling shell's `set -e` if the caller has one active, and
# even without it, an empty subshell output here still means `echo
# "$CRON_LINE"` never gets a chance to run before it — either way,
# `crontab -` ends up installing an empty crontab instead of the intended
# one. Same root cause already found and fixed in install.sh and sync.sh.
(crontab -l 2>/dev/null | grep -v "sitestream/sync.sh" || true; echo "$CRON_LINE") | crontab -

echo "Restarting player, listener, and standalone-portal services…"
sudo systemctl restart sitestream-player.service 2>/dev/null \
  || echo "WARN: could not restart sitestream-player.service"
sudo systemctl restart sitestream-listen.service 2>/dev/null \
  || echo "WARN: could not restart sitestream-listen.service"
# Needed for the pi-portal.sqlite3 deletion above to actually take effect
# now rather than eventually: without this, the running server keeps its
# existing open handle on the now-unlinked file (still fully usable to the
# process that already had it open) until something else happens to restart
# it — the admin login and Media Library would look untouched the whole
# time, not freshly reset, until that eventually happened on its own.
sudo systemctl restart sitestream-portal.service 2>/dev/null \
  || echo "WARN: could not restart sitestream-portal.service"

echo ""
echo "=== Factory reset complete ==="
echo "This device will show the onboarding screen now, and check in as"
echo "unclaimed within a minute (or run 'bash sync.sh' to trigger it now)."
echo "If it still shows up as already claimed, remove its old Device record"
echo "from the portal — this script only resets the Pi, not the server."
if [ "$FORGET_WIFI" = "true" ]; then
  echo ""
  echo "--forget-wifi was used: confirmed live that this can leave"
  echo "NetworkManager's Wi-Fi radio/device state stuck (no setup hotspot"
  echo "broadcasting, won't rejoin anything) until a full reboot, not just a"
  echo "service restart. Recommend rebooting now: sudo reboot"
  echo "(Not done automatically here — the remote-triggered path (sync.sh)"
  echo "reboots itself, after its own API confirm call; this script is also"
  echo "run standalone by a human, who should decide when to reboot.)"
fi
