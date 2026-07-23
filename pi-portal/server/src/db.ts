import Database from 'better-sqlite3'
import { DB_FILE, ensureDirs } from './paths'

ensureDirs()
export const db = new Database(DB_FILE)
db.pragma('journal_mode = WAL')

db.exec(`
  CREATE TABLE IF NOT EXISTS video_files (
    id TEXT PRIMARY KEY,
    filename TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    etag TEXT NOT NULL DEFAULT '',
    duration_seconds INTEGER,
    uploaded_at TEXT NOT NULL,
    version INTEGER NOT NULL DEFAULT 1
  );

  CREATE TABLE IF NOT EXISTS schedules (
    id TEXT PRIMARY KEY,
    video_file_id TEXT NOT NULL REFERENCES video_files(id) ON DELETE CASCADE,
    start_time TEXT NOT NULL,
    end_time TEXT NOT NULL,
    days_of_week TEXT NOT NULL DEFAULT '[]',
    valid_from TEXT,
    valid_until TEXT,
    priority INTEGER NOT NULL DEFAULT 0,
    label TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );

  -- Singleton row (id always 1) — this portal only ever has one operator,
  -- unlike the cloud app's real multi-user auth. Seeded with default
  -- credentials on first run (see auth.ts) since a standalone device ships
  -- with install.sh already having run, with no interactive setup step to
  -- ask an install-time password the way the cloud API's tenant creation does.
  CREATE TABLE IF NOT EXISTS portal_auth (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    username TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    must_change_password INTEGER NOT NULL DEFAULT 1
  );
`)

export interface VideoFileRow {
  id: string
  filename: string
  size_bytes: number
  etag: string
  duration_seconds: number | null
  uploaded_at: string
  version: number
}

export interface ScheduleRow {
  id: string
  video_file_id: string
  start_time: string
  end_time: string
  days_of_week: string
  valid_from: string | null
  valid_until: string | null
  priority: number
  label: string | null
  created_at: string
  updated_at: string
}

export const videoFiles = {
  list: (): VideoFileRow[] => db.prepare('SELECT * FROM video_files ORDER BY uploaded_at DESC').all() as VideoFileRow[],
  get: (id: string): VideoFileRow | undefined =>
    db.prepare('SELECT * FROM video_files WHERE id = ?').get(id) as VideoFileRow | undefined,
  getByFilename: (filename: string): VideoFileRow | undefined =>
    db.prepare('SELECT * FROM video_files WHERE filename = ?').get(filename) as VideoFileRow | undefined,
  upsert: (row: { id: string; filename: string; sizeBytes: number; durationSeconds?: number; version: number }): void => {
    db.prepare(`
      INSERT INTO video_files (id, filename, size_bytes, etag, duration_seconds, uploaded_at, version)
      VALUES (@id, @filename, @sizeBytes, '', @durationSeconds, @uploadedAt, @version)
      ON CONFLICT(id) DO UPDATE SET
        filename = @filename, size_bytes = @sizeBytes, etag = '', duration_seconds = @durationSeconds,
        uploaded_at = @uploadedAt, version = @version
    `).run({
      id: row.id, filename: row.filename, sizeBytes: row.sizeBytes,
      durationSeconds: row.durationSeconds ?? null, uploadedAt: new Date().toISOString(), version: row.version,
    })
  },
  confirmEtag: (id: string, etag: string): void => {
    db.prepare('UPDATE video_files SET etag = ? WHERE id = ?').run(etag, id)
  },
  delete: (id: string): void => {
    db.prepare('DELETE FROM video_files WHERE id = ?').run(id)
  },
  scheduleCount: (id: string): number =>
    (db.prepare('SELECT COUNT(*) as c FROM schedules WHERE video_file_id = ?').get(id) as { c: number }).c,
}

export const schedules = {
  list: (): ScheduleRow[] => db.prepare('SELECT * FROM schedules ORDER BY priority DESC, start_time ASC').all() as ScheduleRow[],
  get: (id: string): ScheduleRow | undefined =>
    db.prepare('SELECT * FROM schedules WHERE id = ?').get(id) as ScheduleRow | undefined,
  create: (row: {
    id: string; videoFileId: string; startTime: string; endTime: string
    daysOfWeek: number[]; validFrom: string | null; validUntil: string | null; priority: number; label: string | null
  }): void => {
    const now = new Date().toISOString()
    db.prepare(`
      INSERT INTO schedules (id, video_file_id, start_time, end_time, days_of_week, valid_from, valid_until, priority, label, created_at, updated_at)
      VALUES (@id, @videoFileId, @startTime, @endTime, @daysOfWeek, @validFrom, @validUntil, @priority, @label, @now, @now)
    `).run({
      id: row.id, videoFileId: row.videoFileId, startTime: row.startTime, endTime: row.endTime,
      daysOfWeek: JSON.stringify(row.daysOfWeek), validFrom: row.validFrom, validUntil: row.validUntil,
      priority: row.priority, label: row.label, now,
    })
  },
  update: (id: string, row: Partial<{
    videoFileId: string; startTime: string; endTime: string
    daysOfWeek: number[]; validFrom: string | null; validUntil: string | null; priority: number; label: string | null
  }>): void => {
    const existing = schedules.get(id)
    if (!existing) return
    const merged = {
      videoFileId: row.videoFileId ?? existing.video_file_id,
      startTime: row.startTime ?? existing.start_time,
      endTime: row.endTime ?? existing.end_time,
      daysOfWeek: row.daysOfWeek ? JSON.stringify(row.daysOfWeek) : existing.days_of_week,
      validFrom: row.validFrom !== undefined ? row.validFrom : existing.valid_from,
      validUntil: row.validUntil !== undefined ? row.validUntil : existing.valid_until,
      priority: row.priority ?? existing.priority,
      label: row.label !== undefined ? row.label : existing.label,
    }
    db.prepare(`
      UPDATE schedules SET video_file_id = @videoFileId, start_time = @startTime, end_time = @endTime,
        days_of_week = @daysOfWeek, valid_from = @validFrom, valid_until = @validUntil,
        priority = @priority, label = @label, updated_at = @now
      WHERE id = @id
    `).run({ ...merged, id, now: new Date().toISOString() })
  },
  delete: (id: string): void => {
    db.prepare('DELETE FROM schedules WHERE id = ?').run(id)
  },
}
