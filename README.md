# SiteStream Pi Client

Runs on each Raspberry Pi. Pulls its schedule from the SiteStream API every 15
minutes, caches videos locally, and loops the currently-scheduled video in VLC.
Deliberately separate from the main [SiteStream](../SiteStream) monorepo — this
is the only thing that needs to exist on the device itself, so it's deployed by
`git clone`/`git pull` directly on the Pi rather than shipping the whole app.

## How it works

- `sync.sh` — runs every 15 min via cron. If the Pi doesn't have a device
  token yet, it checks in with the API using its **hardware serial number**
  (read from `/proc/cpuinfo`) and waits to be claimed — see "Deploying to a
  new Pi" below. Once claimed, it fetches `/api/manifest` (device JWT),
  downloads any video whose ETag changed, deletes videos no longer scheduled,
  writes `schedule.json`, and reports a heartbeat back to the API.
- `player.sh` — runs as a systemd service. Every 30s, reads `schedule.json` and
  figures out what should be playing right now (time window + day-of-week +
  priority), and starts/switches VLC if needed.
- `install.sh` — one-time setup: installs `vlc`/`jq`/`curl`, writes
  `config.env` (just the API URL — no credentials yet), installs the cron job
  and systemd service, and runs an initial sync so the Pi's serial shows up
  right away.

All runtime state (`config.env`, `schedule.json`, logs, downloaded videos)
lives under `~/sitestream/` in the home directory of whoever ran
`install.sh` via `sudo` (Raspberry Pi OS Bullseye+ has no default `pi`
account — you pick your own username during imaging). That same user is
also who the systemd service runs VLC as, since it needs to match whoever's
desktop/X session is actually active. Nothing sensitive is ever committed to
this repo.

## Deploying to a new Pi

No token to copy onto the device by hand — this is zero-touch, designed for
Pis that ship anywhere and get set up by whoever's on-site, with no access to
the admin system themselves.

1. On the Pi, logged in as your normal user (not root):
   ```bash
   git clone <this-repo-url> ~/sitestream-src
   cd ~/sitestream-src
   sudo bash install.sh https://your-sitestream-api.example.com
   ```
   `install.sh` installs into *your* home directory, detected via `sudo` — run
   it as the account that owns the Pi's desktop session, not via `su`/root
   directly, or it won't know who to install for.
   This prints the device's hardware serial number at the end — it's also
   readable any time via `cat /proc/cpuinfo | grep Serial`, and worth putting
   on a physical label on the unit before it ships.
2. In the SiteStream admin UI (Devices page → **Claim Device**), enter that
   serial number, pick the Zone it belongs to, and give it a name. A Tenant
   Admin can do this themselves — no platform-team involvement needed.
3. Within 15 minutes (the Pi's cron cycle), it picks up its device token
   automatically and starts syncing. `sudo reboot` if you want VLC to come up
   immediately rather than waiting for the next cron tick.

## Updating an already-deployed Pi

`install.sh` copies `sync.sh`/`player.sh` from wherever you ran it *from*
(your git checkout) into `~/sitestream` — the actual location cron and
systemd run from. A plain `git pull` only updates the checkout, not that
deployed copy, so use `update.sh` instead of doing it by hand:

```bash
cd ~/sitestream-src
sudo bash update.sh
```

This pulls the latest, copies `sync.sh`/`player.sh` into `~/sitestream`, and
restarts `sitestream-player.service`. Equivalent by-hand version, if you'd
rather:

```bash
cd ~/sitestream-src
git pull
cp sync.sh player.sh ~/sitestream/
sudo systemctl restart sitestream-player.service
```

(`install.sh` is idempotent too, if you need to re-run the full setup —
e.g. after changing the cron schedule or systemd unit.)

## Uninstalling a Pi

Reverses everything `install.sh` set up — stops/removes the systemd service,
removes the cron job, deletes `~/sitestream` (config, cached videos,
logs, schedule state). Run it via `sudo` as the same user you installed as:

```bash
sudo bash uninstall.sh
```

By default this leaves `vlc`/`jq`/`curl`/`cron` installed, since those are
common Raspberry Pi OS utilities other things on the box might depend on. To
also remove those packages:

```bash
sudo bash uninstall.sh --purge-packages
```

This only cleans up the device itself — it doesn't touch the Device record
in the admin UI. If you don't want the device claimable again as-is, remove
it from the Devices page too. If you cloned this repo to `~/sitestream-src`
to run `install.sh`, delete that yourself afterward (`rm -rf ~/sitestream-src`)
— the uninstall script can't safely delete the directory it's running from.

## Debugging

```bash
tail -f ~/sitestream/logs/sync.log     # sync history
sudo systemctl status sitestream-player       # is the player service alive?
cat ~/sitestream/schedule.json         # what the Pi currently thinks should play
```
