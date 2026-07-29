import { FastifyInstance, FastifyBaseLogger } from 'fastify'
import { z } from 'zod'
import { exec as execCb, execFile as execFileCb } from 'child_process'
import { promisify } from 'util'
import fs from 'fs'
import os from 'os'
import path from 'path'
import { SITESTREAM_DIR, CONFIG_FILE, getApiUrl, getAppUrl, parseConfigEnv } from '../paths'

const exec = promisify(execCb)
const execFile = promisify(execFileCb)

const INSTALLED_VERSION_FILE = path.join(SITESTREAM_DIR, '.installed_version')
// Same files sync.sh itself writes (.last_sync_ok on every successful
// manifest fetch, .sync_interval on every cron-schedule change) — reused
// here rather than duplicated, so this always reflects sync.sh's own idea
// of the cadence instead of a second, potentially-drifting copy of it.
const LAST_SYNC_OK_FILE = path.join(SITESTREAM_DIR, '.last_sync_ok')
const SYNC_INTERVAL_FILE = path.join(SITESTREAM_DIR, '.sync_interval')

/** Requested in QA: a visible "next check-in" on the System tab, so a
 * tester watching a sync-interval change (or just wondering if the device
 * is stuck) doesn't have to guess. Null when we don't have enough state to
 * compute it yet (never synced, or interval unknown) rather than a
 * misleading guess. */
function getNextCheckin(): string | null {
  if (!fs.existsSync(LAST_SYNC_OK_FILE)) return null
  const lastSyncOk = Number(fs.readFileSync(LAST_SYNC_OK_FILE, 'utf8').trim())
  if (!Number.isFinite(lastSyncOk)) return null

  const intervalMinutes = fs.existsSync(SYNC_INTERVAL_FILE)
    ? Number(fs.readFileSync(SYNC_INTERVAL_FILE, 'utf8').trim())
    : 15
  if (!Number.isFinite(intervalMinutes)) return null

  return new Date((lastSyncOk + intervalMinutes * 60) * 1000).toISOString()
}

// child_process errors carry stdout/stderr from the failed command, which is
// exactly what's needed to actually diagnose a sudoers/permission/syntax
// problem — every catch block below logs this instead of swallowing it, so
// a failure shows up in `journalctl -u sitestream-portal.service` instead of
// just a generic 500 with no trace of what the underlying command said.
function logExecFailure(log: FastifyBaseLogger, context: string, err: unknown) {
  const e = err as { message?: string; stdout?: string; stderr?: string; code?: number }
  log.error({ context, message: e?.message, stdout: e?.stdout, stderr: e?.stderr, code: e?.code }, 'system route command failed')
}

// Plain `timedatectl show` (no --property filter) dumps every property as
// KEY=VALUE, one per line — deliberately not relying on the comma-joined
// `--property=A,B,C --value` form (order-dependent, easy to get subtly
// wrong) when this is unambiguous and just as cheap to parse.
async function readTimedatectlProperties(): Promise<Record<string, string>> {
  const { stdout } = await exec('timedatectl show')
  const result: Record<string, string> = {}
  for (const line of stdout.split('\n')) {
    const eq = line.indexOf('=')
    if (eq === -1) continue
    result[line.slice(0, eq)] = line.slice(eq + 1)
  }
  return result
}

// `wlan0` was a hardcoded guess — confirmed wrong on real hardware (sudo
// authorized the scan command fine; it just found no such interface, which
// a `2>/dev/null` on that first attempt then hid completely). `iw dev` (no
// interface argument) lists whatever wireless interfaces actually exist;
// asking it directly instead of assuming a name works on any interface
// naming scheme.
async function detectWifiInterface(): Promise<string | null> {
  try {
    const { stdout } = await exec('iw dev')
    return stdout.match(/Interface\s+(\S+)/)?.[1] ?? null
  } catch {
    return null
  }
}

/**
 * Raspberry Pi OS soft-blocks the Wi-Fi radio via rfkill until a regulatory
 * country is set (a legal requirement — transmit power/channel limits are
 * region-specific — not a bug), which a device that's never been through
 * raspi-config's Wi-Fi setup will still be sitting in. Confirmed on real
 * hardware: `iw scan` in that state fails with "Network is down (-100)",
 * a genuinely confusing error with no mention of rfkill or country codes
 * anywhere in it.
 */
async function isWifiRadioBlocked(): Promise<boolean> {
  try {
    const { stdout } = await exec('rfkill list wifi')
    return /Soft blocked:\s*yes/i.test(stdout)
  } catch {
    return false
  }
}

export interface WifiStatus {
  ssid: string | null
  ipAddress: string | null
  subnetMask: string | null
  gateway: string | null
  dns: string[]
}

const EMPTY_WIFI_STATUS: WifiStatus = { ssid: null, ipAddress: null, subnetMask: null, gateway: null, dns: [] }

// /24 -> 255.255.255.0, etc — nmcli/`ip` both report the prefix length, not
// the dotted form the System tab wants to show alongside gateway/DNS.
function cidrPrefixToNetmask(prefix: number): string {
  const mask = prefix === 0 ? 0 : (0xffffffff << (32 - prefix)) >>> 0
  return [24, 16, 8, 0].map((shift) => (mask >>> shift) & 0xff).join('.')
}

// Same NetworkManager-first, `iw`-tooling-fallback split as scanWifi below —
// `nmcli dev wifi` marks the currently-associated network with `active:yes`
// in its own listing, so no separate "am I connected" query is needed on
// Bookworm/Trixie; `iwgetid -r` (wireless-tools, already present alongside
// dhcpcd+wpa_supplicant on Bullseye) covers the older backend. Once an SSID
// is known, `nmcli device show` on that same interface carries the IPv4
// address/gateway/DNS in one call — `ip addr`/`ip route`/resolv.conf below
// is only for the Bullseye path where nmcli isn't managing the interface.
async function getWifiStatus(): Promise<WifiStatus> {
  const iface = await detectWifiInterface()
  if (!iface) return EMPTY_WIFI_STATUS

  let ssid: string | null = null
  try {
    const { stdout } = await exec('nmcli -t -f active,ssid dev wifi list 2>/dev/null')
    const line = stdout.split('\n').find((l) => l.startsWith('yes:'))
    if (line) ssid = line.slice('yes:'.length).trim() || null
  } catch {
    // nmcli not present/usable — fall through to iwgetid below.
  }
  if (!ssid) {
    try {
      const { stdout } = await execFile('iwgetid', ['-r'])
      ssid = stdout.trim() || null
    } catch {
      // Neither tool available — genuinely not connected (or can't tell).
    }
  }
  if (!ssid) return EMPTY_WIFI_STATUS

  try {
    const { stdout } = await execFile('nmcli', ['-t', '-f', 'IP4.ADDRESS,IP4.GATEWAY,IP4.DNS', 'device', 'show', iface])
    let ipAddress: string | null = null
    let prefix: number | null = null
    let gateway: string | null = null
    const dns: string[] = []
    for (const line of stdout.split('\n')) {
      const colon = line.indexOf(':')
      if (colon === -1) continue
      const key = line.slice(0, colon)
      const value = line.slice(colon + 1).trim()
      if (!value) continue
      if (key.startsWith('IP4.ADDRESS')) {
        const [ip, cidr] = value.split('/')
        ipAddress = ip
        prefix = cidr ? Number(cidr) : null
      } else if (key === 'IP4.GATEWAY') {
        gateway = value
      } else if (key.startsWith('IP4.DNS')) {
        dns.push(value)
      }
    }
    if (ipAddress) {
      return { ssid, ipAddress, subnetMask: prefix !== null ? cidrPrefixToNetmask(prefix) : null, gateway, dns }
    }
  } catch {
    // nmcli device show unsupported/failed — fall through to `ip`/resolv.conf below.
  }

  try {
    const { stdout: addrOut } = await execFile('ip', ['-4', '-o', 'addr', 'show', iface])
    const addrMatch = addrOut.match(/inet\s+(\d+\.\d+\.\d+\.\d+)\/(\d+)/)
    const ipAddress = addrMatch?.[1] ?? null
    const prefix = addrMatch ? Number(addrMatch[2]) : null

    const { stdout: routeOut } = await execFile('ip', ['-4', 'route', 'show', 'default'])
    const gatewayMatch = routeOut.match(/default via (\d+\.\d+\.\d+\.\d+)/)

    const dns = fs.existsSync('/etc/resolv.conf')
      ? fs.readFileSync('/etc/resolv.conf', 'utf8').split('\n')
        .map((l) => l.trim())
        .filter((l) => l.startsWith('nameserver '))
        .map((l) => l.split(/\s+/)[1])
        .filter(Boolean)
      : []

    return {
      ssid,
      ipAddress,
      subnetMask: prefix !== null ? cidrPrefixToNetmask(prefix) : null,
      gateway: gatewayMatch?.[1] ?? null,
      dns,
    }
  } catch {
    return { ssid, ipAddress: null, subnetMask: null, gateway: null, dns: [] }
  }
}

export interface MulticastConfig {
  enabled: boolean
  address: string | null
  port: number | null
  interface: string | null
}

// Same MULTICAST_* keys, same config.env, as sync.sh's cloud-driven path
// (see sync.sh's "Persist multicast output config for player.sh to pick
// up") — player.sh doesn't know or care which side wrote them, it just
// re-sources config.env every ~30s (see its main loop) and reacts to
// whatever it finds. This is what gives a standalone, never-claimed device
// the same multicast output the cloud already offers a claimed one.
function getMulticastConfig(): MulticastConfig {
  const cfg = parseConfigEnv()
  return {
    enabled: cfg.MULTICAST_ENABLED === 'true',
    address: cfg.MULTICAST_ADDRESS || null,
    port: cfg.MULTICAST_PORT ? Number(cfg.MULTICAST_PORT) : null,
    interface: cfg.MULTICAST_INTERFACE || null,
  }
}

// Rewrites only the MULTICAST_* lines, in place — every other key already in
// config.env (APP_URL/API_URL/VIDEO_DIR/LOG_FILE, and DEVICE_TOKEN once
// claimed) passes through untouched, same strip-then-append shape as
// sync.sh's own rewrite of these same four keys.
function writeMulticastConfig(config: MulticastConfig): void {
  const existingLines = fs.existsSync(CONFIG_FILE) ? fs.readFileSync(CONFIG_FILE, 'utf8').split('\n') : []
  const kept = existingLines.filter((line) => !/^(MULTICAST_ENABLED|MULTICAST_ADDRESS|MULTICAST_PORT|MULTICAST_INTERFACE)=/.test(line))
  while (kept.length && kept[kept.length - 1] === '') kept.pop()

  const next = [
    ...kept,
    `MULTICAST_ENABLED=${config.enabled}`,
    `MULTICAST_ADDRESS=${config.address ?? ''}`,
    `MULTICAST_PORT=${config.port ?? ''}`,
    `MULTICAST_INTERFACE=${config.interface ?? ''}`,
  ].join('\n') + '\n'

  fs.writeFileSync(CONFIG_FILE, next, { mode: 0o600 })
}

// Lists real NICs for the multicast interface dropdown (see MULTICAST_INTERFACE
// / player.sh's --miface). Was `os.networkInterfaces()` filtered to
// addresses-currently-bound — which excludes a real, physically-present
// interface like an eth0 with no cable plugged in yet (no link, no DHCP
// lease, no address at all), even though picking that interface ahead of
// time for a not-yet-connected multicast feed is a legitimate thing to want
// to do. sync.sh's own network-interfaces report (sent up to the cloud,
// which is why the SaaS-side multicast dropdown for the same device didn't
// have this problem) enumerates /sys/class/net directly instead — no
// address requirement, just filtering out loopback and virtual interfaces.
// Mirrored here so both dropdowns agree.
function listNetworkInterfaces(): string[] {
  let names: string[]
  try {
    names = fs.readdirSync('/sys/class/net')
  } catch {
    // Not on Linux (local dev off a real Pi) — fall back to the old
    // address-bound view rather than returning nothing.
    return Object.entries(os.networkInterfaces())
      .filter(([name, addrs]) => name !== 'lo' && addrs?.some((a) => !a.internal))
      .map(([name]) => name)
  }
  return names.filter((name) => !/^(lo|veth|docker|br-|tun|tap)/.test(name))
}

// Must match wifi-ap-fallback.sh's own HOTSPOT_CONN_NAME — duplicated
// rather than shared, same as that script's own SSID/password duplication
// with generate-onboarding-screen.sh (see that file's comment).
const HOTSPOT_CONN_NAME = 'SiteStream-Setup'

async function scanWifi(): Promise<{ ssid: string; signal: number }[]> {
  if (await isWifiRadioBlocked()) {
    throw new Error('WIFI_BLOCKED')
  }

  const iface = await detectWifiInterface()

  // NetworkManager doesn't expose scan results through `nmcli device wifi
  // list` for a device that's currently ACTIVE AS AN AP (this device's own
  // setup hotspot) — confirmed live: `nmcli device wifi rescan` reports
  // success, and the underlying kernel-level scan genuinely finds every
  // nearby network across every channel and band (this chip supports
  // concurrent AP+scan fine — the same mechanism as rogue-AP detection —
  // it's not the single-radio AP-or-client limitation that applies to
  // actually *joining* a network). But `nmcli dev wifi list` only ever
  // echoes the device's own hotspot SSID back regardless, which used to
  // satisfy this function's old "did nmcli find anything" check below and
  // return just that one self-entry — hiding every real network from
  // someone who is, in the overwhelmingly common case, only reachable
  // BECAUSE they're connected to that same hotspot. Skip nmcli's list
  // entirely in this state and go straight to the `iw scan` path below,
  // which does work.
  const actingAsHotspot = iface
    ? await execFile('nmcli', ['-t', '-f', 'GENERAL.CONNECTION', 'device', 'show', iface])
        .then(({ stdout }) => {
          const colon = stdout.indexOf(':')
          return colon !== -1 && stdout.slice(colon + 1).trim() === HOTSPOT_CONN_NAME
        })
        .catch(() => false)
    : false

  // Prefer NetworkManager (Bookworm/Trixie's default) — falls back to a raw
  // `iw` scan for dhcpcd+wpa_supplicant setups (Bullseye's default) and for
  // the acting-as-hotspot case above. Neither call takes any user-supplied
  // input, so a plain shell string is fine here — no injection surface,
  // unlike wifi/connect below.
  if (!actingAsHotspot) {
    try {
      // `nmcli ... list` shows the LAST scan's cached results, which is often
      // empty if nothing has triggered a scan recently — request a fresh one
      // first. Best-effort: NetworkManager rate-limits rescans, so a failure
      // here just means "use whatever's cached," not fatal.
      await exec('nmcli device wifi rescan 2>/dev/null').catch(() => {})
      const { stdout } = await exec('nmcli -t -f SSID,SIGNAL dev wifi list 2>/dev/null')
      const seen = new Set<string>()
      const networks = stdout.split('\n')
        .map((line) => line.split(':'))
        .filter(([ssid]) => ssid && !seen.has(ssid) && seen.add(ssid))
        .map(([ssid, signal]) => ({ ssid, signal: Number(signal) || 0 }))
      // nmcli can run successfully and still report zero networks (rather
      // than erroring) on a dhcpcd+wpa_supplicant box where it's present but
      // not actually managing the wireless interface — fall through to the
      // iw path below instead of silently returning an empty list here.
      if (networks.length > 0) return networks
    } catch {
      // nmcli itself isn't present/usable at all — fall through below.
    }
  }

  if (!iface) {
    throw new Error('No wireless interface found (checked via `iw dev`)')
  }

  // execFile, not a shell pipeline through `grep` — a pipeline's exit code
  // only reflects the LAST command, so `iw scan` failing outright (wrong
  // interface, adapter down) and `iw scan` succeeding with zero SSID lines
  // were indistinguishable before, and stderr piped to /dev/null hid the
  // real reason either way. Parsing the raw output here instead surfaces
  // an actual `iw` failure as a real, logged error.
  const { stdout } = await execFile('sudo', ['-n', 'iw', 'dev', iface, 'scan'])
  const seen = new Set<string>()
  const results: { ssid: string; signal: number }[] = []
  // `signal:` (dBm) always precedes the `SSID:` line within the same BSS
  // block in `iw scan` output — tracked per-block (reset on each new `BSS `
  // header) and converted to the same rough 0-100 percent NetworkManager's
  // own SIGNAL column uses, so this fallback path's numbers land in the
  // same ballpark whichever path a given call ends up taking.
  let lastSignalDbm: number | null = null
  for (const rawLine of stdout.split('\n')) {
    const line = rawLine.trim()
    if (line.startsWith('BSS ')) {
      lastSignalDbm = null
    } else if (line.startsWith('signal:')) {
      const match = line.match(/signal:\s*(-?\d+(?:\.\d+)?)/)
      if (match) lastSignalDbm = Number(match[1])
    } else if (line.startsWith('SSID:')) {
      const ssid = line.replace(/^SSID:\s*/, '').trim()
      if (ssid && !seen.has(ssid)) {
        seen.add(ssid)
        const signal = lastSignalDbm !== null ? Math.max(0, Math.min(100, Math.round(2 * (lastSignalDbm + 100)))) : 0
        results.push({ ssid, signal })
      }
    }
  }
  return results
}

// Auth is now enforced globally in index.ts for the whole portal, not just
// this prefix — no per-route hook needed here anymore.
export default async function systemRoutes(app: FastifyInstance) {

  /** GET /api/system/info — current state for the System tab's summary panel */
  app.get('/info', async (request) => {
    let timezone = 'UTC'
    let ntpEnabled = false
    let ntpSynced = false
    try {
      const props = await readTimedatectlProperties()
      timezone = props.Timezone || 'UTC'
      ntpEnabled = props.NTP === 'yes'
      ntpSynced = props.NTPSynchronized === 'yes'
    } catch (err) {
      // timedatectl unavailable (e.g. running this server outside a real Pi,
      // for local dev) — fall back to sane-looking defaults rather than 500,
      // but log it: this exact fallback is what makes a real failure here
      // look like "it silently reverted" instead of an obvious error.
      logExecFailure(request.log, 'GET /info timedatectl show', err)
    }

    const installedVersion = fs.existsSync(INSTALLED_VERSION_FILE)
      ? fs.readFileSync(INSTALLED_VERSION_FILE, 'utf8').trim() || null
      : null

    return {
      hostname: os.hostname(),
      timezone,
      ntpEnabled,
      ntpSynced,
      currentTime: new Date().toISOString(),
      installedVersion,
      nextCheckinAt: getNextCheckin(),
      wifiBlocked: await isWifiRadioBlocked(),
      wifi: await getWifiStatus(),
      multicast: getMulticastConfig(),
    }
  })

  /** GET /api/system/timezones — populates the timezone picker */
  app.get('/timezones', async (request, reply) => {
    try {
      const { stdout } = await exec('timedatectl list-timezones')
      return stdout.split('\n').map((s) => s.trim()).filter(Boolean)
    } catch (err) {
      logExecFailure(request.log, 'GET /timezones', err)
      return reply.code(500).send({ error: 'Could not list timezones' })
    }
  })

  /** POST /api/system/timezone */
  app.post('/timezone', async (request, reply) => {
    const body = z.object({ timezone: z.string().min(1) }).safeParse(request.body)
    if (!body.success) return reply.code(400).send({ error: body.error.flatten() })
    try {
      await execFile('sudo', ['-n', 'timedatectl', 'set-timezone', body.data.timezone])
      return { ok: true }
    } catch (err) {
      logExecFailure(request.log, 'POST /timezone', err)
      return reply.code(500).send({ error: 'Could not set timezone — is it a valid zone name?' })
    }
  })

  /** POST /api/system/ntp — { enabled } toggles systemd-timesyncd */
  app.post('/ntp', async (request, reply) => {
    const body = z.object({ enabled: z.boolean() }).safeParse(request.body)
    if (!body.success) return reply.code(400).send({ error: body.error.flatten() })
    try {
      await execFile('sudo', ['-n', 'timedatectl', 'set-ntp', body.data.enabled ? 'true' : 'false'])
      return { ok: true }
    } catch (err) {
      logExecFailure(request.log, 'POST /ntp', err)
      return reply.code(500).send({ error: 'Could not change the NTP setting' })
    }
  })

  /**
   * POST /api/system/datetime — manual override, only meaningful (and only
   * accepted by timedatectl) while NTP is off; the frontend only shows this
   * picker in that state, but this doesn't re-check it server-side since
   * timedatectl itself already refuses the change and surfaces a clear error.
   */
  app.post('/datetime', async (request, reply) => {
    const body = z.object({ isoDatetime: z.string().min(1) }).safeParse(request.body)
    if (!body.success) return reply.code(400).send({ error: body.error.flatten() })

    // isoDatetime comes straight from an HTML <input type="datetime-local">
    // (SystemPanel.tsx) — a NAIVE local wall-clock string with no timezone,
    // e.g. "2026-07-29T09:38". This used to go through `new Date(...)`
    // (which treats a timezone-less string as local time, per the JS spec)
    // and then `.toISOString()` (which converts TO UTC) before handing it to
    // `timedatectl set-time` — but set-time interprets its argument as LOCAL
    // time too, not UTC. That silently applied the zone's UTC offset a
    // second time on the way into a command that already expected local
    // time. Confirmed live: setting 9:38 AM in America/New_York (UTC-4)
    // resulted in the clock reading 1:38 PM — exactly a 4-hour error, the
    // zone's own offset. Fix: validate and reformat the string directly, no
    // Date object and no timezone conversion in either direction — the
    // wall-clock digits the user typed are exactly what should reach
    // timedatectl, untouched.
    const match = body.data.isoDatetime.match(/^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})(:\d{2})?$/)
    if (!match) return reply.code(400).send({ error: 'Invalid date/time' })
    const formatted = `${match[1]} ${match[2]}${match[3] ?? ':00'}`

    try {
      await execFile('sudo', ['-n', 'timedatectl', 'set-time', formatted])
      return { ok: true }
    } catch (err) {
      logExecFailure(request.log, 'POST /datetime', err)
      return reply.code(500).send({ error: 'Could not set the date/time — disable NTP first if it\'s still on.' })
    }
  })

  /** POST /api/system/hostname */
  app.post('/hostname', async (request, reply) => {
    // Was `^[a-z0-9-]{1,63}$` — looser than what hostnamectl/systemd itself
    // accepts (RFC 1123: no leading/trailing hyphen). A value that passed
    // this validation could still get rejected by `hostnamectl` downstream,
    // surfacing as a generic "Could not set the hostname" with no clue why —
    // confirmed as the likely cause of exactly that QA report.
    const body = z.object({ hostname: z.string().regex(/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/i, 'Letters, numbers, hyphens only — cannot start or end with a hyphen') }).safeParse(request.body)
    if (!body.success) return reply.code(400).send({ error: body.error.flatten() })
    try {
      await execFile('sudo', ['-n', 'hostnamectl', 'set-hostname', body.data.hostname])
      return { ok: true, note: 'Some services may need a reboot to pick this up everywhere.' }
    } catch (err) {
      logExecFailure(request.log, 'POST /hostname', err)
      return reply.code(500).send({ error: 'Could not set the hostname' })
    }
  })

  /** GET /api/system/wifi/scan */
  app.get('/wifi/scan', async (request, reply) => {
    try {
      return await scanWifi()
    } catch (err) {
      if ((err as Error)?.message === 'WIFI_BLOCKED') {
        return reply.code(409).send({ error: 'Wi-Fi radio is disabled — set a Wi-Fi country below first, then try scanning again.', wifiBlocked: true })
      }
      logExecFailure(request.log, 'GET /wifi/scan', err)
      return reply.code(500).send({ error: 'Could not scan for networks — is a Wi-Fi adapter present?' })
    }
  })

  /**
   * POST /api/system/wifi/country — sets the regulatory domain, which is
   * also what actually clears the rfkill soft-block (see
   * isWifiRadioBlocked above) — a device that's never been through this
   * can't scan or join a network at all until it's set. Standalone from
   * wifi/connect below so it can be applied once, independent of joining
   * any particular network.
   */
  app.post('/wifi/country', async (request, reply) => {
    const body = z.object({ countryCode: z.string().length(2) }).safeParse(request.body)
    if (!body.success) return reply.code(400).send({ error: body.error.flatten() })
    try {
      await execFile('sudo', ['-n', 'raspi-config', 'nonint', 'do_wifi_country', body.data.countryCode.toUpperCase()])
      return { ok: true }
    } catch (err) {
      logExecFailure(request.log, 'POST /wifi/country', err)
      return reply.code(500).send({ error: 'Could not set the Wi-Fi country' })
    }
  })

  /**
   * Deletes any existing NetworkManager connection profile(s) matching this
   * SSID before (re)joining it. Needed because `raspi-config nonint
   * do_wifi_ssid_passphrase` — and the `nmcli device wifi connect` it uses
   * under the hood on Bookworm/Trixie — reuses an existing profile by SSID
   * name rather than overwriting its stored password: confirmed live that a
   * network typed in with a fresh password kept failing when a prior
   * attempt (e.g. one submitted with a blank password) had already created
   * a broken profile of the same name — the new password was silently
   * never applied, and the same broken profile just got reactivated every
   * time. Best-effort: a device joining this SSID for the first time has
   * nothing to delete, so a "no such connection" failure here is expected,
   * not logged as an error.
   */
  async function forgetExistingProfile(ssid: string): Promise<void> {
    try {
      const { stdout } = await exec('nmcli -t -f NAME,TYPE connection show 2>/dev/null')
      const names = stdout.split('\n')
        .map((line) => line.split(':'))
        .filter(([name, type]) => name === ssid && type === '802-11-wireless')
        .map(([name]) => name)
      for (const name of names) {
        await execFile('sudo', ['-n', 'nmcli', 'connection', 'delete', name]).catch(() => {})
      }
    } catch {
      // nmcli not present/usable — nothing to clean up, do_wifi_ssid_passphrase below is a no-op too.
    }
  }

  /**
   * POST /api/system/wifi/connect — raspi-config's nonint helper handles
   * both networking backends (dhcpcd+wpa_supplicant on Bullseye,
   * NetworkManager on Bookworm/Trixie) itself, so this doesn't need its own
   * per-backend branching the way scanWifi above does.
   */
  app.post('/wifi/connect', async (request, reply) => {
    const body = z.object({
      ssid: z.string().min(1).max(32),
      password: z.string().min(8).max(63).optional(),
      countryCode: z.string().length(2).optional(),
    }).safeParse(request.body)
    if (!body.success) return reply.code(400).send({ error: body.error.flatten() })

    if (!body.data.countryCode && await isWifiRadioBlocked()) {
      return reply.code(409).send({ error: 'Wi-Fi radio is disabled — set a Wi-Fi country first, then try joining again.', wifiBlocked: true })
    }

    if (body.data.countryCode) {
      try {
        await execFile('sudo', ['-n', 'raspi-config', 'nonint', 'do_wifi_country', body.data.countryCode.toUpperCase()])
      } catch (err) {
        logExecFailure(request.log, 'POST /wifi/connect country', err)
        return reply.code(500).send({ error: 'Could not set the Wi-Fi country' })
      }
    }

    // Fire-and-forget from here on — same reasoning as /firmware/upload and
    // /factory-reset above, but confirmed live for a different concrete
    // reason: if this device was reachable via its OWN setup hotspot (the
    // common case), joining a DIFFERENT network can drop that hotspot —
    // and the interface carrying THIS request — before do_wifi_ssid_
    // passphrase (and the response after it) ever finished. That raced the
    // response with the network change and surfaced as "Could not join
    // that network" even on joins that fully succeeded, every time,
    // reproduced across three separate QA rounds. Respond immediately
    // instead — the 15s system-info poll (info.wifi.ssid, already wired up
    // client-side) is the real source of truth for whether the join
    // actually worked, not this request's own round-trip. Trade-off: a
    // genuinely wrong password/SSID no longer surfaces as an explicit error
    // toast, only as "still not connected" — acceptable since a false error
    // on a successful join was strictly worse and happened far more often.
    forgetExistingProfile(body.data.ssid)
      .then(() => execFile('sudo', ['-n', 'raspi-config', 'nonint', 'do_wifi_ssid_passphrase', body.data.ssid, body.data.password ?? '']))
      .catch((err) => logExecFailure(request.log, 'POST /wifi/connect join', err))

    return { ok: true, message: `Joining "${body.data.ssid}"… this can take a few seconds.` }
  })

  /** GET /api/system/network-interfaces — populates the multicast interface picker */
  app.get('/network-interfaces', async () => listNetworkInterfaces())

  /**
   * POST /api/system/multicast — the standalone-mode equivalent of the
   * cloud's per-device multicast fields (see the SaaS web app's
   * EditDeviceModal). Writes the same MULTICAST_* config.env keys sync.sh's
   * self-update path writes; player.sh already re-sources config.env every
   * ~30s and reacts to a change on its own (see its start_multicast), so
   * this needs no restart/reload of anything to take effect.
   */
  app.post('/multicast', async (request, reply) => {
    const body = z.object({
      enabled: z.boolean(),
      address: z.string().min(1).optional(),
      port: z.number().int().min(1).max(65535).optional(),
      interface: z.string().optional(),
    }).refine((v) => !v.enabled || (v.address && v.port), {
      message: 'Address and port are required when multicast is enabled',
    }).safeParse(request.body)
    if (!body.success) return reply.code(400).send({ error: body.error.flatten() })

    try {
      writeMulticastConfig({
        enabled: body.data.enabled,
        address: body.data.address ?? null,
        port: body.data.port ?? null,
        interface: body.data.interface ?? null,
      })
      return { ok: true }
    } catch (err) {
      logExecFailure(request.log, 'POST /multicast', err)
      return reply.code(500).send({ error: 'Could not save multicast settings' })
    }
  })

  /**
   * POST /api/system/firmware/upload — a local, sneakernet-friendly stand-in
   * for the cloud fleet's push-update mechanism, for a device that may have
   * no path to the cloud at all. Reuses sync.sh's own self-update mechanism
   * verbatim (copy the whole extracted tarball over, re-run install.sh as
   * root) rather than inventing a second one — and reuses that mechanism's
   * EXISTING sudoers grant (install.sh already runs as root via a NOPASSWD
   * rule sync.sh's self-update relies on), so this needs no new privileged
   * access of its own.
   */
  app.post('/firmware/upload', async (request, reply) => {
    const data = await request.file()
    if (!data) return reply.code(400).send({ error: 'No file in request' })
    if (!data.filename.endsWith('.tar.gz')) return reply.code(400).send({ error: 'Expected a .tar.gz release tarball' })

    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sitestream-update-'))
    const tarballPath = path.join(tmpDir, 'release.tar.gz')

    try {
      await new Promise<void>((resolve, reject) => {
        const ws = fs.createWriteStream(tarballPath)
        data.file.pipe(ws)
        ws.on('finish', resolve)
        ws.on('error', reject)
        data.file.on('error', reject)
      })

      await execFile('tar', ['-xzf', tarballPath, '-C', tmpDir])

      if (!fs.existsSync(path.join(tmpDir, 'sync.sh')) || !fs.existsSync(path.join(tmpDir, 'install.sh'))) {
        return reply.code(400).send({ error: 'That tarball is missing sync.sh/install.sh — not a valid SiteStream release.' })
      }

      for (const f of fs.readdirSync(tmpDir)) {
        if (f.endsWith('.sh')) fs.chmodSync(path.join(tmpDir, f), 0o755)
      }
      fs.cpSync(tmpDir, SITESTREAM_DIR, { recursive: true, force: true })

      // The cloud path always knows its version (a PiRelease's own `version`
      // field) — a locally uploaded file has no such label attached, so the
      // uploaded FILENAME is the best available stand-in (matches the
      // sitestream-pi-client-<version>.tar.gz convention releases already
      // use). Written BEFORE the install.sh re-run below, same reasoning as
      // sync.sh's own self-update: if install.sh hangs or fails, "what did I
      // just upload" has still been recorded regardless.
      fs.writeFileSync(INSTALLED_VERSION_FILE, data.filename.replace(/\.tar\.gz$/i, ''))

      // Fire-and-forget — install.sh (apt-get, systemd, npm install for
      // pi-portal) can take a while and may restart this very process
      // (sitestream-portal.service) partway through; this request just
      // acknowledges the upload, it doesn't wait for install.sh to finish.
      execFile('sudo', ['-n', 'bash', path.join(SITESTREAM_DIR, 'install.sh'), getApiUrl(), getAppUrl()])
        .catch((err) => logExecFailure(request.log, 'POST /firmware/upload install.sh re-run', err))

      return { ok: true, message: 'Upload accepted — installing now. This device may restart services or reboot during the update.' }
    } catch (err) {
      logExecFailure(request.log, 'POST /firmware/upload extract', err)
      return reply.code(400).send({ error: 'Could not extract that file — is it a valid .tar.gz?' })
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true })
    }
  })

  /**
   * POST /api/system/factory-reset — the local-portal equivalent of the
   * cloud's Factory Reset action, for a device with no cloud connection (or
   * one being reset before it's ever claimed). Runs factory-reset.sh
   * verbatim rather than reimplementing its steps here — see that script's
   * own header comment for why it exists as a single source of truth.
   *
   * Deliberately has NO "release this device" option: that's a cloud-side
   * Device-record deletion this local script has no way to perform (see
   * factory-reset.sh's own comment on that boundary) — un-claiming a device
   * still has to happen from the SaaS/Platform Admin side.
   */
  app.post('/factory-reset', async (request, reply) => {
    const body = z.object({ forgetWifi: z.boolean().default(false) }).safeParse(request.body)
    if (!body.success) return reply.code(400).send({ error: body.error.flatten() })

    const args = [path.join(SITESTREAM_DIR, 'factory-reset.sh'), '--yes']
    if (body.data.forgetWifi) args.push('--forget-wifi')

    // Fire-and-forget, same shape as /firmware/upload above — factory-reset.sh
    // restarts sitestream-portal.service itself partway through (to release
    // the sqlite file it just deleted), which would kill this very request
    // if awaited.
    execFile('bash', args)
      .then(() => {
        // Forgetting Wi-Fi can leave the radio stuck until a full reboot, not
        // just a service restart (factory-reset.sh's own --forget-wifi exit
        // message says as much). Nobody's at a terminal on a field unit to
        // read that suggestion and act on it, so mirror sync.sh's own
        // cloud-triggered reset path and reboot automatically instead.
        if (body.data.forgetWifi) return execFile('sudo', ['-n', 'systemctl', 'reboot'])
      })
      .catch((err) => logExecFailure(request.log, 'POST /factory-reset', err))

    return {
      ok: true,
      message: body.data.forgetWifi
        ? 'Factory reset started — this device will forget its Wi-Fi network and reboot in a few seconds.'
        : 'Factory reset started — this device is restarting its services now.',
    }
  })
}
