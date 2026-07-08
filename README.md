# SiteStream Pi Client

Runs on each Raspberry Pi. Pulls its schedule from the SiteStream API every 15
minutes, caches videos locally, and loops the currently-scheduled video in VLC.
Deliberately separate from the main [SiteStream](../SiteStream) monorepo — this
is the only thing that needs to exist on the device itself, so it's deployed by
`git clone`/`git pull` directly on the Pi rather than shipping the whole app.

## How it works

- `sync.sh` — runs every 15 min via cron. Fetches `/api/manifest` (device JWT),
  downloads any video whose ETag changed, deletes videos no longer scheduled,
  writes `schedule.json`, and reports a heartbeat back to the API.
- `player.sh` — runs as a systemd service. Every 30s, reads `schedule.json` and
  figures out what should be playing right now (time window + day-of-week +
  priority), and starts/switches VLC if needed.
- `install.sh` — one-time setup: installs `vlc`/`jq`/`curl`, writes
  `config.env` with the device's credentials, installs the cron job and
  systemd service.

All runtime state (`config.env`, `schedule.json`, logs, downloaded videos)
lives under `/home/pi/sitestream/` on the device — nothing sensitive is ever
committed to this repo.

## Deploying to a new Pi

1. In the SiteStream admin UI, register the device under the right Zone —
   this gives you a **device token** (shown once).
2. On the Pi:
   ```bash
   git clone <this-repo-url> /home/pi/sitestream-src
   cd /home/pi/sitestream-src
   sudo bash install.sh <DEVICE_TOKEN> https://your-sitestream-api.example.com
   sudo reboot
   ```
3. After reboot, VLC should come up full-screen and start playing whatever's
   scheduled for that zone right now.

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
