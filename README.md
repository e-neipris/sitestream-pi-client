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
lives under `/home/pi/sitestream/` on the device — nothing sensitive is ever
committed to this repo.

## Deploying to a new Pi

No token to copy onto the device by hand — this is zero-touch, designed for
Pis that ship anywhere and get set up by whoever's on-site, with no access to
the admin system themselves.

1. On the Pi:
   ```bash
   git clone <this-repo-url> /home/pi/sitestream-src
   cd /home/pi/sitestream-src
   sudo bash install.sh https://your-sitestream-api.example.com
   ```
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

```bash
cd /home/pi/sitestream-src
git pull
sudo cp sync.sh player.sh /home/pi/sitestream/
sudo systemctl restart sitestream-player.service
```

(`install.sh` is idempotent too, if you need to re-run the full setup —
e.g. after changing the cron schedule or systemd unit.)

## Debugging

```bash
tail -f /home/pi/sitestream/logs/sync.log     # sync history
sudo systemctl status sitestream-player       # is the player service alive?
cat /home/pi/sitestream/schedule.json         # what the Pi currently thinks should play
```
