import { FastifyInstance } from 'fastify'
import { z } from 'zod'
import fs from 'fs'
import crypto from 'crypto'
import path from 'path'
import { videoFiles } from '../db'
import { VIDEO_DIR } from '../paths'
import { regenerateScheduleFile } from '../scheduleWriter'

const initiateUploadSchema = z.object({
  filename: z.string().min(1),
  contentType: z.string().optional(),
  sizeBytes: z.number().int().positive(),
  durationSeconds: z.number().int().positive().optional(),
  // Accepted for wire-compatibility with the reused MediaPanel.tsx client
  // (which always sends these) but meaningless here — a standalone device
  // has no zones, and replace-in-place is keyed by filename instead (see
  // handleFileChange's duplicate-detection in MediaPanel.tsx).
  zoneId: z.string().optional(),
  replaceFileId: z.string().optional(),
})

const confirmSchema = z.object({ etag: z.string().min(1) })

function serialize(row: ReturnType<typeof videoFiles.get>) {
  if (!row) return null
  return {
    id: row.id,
    filename: row.filename,
    sizeBytes: row.size_bytes,
    etag: row.etag,
    durationSeconds: row.duration_seconds,
    uploadedAt: row.uploaded_at,
    sourceZoneId: null,
    _count: { schedules: videoFiles.scheduleCount(row.id) },
  }
}

export default async function fileRoutes(app: FastifyInstance) {
  app.get('/', async () => videoFiles.list().map(serialize))

  /**
   * POST /api/files/initiate-upload
   * Cloud equivalent presigns an S3 POST; here there's no S3, so the
   * "presigned post" is just this same server's own /raw-upload endpoint —
   * MediaPanel.tsx's upload flow (initiate -> POST to presignedPost.url ->
   * confirm) doesn't need to know the difference, it just POSTs wherever
   * it's told to.
   */
  app.post('/initiate-upload', async (request, reply) => {
    const body = initiateUploadSchema.safeParse(request.body)
    if (!body.success) return reply.code(400).send({ error: body.error.flatten() })

    const fileId = body.data.replaceFileId ?? crypto.randomUUID()
    const existing = body.data.replaceFileId ? videoFiles.get(body.data.replaceFileId) : undefined
    const version = existing ? existing.version + 1 : 1

    videoFiles.upsert({
      id: fileId,
      filename: body.data.filename,
      sizeBytes: body.data.sizeBytes,
      durationSeconds: body.data.durationSeconds,
      version,
    })

    return reply.code(201).send({
      fileId,
      presignedPost: { url: `/api/files/${fileId}/raw-upload`, fields: {} },
    })
  })

  /**
   * POST /api/files/:id/raw-upload — same-origin stand-in for the cloud's
   * S3 presigned POST. Streams the multipart body straight to
   * <VIDEO_DIR>/<id>.mp4 — that exact filename convention is what
   * sync.sh's own downloads already use, so player.sh (which only ever
   * looks for "<videoDir>/<videoId>.mp4") needs no changes. Responds with
   * an ETag header because MediaPanel.tsx reads
   * `xhr.getResponseHeader('ETag')` after this step completes.
   */
  app.post('/:id/raw-upload', async (request, reply) => {
    const { id } = request.params as { id: string }
    const data = await request.file()
    if (!data) return reply.code(400).send({ error: 'No file in request' })

    const destPath = path.join(VIDEO_DIR, `${id}.mp4`)
    const tmpPath = `${destPath}.tmp`
    const hash = crypto.createHash('md5')
    const writeStream = fs.createWriteStream(tmpPath)

    await new Promise<void>((resolve, reject) => {
      data.file.on('data', (chunk: Buffer) => hash.update(chunk))
      data.file.pipe(writeStream)
      writeStream.on('finish', resolve)
      writeStream.on('error', reject)
      data.file.on('error', reject)
    })

    fs.renameSync(tmpPath, destPath)
    const etag = hash.digest('hex')
    reply.header('ETag', etag)
    return { ok: true }
  })

  app.post('/:id/confirm', async (request, reply) => {
    const { id } = request.params as { id: string }
    const body = confirmSchema.safeParse(request.body)
    if (!body.success) return reply.code(400).send({ error: body.error.flatten() })

    const existing = videoFiles.get(id)
    if (!existing) return reply.code(404).send({ error: 'Not found' })

    videoFiles.confirmEtag(id, body.data.etag.replace(/"/g, ''))
    regenerateScheduleFile()
    return serialize(videoFiles.get(id))
  })

  app.delete('/:id', async (request, reply) => {
    const { id } = request.params as { id: string }
    const existing = videoFiles.get(id)
    if (!existing) return reply.code(404).send({ error: 'Not found' })
    if (videoFiles.scheduleCount(id) > 0) {
      return reply.code(409).send({ error: 'File is referenced by active schedules. Remove schedules first.' })
    }

    videoFiles.delete(id)
    const videoPath = path.join(VIDEO_DIR, `${id}.mp4`)
    fs.rmSync(videoPath, { force: true })
    regenerateScheduleFile()
    return reply.code(204).send()
  })
}
