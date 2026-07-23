#!/bin/bash
# SiteStream Pi Client — first-time setup
# Run this once on a fresh Raspberry Pi OS installation.
# Usage: sudo bash install.sh [API_URL] [APP_URL]
#
# API_URL: defaults to https://api.sitestream.app (or your self-hosted URL)
# APP_URL: the web portal (not the API) — same env var name/default as the
#   API's own APP_URL (see packages/api/src/lib/mailer.ts) for consistency.
#   Only used to build the QR code on the onboarding screen (see
#   generate-onboarding-screen.sh) — nothing here talks to it directly.
#
# No device token needed here — this Pi identifies itself to the API by its
# hardware serial number and waits to be claimed in the admin UI (Devices page,
# "Claim Device" — enter the serial printed on this unit, pick a Zone, done).
# sync.sh handles the check-in loop automatically via its normal 1-min cron.
# Until claimed, player.sh shows an onboarding screen with that serial and a
# QR code straight to the claim flow instead of a blank/idle display.

set -e

API_URL="${1:-https://api.sitestream.app}"
APP_URL="${2:-https://app.sitestream.app}"

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

# ── Modern Node.js (for the standalone-mode local portal) ─────────────────────
# Raspberry Pi OS's own apt repo ships a very old nodejs (v12 on Bullseye) —
# well below what pi-portal/server's Fastify 4 (and its router, find-my-way)
# actually needs (Node >=14.6 minimum; confirmed via real EBADENGINE warnings
# on real hardware). Handled entirely here, not via the generic
# PACKAGES_TO_INSTALL list below, since the install method differs by CPU:
#   - x86_64/arm64: NodeSource's apt repo (their setup script, then apt install)
#   - armv7l (32-bit Pi OS — still what a lot of Pi 4 images actually run,
#     confirmed on real hardware here): NodeSource dropped 32-bit ARM support
#     entirely (their setup script hard-errors "Unsupported architecture:
#     armhf") — fall back to the official prebuilt tarball straight from
#     nodejs.org instead, which (unlike NodeSource) still ships an armv7l
#     build.
# Skipped entirely if a sufficient Node is already present — idempotent for
# install.sh re-runs (self-update).
CURRENT_NODE_MAJOR=0
if command -v node >/dev/null 2>&1; then
  CURRENT_NODE_MAJOR=$(node -e 'console.log(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)
fi
if [ "$CURRENT_NODE_MAJOR" -lt 14 ]; then
  NODE_ARCH="$(uname -m)"
  echo "Installing a current Node.js (found v$CURRENT_NODE_MAJOR, need >=14, arch $NODE_ARCH)…"
  if [ "$NODE_ARCH" = "armv7l" ]; then
    NODE_PIN_VERSION="20.20.2"
    NODE_TARBALL="node-v$NODE_PIN_VERSION-linux-armv7l.tar.xz"
    curl -fsSL "https://nodejs.org/dist/v$NODE_PIN_VERSION/$NODE_TARBALL" -o "/tmp/$NODE_TARBALL"
    rm -rf /usr/local/lib/nodejs
    mkdir -p /usr/local/lib/nodejs
    tar -xJf "/tmp/$NODE_TARBALL" -C /usr/local/lib/nodejs
    rm -f "/tmp/$NODE_TARBALL"
    # /usr/local/bin already precedes /usr/bin on Debian's default PATH for
    # every user, interactive or not — these symlinks take priority over
    # whatever Raspbian's own (much older) nodejs/npm apt packages provide,
    # with no profile/PATH edits needed anywhere.
    for bin in node npm npx; do
      ln -sf "/usr/local/lib/nodejs/node-v$NODE_PIN_VERSION-linux-armv7l/bin/$bin" "/usr/local/bin/$bin"
    done
  else
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y -q nodejs
  fi
fi

# ── Dependencies ──────────────────────────────────────────────────────────────
# qrencode + imagemagick + fonts-dejavu-core are only for the onboarding
# screen (generate-onboarding-screen.sh) — everything else here is the
# existing set. fonts-dejavu-core is explicit, not assumed pre-installed —
# ImageMagick's -font DejaVu-Sans-Bold/DejaVu-Sans lookups need it present.
#
# Recorded BEFORE installing anything, not after — checking dpkg once these
# are already installed would always say "present" and uninstall.sh could
# never tell which ones it's actually safe to remove. Some of these
# (curl, cron especially) are very likely already on a stock Raspberry Pi OS
# image; uninstall.sh needs to remove only what THIS run actually added, or
# "uninstall" would leave the machine in a state that never existed before
# SiteStream touched it, not the state it started in.
# Node (for the standalone-mode local portal, pi-portal/) is NOT in this
# list — handled entirely in its own section above, since which install
# method even works depends on CPU architecture (see there for why).
PACKAGES_TO_INSTALL="vlc jq curl cron logrotate qrencode imagemagick fonts-dejavu-core"
NEWLY_INSTALLED_PACKAGES=""
for pkg in $PACKAGES_TO_INSTALL; do
  dpkg -s "$pkg" >/dev/null 2>&1 || NEWLY_INSTALLED_PACKAGES="$NEWLY_INSTALLED_PACKAGES $pkg"
done

apt-get update -q
apt-get install -y -q $PACKAGES_TO_INSTALL

# ── Directory structure ───────────────────────────────────────────────────────
mkdir -p "$PI_HOME/sitestream/videos"
mkdir -p "$PI_HOME/sitestream/logs"

# Trimmed (leading space from the loop above) — empty file if every package
# was already present, meaning uninstall.sh will correctly remove nothing.
echo "${NEWLY_INSTALLED_PACKAGES# }" > "$PI_HOME/sitestream/.packages_added_by_install"

# ── Write config — merges with whatever's already there, doesn't wipe it ──────
# This used to be a flat overwrite, which was fine when install.sh only ever
# ran once by hand. Now that self-update can re-run this unattended on every
# system-relevant release (see sync.sh's self-update step), a flat overwrite
# would strand an already-claimed device's DEVICE_TOKEN and multicast
# settings on every single fleet update — forcing a needless re-provisioning
# checkin each time instead of restoring exactly the config this script
# actually owns (API_URL/APP_URL/VIDEO_DIR/LOG_FILE) and leaving everything
# else (DEVICE_TOKEN, MULTICAST_*, anything sync.sh has since added) intact.
CONFIG_FILE="$PI_HOME/sitestream/config.env"
if [ -f "$CONFIG_FILE" ]; then
  grep -vE '^(API_URL|APP_URL|VIDEO_DIR|LOG_FILE)=' "$CONFIG_FILE" > "$CONFIG_FILE.preserved" || true
else
  : > "$CONFIG_FILE.preserved"
fi
{
  echo "API_URL=$API_URL"
  echo "APP_URL=$APP_URL"
  echo "VIDEO_DIR=$PI_HOME/sitestream/videos"
  echo "LOG_FILE=$PI_HOME/sitestream/logs/sync.log"
  cat "$CONFIG_FILE.preserved"
} > "$CONFIG_FILE.tmp"
rm -f "$CONFIG_FILE.preserved"
mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

chmod 600 "$CONFIG_FILE"

# ── Install scripts ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# On a self-update re-invocation, sync.sh has already cp -rf'd the whole
# extracted release into $PI_HOME/sitestream and THEN re-runs install.sh
# from inside that same directory (see sync.sh) — so SCRIPT_DIR and the
# destination below are the identical path at that point, and every `cp`
# in this block would be copying a file onto itself. That's not a harmless
# no-op: `cp` refuses ("are the same file") and exits non-zero, which
# (set -e) aborted this entire script right here on every single self-
# update, before packages/systemd units/sudoers/pi-portal ever got applied —
# silently, since sync.sh only logs install.sh failing here as a WARNing,
# not fatal (script files were already updated by its own copy either way).
# Skip entirely in that case; there's nothing to copy, the files are
# already exactly where they need to be.
if [ "$SCRIPT_DIR" != "$PI_HOME/sitestream" ]; then
  cp "$SCRIPT_DIR/sync.sh"                        "$PI_HOME/sitestream/sync.sh"
  cp "$SCRIPT_DIR/player.sh"                      "$PI_HOME/sitestream/player.sh"
  cp "$SCRIPT_DIR/listen.sh"                       "$PI_HOME/sitestream/listen.sh"
  cp "$SCRIPT_DIR/generate-onboarding-screen.sh"  "$PI_HOME/sitestream/generate-onboarding-screen.sh"
  cp "$SCRIPT_DIR/factory-reset.sh"               "$PI_HOME/sitestream/factory-reset.sh"
  cp "$SCRIPT_DIR/wifi-ap-fallback.sh"            "$PI_HOME/sitestream/wifi-ap-fallback.sh"
  cp "$SCRIPT_DIR/install.sh"                     "$PI_HOME/sitestream/install.sh"
fi
chmod +x "$PI_HOME/sitestream/sync.sh"
chmod +x "$PI_HOME/sitestream/player.sh"
chmod +x "$PI_HOME/sitestream/listen.sh"
chmod +x "$PI_HOME/sitestream/generate-onboarding-screen.sh"
chmod +x "$PI_HOME/sitestream/factory-reset.sh"
chmod +x "$PI_HOME/sitestream/wifi-ap-fallback.sh"
chmod +x "$PI_HOME/sitestream/install.sh"

# ── Standalone-mode local portal ───────────────────────────────────────────────
# pi-portal/ ships pre-built (server/dist + web-dist, no node_modules — see
# the main SiteStream monorepo's packages/pi-portal) inside this release's
# tarball, alongside the bash scripts above. node_modules is deliberately
# NOT shipped: better-sqlite3 needs a native binary matching THIS Pi's
# architecture, which a Windows/x64 dev machine can't produce — `npm
# install` right here, on the actual device, is what gets the correct
# prebuilt ARM binary (or falls back to compiling it) instead of shipping
# one that silently wouldn't load.
if [ -d "$SCRIPT_DIR/pi-portal" ]; then
  # Trailing /. on the source (and / on the dest) merges CONTENTS into an
  # existing destination in place — plain `cp -r src dst` behaves totally
  # differently once dst already exists (true for every reinstall/update
  # after the first): it copies src INTO dst as a nested subdirectory
  # (dst/pi-portal/pi-portal/...) instead of overwriting, silently leaving
  # the actually-served server/dist/index.js completely untouched no matter
  # how many times this runs. Confirmed on real hardware: this is why a
  # firmware update that otherwise completed successfully (including
  # restarting the service) still served old pi-portal code.
  #
  # Same self-copy hazard as the script block above still applies on top of
  # that — skip entirely when this is a self-update re-invocation
  # (SCRIPT_DIR already IS the destination), since src/. and dst/ being the
  # identical directory still errors ("are the same file") even with the
  # trailing-slash form.
  if [ "$SCRIPT_DIR" != "$PI_HOME/sitestream" ]; then
    cp -r "$SCRIPT_DIR/pi-portal/." "$PI_HOME/sitestream/pi-portal/"
  fi
  # This whole script runs as root (via sudo), so the copy above is
  # root-owned — chown it BEFORE the npm install below, which runs as the
  # unprivileged $PI_USER via `sudo -u` and needs to create node_modules/
  # inside it. The broader chown -R later in this script (covering the rest
  # of ~/sitestream) happens too late to help with that.
  chown -R "$PI_USER:$PI_GROUP" "$PI_HOME/sitestream/pi-portal"
  sudo -u "$PI_USER" bash -c "cd '$PI_HOME/sitestream/pi-portal/server' && npm install --omit=dev --no-audit --no-fund"
else
  echo "WARN: pi-portal/ not found next to install.sh — skipping standalone-mode local portal setup."
fi

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
# sync.sh caches the interval it last wrote to crontab (.sync_interval) so it
# doesn't rewrite crontab on every single run — only when the target value
# actually changes. That cache has no way to know we just reset crontab out
# from under it above, so on a re-run of this script it would see "target
# matches what I last applied" and skip rewriting, silently leaving the
# device on this 1-minute default forever instead of the zone's real
# interval. Clearing it forces sync.sh's next run to always re-verify and
# rewrite, regardless of what it remembers applying before.
rm -f "$PI_HOME/sitestream/.sync_interval"

# ── Kiosk display mode ─────────────────────────────────────────────────────────
# player.sh renders straight to the screen via VLC's own DRM/KMS output, not
# through a desktop session — a running desktop (X11 or Wayland, whichever
# this OS defaults to) holds the same DRM plane VLC needs for itself, and only
# one of the two can ever have it. Confirmed on real hardware: with lightdm
# running (X11 *or* Wayland, doesn't matter which), VLC's own DRM probe fails
# with "No plane found"; stopping lightdm and nothing else, it renders fine.
# do_boot_behaviour B2 is "Console Autologin" — this also flips the systemd
# default target to multi-user.target, which is why sitestream-player.service
# below targets that instead of graphical.target (which console-autologin
# systems never reach, so the service would just never start).
if command -v raspi-config >/dev/null 2>&1; then
  raspi-config nonint do_boot_behaviour B2 || true
fi
# The boot-behaviour change above only takes effect on next boot — belt and
# suspenders for a re-run of this script (self-update) on a Pi that's already
# sitting at a desktop session right now.
systemctl disable lightdm 2>/dev/null || true
systemctl stop lightdm 2>/dev/null || true

# Separate from X11/Wayland DPMS: the Linux console (fbcon) has its own
# blanking timer (~10 min default) that player.sh used to have to keep
# re-disabling via `xset` every loop — which only ever worked because an X
# session was running for `xset` to talk to. consoleblank=0 turns this off
# once, at the kernel level, permanently — nothing left for player.sh to do.
CMDLINE_FILE=""
for candidate in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
  [ -f "$candidate" ] && CMDLINE_FILE="$candidate" && break
done
if [ -n "$CMDLINE_FILE" ] && ! grep -q 'consoleblank=' "$CMDLINE_FILE"; then
  sed -i 's/$/ consoleblank=0/' "$CMDLINE_FILE"
fi

# ── Autostart VLC via systemd service ─────────────────────────────────────────
# Safe to enable even before claiming — player.sh just idles with nothing to
# play until sync.sh has been claimed and produces a real schedule.json.
cat > /etc/systemd/system/sitestream-player.service << EOF
[Unit]
Description=SiteStream Video Player
After=multi-user.target

[Service]
User=$PI_USER
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
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sitestream-player.service
# Deliberately NOT started/restarted unconditionally here on a fresh install —
# doing so would race the Console Autologin/lightdm-disable switch above,
# which itself needs a reboot to fully take effect (see the "Reboot the Pi to
# start the player" message at the end of this script). But on a self-update
# re-invocation of an already-installed device, this service is already
# running old code that needs to actually reload — `enable` alone never
# restarts anything, so without this, updated player.sh content would sit on
# disk unused until the next unrelated reboot.
if systemctl is-active --quiet sitestream-player.service; then
  systemctl restart sitestream-player.service
fi

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
# Default KillMode (control-group) signals every process in this service's
# cgroup on restart — including sync.sh, which listen.sh spawns as a
# backgrounded child every time it reacts to a push (see trigger_sync() in
# listen.sh). A self-update's own sync.sh run restarts THIS service (to pick
# up the new listen.sh) as one of its last steps — with the default KillMode
# that kills the very sync.sh process doing the restarting, right before it
# can report the update back to the API. KillMode=process signals only the
# main listen.sh process, sparing children like that in-flight sync.sh so it
# can finish normally. Exact same reasoning as sitestream-player.service's
# KillMode=process, different concrete symptom.
#
# Expected side effect, not a bug: every time this happens, journalctl logs
# a block like "Found left-over process NNNN (sync.sh) in control group
# while starting unit. Ignoring." (plus its sudo/systemctl/sleep children,
# and "This usually indicates unclean termination of a previous run, or
# service implementation deficiencies" underneath each one). That generic
# wording is systemd's one-size-fits-all message for any spared cgroup
# member — it does NOT mean anything leaked or failed to clean up. The old
# listen.sh (that sync.sh's real parent) exits during the restart, Linux
# re-parents the still-running sync.sh (and its children) to init/PID 1,
# and they're reaped normally the moment they finish their own last few
# lines a couple seconds later — same as any other orphaned process on
# Linux. Expect to see this exact log block on every push-triggered
# self-update, indefinitely; it's the visible signature of this fix working,
# not something to chase.
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sitestream-listen.service
# restart, not start — `start` no-ops on an already-active unit, which is
# exactly the case on every self-update re-invocation (this service is what's
# driving sync.sh right now). Without an actual restart, updated listen.sh/
# sync.sh behavior changes would never take effect until an unrelated reboot,
# which defeats the KillMode=process handling above (written specifically
# for THIS restart to survive gracefully mid-self-update).
systemctl restart sitestream-listen.service

# ── Wi-Fi ad-hoc setup fallback via systemd service ───────────────────────────
# Always running (same reasoning as the listener above) — it's the script
# itself that decides, every 30s, whether a hotspot is actually warranted
# (no connectivity AND not yet claimed — see wifi-ap-fallback.sh), not
# whether this service happens to be active. Safe to enable unconditionally
# even on a Bullseye/dhcpcd image: the script detects the lack of `nmcli`
# and exits cleanly rather than pretending to work.
cat > /etc/systemd/system/sitestream-wifi-ap.service << EOF
[Unit]
Description=SiteStream Wi-Fi Ad-Hoc Setup Fallback
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
User=$PI_USER
ExecStart=$PI_HOME/sitestream/wifi-ap-fallback.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sitestream-wifi-ap.service
systemctl restart sitestream-wifi-ap.service

# ── Standalone-mode local portal service ──────────────────────────────────────
# Always running (like the listener above), reachable at
# http://<this-device-lan-ip>:8080 — lets a customer who never claims this
# device into the cloud upload videos and build a schedule directly,
# read/writing the same schedule.json + videos/ player.sh already uses (see
# pi-portal/server for the full design). Goes read-only on its own once
# DEVICE_TOKEN shows up in config.env (i.e. this device gets claimed into
# the cloud after all) — no coordination needed here.
if [ -d "$PI_HOME/sitestream/pi-portal" ]; then
  cat > /etc/systemd/system/sitestream-portal.service << EOF
[Unit]
Description=SiteStream Standalone-Mode Local Portal
After=network-online.target
Wants=network-online.target

[Service]
User=$PI_USER
Environment=PORT=8080
Environment=SITESTREAM_DIR=$PI_HOME/sitestream
ExecStart=$(command -v node) $PI_HOME/sitestream/pi-portal/server/dist/index.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable sitestream-portal.service
  # restart, not start — this is precisely the bug that shipped in 1.28: on
  # a self-update, `start` no-ops against the already-running old server, so
  # the new pi-portal code (a new System tab, in that case) sat on disk
  # completely unused until something else happened to restart the process.
  systemctl restart sitestream-portal.service
fi

# ── Sudo grants: let sync.sh restart the player/listener services after a
# self-update, reboot the device on admin request, and re-run install.sh
# itself unattended for system-level updates (new packages, new/changed
# systemd units — see sync.sh's self-update step) — each scoped to exactly
# one command via sudoers.d, not blanket sudo access. sync.sh runs as
# $PI_USER, not root (see the cron job below), so without these it can't do
# any of them: the Pi would keep running old code until its next natural
# reboot, the admin-panel Reboot button would have no way to actually reboot
# it, and a release needing anything beyond a plain script swap would need a
# human to SSH in and re-run install.sh by hand on every single device.
#
# The install.sh grant is the one worth being deliberate about: it lets an
# unprivileged process run this exact script as root, and this script's own
# CONTENT is whatever the most recent release tarball contained — so the
# real trust boundary this rests on is "whoever can upload a PiRelease"
# (already SUPER_ADMIN-gated), not sync.sh's own logic. That's the same
# trust boundary self-update already operates under for sync.sh/player.sh/
# listen.sh's own content today; this extends it to full root rather than
# narrowing to a new one.
# Also covers the standalone portal's System tab (pi-portal/server/src/
# routes/system.ts) — Wi-Fi join, timezone, NTP toggle, manual date/time, and
# hostname all need root, and that server runs as $PI_USER same as sync.sh.
# Firmware upload from that same tab needs no grant of its own: it reuses
# the install.sh rule below verbatim, the same mechanism sync.sh's own
# self-update already relies on.
SYSTEMCTL_BIN="$(command -v systemctl)"
BASH_BIN="$(command -v bash)"
RASPI_CONFIG_BIN="$(command -v raspi-config)"
TIMEDATECTL_BIN="$(command -v timedatectl)"
HOSTNAMECTL_BIN="$(command -v hostnamectl)"
IW_BIN_FOR_SUDOERS="$(command -v iw)"
NMCLI_BIN="$(command -v nmcli)"
cat > /etc/sudoers.d/sitestream << EOF
$PI_USER ALL=(root) NOPASSWD: $SYSTEMCTL_BIN restart sitestream-player.service
$PI_USER ALL=(root) NOPASSWD: $SYSTEMCTL_BIN restart sitestream-listen.service
$PI_USER ALL=(root) NOPASSWD: $SYSTEMCTL_BIN reboot
$PI_USER ALL=(root) NOPASSWD: $BASH_BIN $PI_HOME/sitestream/install.sh *
$PI_USER ALL=(root) NOPASSWD: $RASPI_CONFIG_BIN nonint do_wifi_ssid_passphrase *
$PI_USER ALL=(root) NOPASSWD: $RASPI_CONFIG_BIN nonint do_wifi_country *
$PI_USER ALL=(root) NOPASSWD: $TIMEDATECTL_BIN set-timezone *
$PI_USER ALL=(root) NOPASSWD: $TIMEDATECTL_BIN set-ntp *
$PI_USER ALL=(root) NOPASSWD: $TIMEDATECTL_BIN set-time *
$PI_USER ALL=(root) NOPASSWD: $HOSTNAMECTL_BIN set-hostname *
$PI_USER ALL=(root) NOPASSWD: $IW_BIN_FOR_SUDOERS dev * scan
$PI_USER ALL=(root) NOPASSWD: $NMCLI_BIN device wifi hotspot *
$PI_USER ALL=(root) NOPASSWD: $NMCLI_BIN connection down *
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

PI_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

echo ""
echo "=== Setup complete ==="
echo "Device serial: $SERIAL"
echo "Go to the SiteStream admin UI -> Devices -> Claim Device, enter that serial,"
echo "and assign it to a Zone. This Pi will pick up its token within 15 minutes"
echo "(or immediately, next time sync.sh runs)."
echo ""
if [ -d "$PI_HOME/sitestream/pi-portal" ]; then
  echo "Don't want to use the cloud? Go to http://${PI_IP:-<this-device-ip>}:8080 instead"
  echo "to upload videos and build a schedule directly on this device — no account needed."
  echo ""
fi
echo "Reboot the Pi to start the player: sudo reboot"
echo "Logs: tail -f $PI_HOME/sitestream/logs/sync.log"
