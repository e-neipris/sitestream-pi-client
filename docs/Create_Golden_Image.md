# Creating a Golden Image for Mass SD Card Provisioning

How to prepare a Raspberry Pi as a "golden" source device, capture its SD card
as an image, and clone it onto multiple cards for a production batch.

## Why this works safely

Each device identifies itself to the SaaS by its **hardware serial number**
(from `/proc/cpuinfo`) — this is baked into the SoC, not part of the SD card
image, so it's automatically unique per clone with zero extra steps. The only
things that need manual cleanup before imaging are the pieces that *do* live
on the SD card: SiteStream's own claim token, and a couple of OS-level
identity files.

## Before you start

Make sure the source Pi is running the **latest pi-client release** before
you capture the image — whatever version is on it when you image it is what
every cloned device ships with until it's claimed (self-update only runs
*after* claiming; see "Note on outdated images" below).

Upload the latest release via the local portal's Firmware tab
(`http://<device-ip>:8080`) if it isn't already current.

## Step 1 — Strip SiteStream's own identity

On the golden Pi:

```bash
bash ~/sitestream/factory-reset.sh --yes --forget-wifi
```

This wipes:
- `DEVICE_TOKEN` — **critical**. Without this, every cloned device would
  share one device identity and fight over the same record server-side.
- Saved Wi-Fi credentials/profile (`--forget-wifi`) — so clones don't try to
  auto-join your test network.
- Cached videos, the standalone portal's admin login/database, and all local
  state files.

## Step 2 — Strip OS-level identity

```bash
sudo rm -f /etc/machine-id /var/lib/dbus/machine-id
sudo rm -f /etc/ssh/ssh_host_*
```

Both regenerate automatically on next boot (machine-id via systemd, SSH host
keys via `ssh-keygen -A` at sshd startup). Without this, every clone shares
the same machine-id (confuses some DHCP/logging setups) and the same SSH
host key (a single leaked private key would let someone impersonate/MITM
*every* unit).

Wi-Fi **country code**, if already set, is fine to leave alone — it's a
regulatory-region setting, not a per-device credential, and every clone
should inherit it.

## Step 3 — Shut down and pull the card

```bash
sudo shutdown now
```

Remove the SD card once the Pi is fully powered off.

## Step 4 — Capture the image

Read the card into an `.img` file with **Win32DiskImager** (Read mode) on
Windows. Raspberry Pi Imager can flash but can't capture from a live card —
Win32DiskImager is the tool for this direction.

Sizing note: a raw image captures the *entire* card. Keep your golden card at
the smallest capacity you'll standardize on — any same-or-larger destination
card works fine, since Raspberry Pi OS auto-expands the filesystem to fill
whatever card it boots on, regardless of the source image's size.

## Step 5 — Flash the batch

For writing to **multiple cards at once**, Raspberry Pi Imager only allows
one running instance — use one of these instead:

- **balenaEtcher** — supports flashing one image to multiple target drives
  simultaneously in a single session. The easiest option for a real batch.
- **USB Image Tool** — also built for one-to-many cloning.
- **Win32DiskImager** — no single-instance lock, so you can just launch it
  multiple times, once per target card, side by side.

You'll need enough card readers/slots to have all target cards connected at
once for true parallel writing.

## Step 6 — Verify one card before mass-producing

Boot a single cloned card end-to-end first:
- Shows the onboarding screen with a **different** serial number than the
  golden device.
- Joins your network and checks in as a new, unclaimed device in the portal.

Once confirmed, the rest is repeat-and-flash.

## Note on outdated images

Self-update only runs **after** a device is claimed — an unclaimed device
has no manifest/target release to check against. So:

- If you image a batch now and claim devices later, each one will pick up
  whatever release is targeted for its zone/tenant automatically on its
  first check-in after claiming, regardless of what shipped on the card.
- If you need a specific device running the latest code **before** claiming
  it (e.g. to test onboarding-screen behavior pre-claim), that one still
  needs a manual firmware upload via its local portal.
- Check the destination tenant's release channel before relying on
  auto-update: a tenant on the `GA` channel can only be targeted with a `GA`
  release. If the release you need is still `BETA`, either promote it (Platform
  Admin → Firmware page) or set the tenant/zone target once it's promoted.
