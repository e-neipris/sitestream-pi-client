import crypto from 'crypto'
import { db } from './db'

// Ships with the portal — install.sh already ran with no interactive setup
// step to ask a real password during, so a known default is the only option;
// must_change_password (below) is what forces it to not stay this way.
const DEFAULT_USERNAME = 'admin'
const DEFAULT_PASSWORD = 'SiteStream'

function hashWithSalt(password: string, salt: string): string {
  return crypto.scryptSync(password, salt, 64).toString('hex')
}

function makeSaltedHash(password: string): string {
  const salt = crypto.randomBytes(16).toString('hex')
  return `${salt}:${hashWithSalt(password, salt)}`
}

function verifyAgainstHash(password: string, stored: string): boolean {
  const [salt, hash] = stored.split(':')
  if (!salt || !hash) return false
  const candidate = Buffer.from(hashWithSalt(password, salt), 'hex')
  const expected = Buffer.from(hash, 'hex')
  return candidate.length === expected.length && crypto.timingSafeEqual(candidate, expected)
}

interface PortalAuthRow {
  id: number
  username: string
  password_hash: string
  must_change_password: number
}

function getAuthRow(): PortalAuthRow {
  const existing = db.prepare('SELECT * FROM portal_auth WHERE id = 1').get() as PortalAuthRow | undefined
  if (existing) return existing
  db.prepare(`
    INSERT INTO portal_auth (id, username, password_hash, must_change_password)
    VALUES (1, ?, ?, 1)
  `).run(DEFAULT_USERNAME, makeSaltedHash(DEFAULT_PASSWORD))
  return db.prepare('SELECT * FROM portal_auth WHERE id = 1').get() as PortalAuthRow
}

export function verifyLogin(username: string, password: string): { ok: boolean; mustChangePassword: boolean } {
  const row = getAuthRow()
  // Case-insensitive on purpose — see the matching fix on the cloud API's
  // own login, which had the same bug for email/username.
  if (row.username.toLowerCase() !== username.trim().toLowerCase()) return { ok: false, mustChangePassword: false }
  if (!verifyAgainstHash(password, row.password_hash)) return { ok: false, mustChangePassword: false }
  return { ok: true, mustChangePassword: !!row.must_change_password }
}

export function changePassword(currentPassword: string, newPassword: string): boolean {
  const row = getAuthRow()
  if (!verifyAgainstHash(currentPassword, row.password_hash)) return false
  db.prepare('UPDATE portal_auth SET password_hash = ?, must_change_password = 0 WHERE id = 1').run(makeSaltedHash(newPassword))
  return true
}

export function mustChangePassword(): boolean {
  return !!getAuthRow().must_change_password
}

// ── Sessions ────────────────────────────────────────────────────────────────
// In-memory only, not persisted — a server restart logging everyone out is a
// fine tradeoff for a single-device local portal with no remote/multi-
// instance concerns, and avoids another table (and cleanup job) for
// something this low-stakes to get wrong.
const SESSION_TTL_MS = 24 * 60 * 60 * 1000
const sessions = new Map<string, number>() // token -> expiresAt

export function createSession(): string {
  const token = crypto.randomBytes(32).toString('hex')
  sessions.set(token, Date.now() + SESSION_TTL_MS)
  return token
}

export function isValidSession(token: string | undefined): boolean {
  if (!token) return false
  const expiresAt = sessions.get(token)
  if (!expiresAt) return false
  if (Date.now() > expiresAt) {
    sessions.delete(token)
    return false
  }
  return true
}

export function destroySession(token: string): void {
  sessions.delete(token)
}

export function bearerToken(request: { headers: { authorization?: string } }): string | undefined {
  const header = request.headers.authorization
  return header?.startsWith('Bearer ') ? header.slice(7) : undefined
}

/**
 * Gates everything under /api/system — the routes that can join Wi-Fi
 * networks, change the clock/timezone, or push a firmware update, unlike
 * the file/schedule routes this portal started with (still open by design,
 * see index.ts). Also blocks all of it while still on the default
 * password, not just login — "must change it" only means something if
 * nothing sensitive is reachable until it happens.
 */
export async function requirePortalAuth(
  request: { headers: { authorization?: string } },
  reply: { code: (n: number) => { send: (body: unknown) => void } },
): Promise<void> {
  const token = bearerToken(request)
  if (!isValidSession(token)) {
    reply.code(401).send({ error: 'Not authenticated' })
    return
  }
  if (mustChangePassword()) {
    reply.code(403).send({ error: 'You must change the default password before using this.', mustChangePassword: true })
  }
}
