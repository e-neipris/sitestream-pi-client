import { FastifyInstance } from 'fastify'
import { z } from 'zod'
import crypto from 'crypto'
import { schedules, videoFiles } from '../db'
import { regenerateScheduleFile } from '../scheduleWriter'
import { ensureMulticastTranscodeQueued } from '../multicastTranscode'

const TIME_RE = /^([01]\d|2[0-3]):([0-5]\d)$/

const createSchema = z.object({
  videoFileId: z.string().min(1),
  startTime: z.string().regex(TIME_RE, 'Must be HH:MM (24h)'),
  endTime: z.string().regex(TIME_RE, 'Must be HH:MM (24h)'),
  daysOfWeek: z.array(z.number().int().min(0).max(6)).default([]),
  validFrom: z.string().datetime().optional().nullable(),
  validUntil: z.string().datetime().optional().nullable(),
  priority: z.number().int().min(0).default(0),
  label: z.string().max(100).optional().nullable(),
})

const updateSchema = createSchema.partial()

function serialize(row: ReturnType<typeof schedules.get>) {
  if (!row) return null
  const file = videoFiles.get(row.video_file_id)
  return {
    id: row.id,
    videoFileId: row.video_file_id,
    startTime: row.start_time,
    endTime: row.end_time,
    daysOfWeek: JSON.parse(row.days_of_week) as number[],
    validFrom: row.valid_from,
    validUntil: row.valid_until,
    priority: row.priority,
    label: row.label,
    videoFile: file ? { id: file.id, filename: file.filename, durationSeconds: file.duration_seconds } : null,
    // No zones in standalone mode — kept null (not omitted) so the reused
    // web UI's `s.zone?.group?.name` optional-chaining reads render as
    // blank instead of needing a special-cased standalone layout.
    zone: null,
  }
}

export default async function scheduleRoutes(app: FastifyInstance) {
  app.get('/', async () => schedules.list().map(serialize))

  app.post('/', async (request, reply) => {
    const body = createSchema.safeParse(request.body)
    if (!body.success) return reply.code(400).send({ error: body.error.flatten() })

    const file = videoFiles.get(body.data.videoFileId)
    if (!file) return reply.code(404).send({ error: 'Video file not found' })
    if (!file.etag) return reply.code(422).send({ error: 'Video file upload not yet confirmed' })

    const id = crypto.randomUUID()
    schedules.create({
      id,
      videoFileId: body.data.videoFileId,
      startTime: body.data.startTime,
      endTime: body.data.endTime,
      daysOfWeek: body.data.daysOfWeek,
      validFrom: body.data.validFrom ?? null,
      validUntil: body.data.validUntil ?? null,
      priority: body.data.priority,
      label: body.data.label ?? null,
    })
    // The normal-order case (see files.ts's own call to this for the
    // reverse order): a file usually gets scheduled after it's already
    // uploaded, so this is the trigger that actually fires most of the time.
    ensureMulticastTranscodeQueued(body.data.videoFileId)
    regenerateScheduleFile()
    return reply.code(201).send(serialize(schedules.get(id)))
  })

  app.patch('/:id', async (request, reply) => {
    const { id } = request.params as { id: string }
    const body = updateSchema.safeParse(request.body)
    if (!body.success) return reply.code(400).send({ error: body.error.flatten() })

    const existing = schedules.get(id)
    if (!existing) return reply.code(404).send({ error: 'Not found' })

    if (body.data.videoFileId) {
      const file = videoFiles.get(body.data.videoFileId)
      if (!file) return reply.code(404).send({ error: 'Video file not found' })
    }

    schedules.update(id, body.data)
    // Covers a PATCH that repoints this schedule at a different (previously
    // unscheduled) file — the file's own confirm step already tried this
    // once, but at that time it may not have been on any schedule yet.
    ensureMulticastTranscodeQueued(body.data.videoFileId ?? existing.video_file_id)
    regenerateScheduleFile()
    return serialize(schedules.get(id))
  })

  app.delete('/:id', async (request, reply) => {
    const { id } = request.params as { id: string }
    const existing = schedules.get(id)
    if (!existing) return reply.code(404).send({ error: 'Not found' })

    schedules.delete(id)
    regenerateScheduleFile()
    return reply.code(204).send()
  })
}
