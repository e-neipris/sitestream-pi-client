import { FastifyInstance, FastifyBaseLogger } from 'fastify'
import { z } from 'zod'
import { exec as execCb, execFile as execFileCb } from 'child_process'
import { promisify } from 'util'
import fs from 'fs'
import os from 'os'
import path from 'path'
import { SITESTREAM_DIR, getApiUrl, getAppUrl } from '../paths'

const exec = promisify(execCb)
const execFile = promisify(execFileCb)

const INSTALLED_VERSION_FILE = path.join(SITESTREAM_DIR, '.installed_version')

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

async function scanWifi(): Promise<{ ssid: string; signal: number }[]> {
  if (await isWifiRadioBlocked()) {
    throw new Error('WIFI_BLOCKED')
  }

  // Prefer NetworkManager (Bookworm/Trixie's default) — falls back to a raw
  // `iw` scan for dhcpcd+wpa_supplicant setups (Bullseye's default). Neither
  // call takes any user-supplied input, so a plain shell string is fine here
  // — no injection surface, unlike wifi/connect below.
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

  const iface = await detectWifiInterface()
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
  return stdout.split('\n')
    .filter((line) => line.trim().startsWith('SSID:'))
    .map((line) => line.replace(/^\s*SSID:\s*/, '').trim())
    .filter((ssid) => ssid && !seen.has(ssid) && seen.add(ssid))
    .map((ssid) => ({ ssid, signal: 0 }))
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
      wifiBlocked: await isWifiRadioBlocked(),
      wifi: await getWifiStatus(),
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

    const dt = new Date(body.data.isoDatetime)
    if (isNaN(dt.getTime())) return reply.code(400).send({ error: 'Invalid date/time' })
    const formatted = dt.toISOString().replace('T', ' ').replace(/\.\d+Z$/, '')

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
    const body = z.object({ hostname: z.string().regex(/^[a-z0-9-]{1,63}$/i, 'Letters, numbers, hyphens only') }).safeParse(request.body)
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

    try {
      if (body.data.countryCode) {
        await execFile('sudo', ['-n', 'raspi-config', 'nonint', 'do_wifi_country', body.data.countryCode.toUpperCase()])
      }
      await execFile('sudo', ['-n', 'raspi-config', 'nonint', 'do_wifi_ssid_passphrase', body.data.ssid, body.data.password ?? ''])
      return { ok: true }
    } catch (err) {
      logExecFailure(request.log, 'POST /wifi/connect', err)
      return reply.code(500).send({ error: 'Could not join that network — check the password and try again.' })
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
}
