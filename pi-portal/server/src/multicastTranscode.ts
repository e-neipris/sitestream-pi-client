import { spawn } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { videoFiles, schedules } from './db'
import { VIDEO_DIR, isCloudManaged, parseConfigEnv } from './paths'
import { regenerateScheduleFile } from './scheduleWriter'

/**
 * Standalone-mode equivalent of the SaaS API's multicastTranscode.ts, run
 * locally on the Pi instead of server-side — there's no S3/cloud transcode
 * pipeline to lean on for a device that's never been claimed, so this device
 * has to produce its own MPEG-2 variant if it wants multicast output at all.
 * Same gating intent as the cloud version, just with "this device" standing
 * in for "a zone with a multicast-enabled device" (standalone mode has
 * exactly one device and no zones): a file only ever gets transcoded if
 * multicast is actually enabled AND the file is actually on the schedule —
 * uploading media to a non-multicast device, or scheduling media on a device
 * with multicast off, both leave the file alone. See ensureMulticastTranscodeQueued
 * for where those two conditions are actually checked.
 *
 * Deliberately does nothing at all once isCloudManaged() — see index.ts's
 * own read-only gate on files/schedules routes for why triggers below never
 * fire in that state anyway, but the poll loop (startMulticastTranscodeJob)
 * runs regardless of route gating, and needs its own check so a device that
 * was standalone (with leftover PENDING rows) and later got claimed doesn't
 * keep locally transcoding files sync.sh is about to overwrite with the
 * cloud's own transcoded output anyway — wasted Pi CPU at best, a write race
 * with sync.sh's own download-and-rename onto the same filename at worst.
 */
function multicastEnabled(): boolean {
  return parseConfigEnv().MULTICAST_ENABLED === 'true'
}

/** Does this device's own schedule reference this file at all? */
function isOnSchedule(videoFileId: string): boolean {
  return videoFiles.scheduleCount(videoFileId) > 0
}

/**
 * Call after any change that could newly make a file's multicast dependency
 * true — an upload's own confirm step, or the file getting added to (or an
 * existing schedule updated to point at) the schedule. Cheap to call
 * speculatively; only actually queues the first time it's found to be
 * needed. FAILED is re-queueable (e.g. after fixing whatever broke ffmpeg),
 * READY/PENDING/PROCESSING are left alone — see setMulticastPending's own
 * guard for the second half of that.
 */
export function ensureMulticastTranscodeQueued(videoFileId: string): void {
  if (isCloudManaged()) return
  const file = videoFiles.get(videoFileId)
  if (!file) return
  if (file.multicast_transcode_status === 'PENDING' || file.multicast_transcode_status === 'PROCESSING'
    || file.multicast_transcode_status === 'READY') return

  if (!multicastEnabled() || !isOnSchedule(videoFileId)) return

  videoFiles.setMulticastPending(videoFileId)
}

/**
 * Call after multicast gets turned on for this device — every file already
 * scheduled may now need a transcode it never needed before. The more common
 * real-world trigger than a fresh upload: multicast usually gets flipped on
 * for a device that already has content scheduled, not the other way
 * around. Mirrors the cloud API's ensureZoneMulticastTranscodesQueued, with
 * "every distinct scheduled file on this device" standing in for "every
 * distinct scheduled file in this zone."
 */
export function ensureAllScheduledTranscodesQueued(): void {
  if (isCloudManaged()) return
  const fileIds = new Set(schedules.list().map((s) => s.video_file_id))
  for (const id of fileIds) ensureMulticastTranscodeQueued(id)
}

// Identical to the SaaS API's own buildFfmpegArgs (packages/api/src/services/
// multicastTranscode.ts) — same command, confirmed live against real SMARTBOX
// hardware, just local-path-in/local-path-out instead of S3-download/S3-
// upload since standalone mode has no S3 to round-trip through.
function buildFfmpegArgs(inputPath: string, outputPath: string): string[] {
  return [
    '-y',
    '-i', inputPath,
    '-map', '0:v:0',
    '-map', '0:a:0?',
    '-vf', 'fps=30,scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2',
    '-c:v', 'mpeg2video',
    '-pix_fmt', 'yuv420p',
    '-b:v', '5000k',
    '-maxrate', '6000k',
    '-bufsize', '1835k',
    '-g', '15',
    '-bf', '2',
    '-qmin:v', '2',
    '-qmax:v', '31',
    '-c:a', 'mp2',
    '-b:a', '192k',
    '-ar', '48000',
    '-ac', '2',
    '-f', 'mpeg',
    outputPath,
  ]
}

const FFMPEG_TIMEOUT_MS = 30 * 60 * 1000 // safety cap — real clips run well under this

function runFfmpeg(args: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    // Run niced to the lowest CPU priority, not plain `ffmpeg` — unlike the
    // SaaS API (a server with no other real-time work), this runs on the
    // same Pi that's simultaneously decoding/playing video through VLC over
    // HDMI and multicast. An un-niced transcode competing for the same CPU
    // cores is exactly the kind of contention that showed up as visible
    // playback stutter in earlier testing on this hardware — `nice -n 19`
    // means the scheduler only gives this process CPU time playback isn't
    // currently using, at the cost of the transcode itself taking longer.
    const child = spawn('nice', ['-n', '19', 'ffmpeg', ...args], { timeout: FFMPEG_TIMEOUT_MS })
    let stderr = ''
    child.stderr.on('data', (chunk) => { stderr += chunk.toString() })
    child.on('error', reject) // e.g. ffmpeg not installed — see install.sh
    child.on('close', (code) => {
      if (code === 0) resolve()
      else reject(new Error(`ffmpeg exited ${code}: ${stderr.slice(-2000)}`))
    })
  })
}

/** Processes exactly one PENDING file per call — see startMulticastTranscodeJob. */
export async function runNextMulticastTranscode(): Promise<void> {
  if (isCloudManaged()) return
  const file = videoFiles.findNextPendingMulticast()
  if (!file) return

  // Claim it immediately so a second poll tick never picks up the same row
  // while this one is still working (mirrors the SaaS's updateMany claim).
  if (!videoFiles.claimMulticastPending(file.id)) return

  const inputPath = path.join(VIDEO_DIR, `${file.id}.mp4`)
  const outputPath = path.join(VIDEO_DIR, `${file.id}-multicast.mpg`)
  const tmpOutputPath = `${outputPath}.tmp`

  try {
    if (!fs.existsSync(inputPath)) {
      throw new Error(`Source file not on disk: ${inputPath}`)
    }
    await runFfmpeg(buildFfmpegArgs(inputPath, tmpOutputPath))
    // Atomic rename, not a direct write to outputPath — player.sh (via
    // start_multicast's own -f check) could otherwise pick up a
    // half-written file mid-transcode and try to broadcast it.
    fs.renameSync(tmpOutputPath, outputPath)
    videoFiles.setMulticastReady(file.id)
    // Unlike the SaaS's manifest.ts (built fresh on every device poll, so a
    // status change is just visible on the next request with nothing to
    // proactively push), schedule.json is a file player.sh reads as-is —
    // nothing re-derives it from the DB on its own. Without this, a file
    // finishing its transcode would sit at READY with the right bytes on
    // disk, but schedule.json's multicastLocalPath would stay null until
    // some unrelated upload/schedule change happened to regenerate it.
    regenerateScheduleFile()
  } catch (err) {
    console.error(`Multicast transcode failed for VideoFile ${file.id}:`, err)
    videoFiles.setMulticastFailed(file.id, err instanceof Error ? err.message : String(err))
    fs.rmSync(tmpOutputPath, { force: true })
  }
}

/**
 * Sweeps the current schedule and queues transcodes for whatever's on it,
 * if multicast is enabled. The targeted triggers above only fire on a
 * *change* (an upload confirming, a schedule being created, multicast being
 * turned on) — this covers every other way the "multicast enabled AND on
 * schedule" state could already be true without ever having fired one of
 * those (a fresh self-update onto a device that already reached this state
 * under old code with no transcode support at all, a direct DB edit, etc.).
 * Run once at startup, not on every poll tick — cheap, but pointless to
 * repeat once everything's already been queued at least once.
 */
function backfillMulticastTranscodeQueue(): void {
  if (isCloudManaged() || !multicastEnabled()) return
  ensureAllScheduledTranscodesQueued()
}

const POLL_INTERVAL_MS = 30 * 1000

/**
 * One transcode at a time, polled — same shape as the SaaS API's own
 * startMulticastTranscodeJob (setInterval, no queue library). Serial on
 * purpose, doubly so here: a Raspberry Pi has far less CPU headroom than the
 * API server this was mirrored from, and this device may be actively
 * decoding/playing video the entire time (see runFfmpeg's own nice -n 19).
 */
export function startMulticastTranscodeJob(): void {
  try {
    backfillMulticastTranscodeQueue()
  } catch (err) {
    console.error('Multicast transcode backfill failed:', err)
  }
  runNextMulticastTranscode().catch((err) => console.error('Multicast transcode poll failed:', err))
  setInterval(() => {
    runNextMulticastTranscode().catch((err) => console.error('Multicast transcode poll failed:', err))
  }, POLL_INTERVAL_MS)
}
