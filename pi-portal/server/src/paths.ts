import path from 'path'
import fs from 'fs'

// Deployed layout on the Pi: ~/sitestream/pi-portal/server/dist/index.js —
// three levels up from the built file's own directory gets back to
// ~/sitestream, where config.env/videos/schedule.json already live
// (sync.sh/player.sh's own directory). SITESTREAM_DIR env var overrides this
// for local dev/testing against a scratch directory instead of a real Pi
// layout.
export const SITESTREAM_DIR = process.env.SITESTREAM_DIR ?? path.resolve(__dirname, '../../../..')
export const VIDEO_DIR = path.join(SITESTREAM_DIR, 'videos')
export const SCHEDULE_FILE = path.join(SITESTREAM_DIR, 'schedule.json')
export const CONFIG_FILE = path.join(SITESTREAM_DIR, 'config.env')
export const DB_FILE = path.join(SITESTREAM_DIR, 'pi-portal.sqlite3')

/** Minimal KEY=VALUE parser matching config.env's own format (no quoting, one per line). */
function parseConfigEnv(): Record<string, string> {
  if (!fs.existsSync(CONFIG_FILE)) return {}
  const out: Record<string, string> = {}
  for (const line of fs.readFileSync(CONFIG_FILE, 'utf8').split('\n')) {
    const match = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/)
    if (match) out[match[1]] = match[2]
  }
  return out
}

/**
 * True once sync.sh has provisioned a real device token — meaning this
 * device has been claimed into the cloud (see sync.sh's zero-touch
 * provisioning). The local portal goes read-only at that point: letting it
 * keep writing schedule.json/videos would race sync.sh's own cloud-driven
 * writes to the exact same files.
 */
export function isCloudManaged(): boolean {
  const token = parseConfigEnv().DEVICE_TOKEN
  return !!token && token.trim().length > 0
}

export function getAppUrl(): string {
  return parseConfigEnv().APP_URL ?? 'https://app.sitestream.app'
}

export function getApiUrl(): string {
  return parseConfigEnv().API_URL ?? 'https://api.sitestream.app'
}

export function getSerialNumber(): string | null {
  try {
    const cpuinfo = fs.readFileSync('/proc/cpuinfo', 'utf8')
    const match = cpuinfo.match(/^Serial\s*:\s*(\S+)/m)
    return match ? match[1] : null
  } catch {
    return null
  }
}

export function ensureDirs(): void {
  fs.mkdirSync(VIDEO_DIR, { recursive: true })
}
