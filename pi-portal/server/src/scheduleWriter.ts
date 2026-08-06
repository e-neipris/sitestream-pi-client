import fs from 'fs'
import path from 'path'
import crypto from 'crypto'
import { SCHEDULE_FILE, VIDEO_DIR } from './paths'
import { schedules, videoFiles } from './db'

/**
 * Regenerates schedule.json in the exact shape sync.sh's own step 4 writes
 * (see sync.sh: `jq --arg videoDir ... '{manifestVersion, generatedAt,
 * schedule: [...]}'`) — player.sh only ever reads startTime/endTime/
 * daysOfWeek/validFrom/validUntil/priority/localPath/multicastLocalPath from
 * each entry (see get_current_video() in player.sh), so matching those
 * fields exactly means player.sh needs zero changes to work against a
 * locally-produced schedule. localPath always resolves to
 * "<videoDir>/<videoId>.mp4", matching how sync.sh names cached videos
 * regardless of the original upload's extension — same convention, so the
 * two producers stay interchangeable.
 */
export function regenerateScheduleFile(): void {
  const rows = schedules.list()
  const entries = rows.map((s) => {
    const file = videoFiles.get(s.video_file_id)
    return {
      videoId: s.video_file_id,
      filename: file?.filename ?? '',
      etag: file?.etag ?? '',
      startTime: s.start_time,
      endTime: s.end_time,
      daysOfWeek: JSON.parse(s.days_of_week) as number[],
      validFrom: s.valid_from,
      validUntil: s.valid_until,
      priority: s.priority,
      label: s.label,
      localPath: path.join(VIDEO_DIR, `${s.video_file_id}.mp4`),
      // null for the vast majority of entries — only set once
      // multicastTranscode.ts has actually produced this file's MPEG-2
      // variant (see its runNextMulticastTranscode). Same convention as
      // sync.sh's own multicastLocalPath field, so player.sh's
      // get_current_video needs no changes to consume either producer.
      multicastLocalPath: file?.multicast_transcode_status === 'READY'
        ? path.join(VIDEO_DIR, `${s.video_file_id}-multicast.mpg`)
        : null,
    }
  })

  const manifest = {
    manifestVersion: crypto.createHash('sha256').update(JSON.stringify(entries)).digest('hex'),
    generatedAt: new Date().toISOString(),
    schedule: entries,
  }

  const tmp = `${SCHEDULE_FILE}.tmp`
  fs.writeFileSync(tmp, JSON.stringify(manifest, null, 2))
  fs.renameSync(tmp, SCHEDULE_FILE)
}
