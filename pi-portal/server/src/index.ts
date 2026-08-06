import path from 'path'
import Fastify from 'fastify'
import cors from '@fastify/cors'
import multipart from '@fastify/multipart'
import fastifyStatic from '@fastify/static'
import fileRoutes from './routes/files'
import scheduleRoutes from './routes/schedules'
import deviceInfoRoutes from './routes/deviceInfo'
import authRoutes from './routes/auth'
import systemRoutes from './routes/system'
import { isCloudManaged } from './paths'
import { requirePortalAuth } from './auth'
import { startMulticastTranscodeJob } from './multicastTranscode'
import './db' // creates the schema/tables as a side effect on first import

const PORT = Number(process.env.PORT ?? 8080)
const HOST = process.env.HOST ?? '0.0.0.0'

async function start() {
  const app = Fastify({ logger: { level: 'info' } })

  app.register(cors, { origin: true })
  app.register(multipart, { limits: { fileSize: 5_368_709_120 } }) // 5 GB, matches the cloud API's own limit

  // The whole portal requires login now (not just the System tab it started
  // with) — every /api/* route except login/change-password/logout itself
  // and the health check. Runs before the cloud-managed check below: "are
  // you even allowed in" comes before "is this specific thing blocked."
  app.addHook('preHandler', async (request, reply) => {
    if (!request.url.startsWith('/api/')) return
    if (request.url.startsWith('/api/auth/')) return
    if (request.url === '/api/health') return
    // POST /api/files/:id/raw-upload is this server's own same-origin
    // stand-in for a genuine S3 presigned POST (see files.ts) — MediaPanel.tsx
    // deliberately sends that step with no Authorization header, exactly as
    // it would for a real presigned URL, so this blanket check can't apply
    // here. The unguessable fileId embedded in the URL — handed out only by
    // an already-authenticated initiate-upload call — is the credential,
    // same as a presigned URL's signature.
    if (request.method === 'POST' && /^\/api\/files\/[^/]+\/raw-upload$/.test(request.url)) return
    return requirePortalAuth(request, reply)
  })

  // Once claimed into the cloud (see paths.ts's isCloudManaged), sync.sh
  // owns schedule.json/videos from here on — blocking mutations here is
  // what actually prevents the two producers (this portal and sync.sh) from
  // racing each other on THOSE specific files, not a general "claimed
  // devices are read-only" rule. Scoped to files/schedules only:
  //   - /api/auth/* must always work regardless of claim status, or a
  //     claimed device could never be logged into at all (this was a real
  //     bug — POST /api/auth/login is a non-GET request, so the old
  //     blanket version blocked login itself the moment a device got
  //     claimed).
  //   - /api/system/* (Wi-Fi, timezone, hostname, firmware) has no such
  //     race — nothing about network/OS config is cloud-owned — so a
  //     claimed device still needs this reachable for on-site setup (e.g.
  //     joining Wi-Fi) via its own LAN IP, not just before it's claimed.
  app.addHook('preHandler', async (request, reply) => {
    if (request.method === 'GET') return
    if (!request.url.startsWith('/api/files') && !request.url.startsWith('/api/schedules')) return
    if (isCloudManaged()) {
      return reply.code(403).send({ error: 'This device is now managed by SiteStream Cloud — local changes are disabled.' })
    }
  })

  app.register(fileRoutes, { prefix: '/api/files' })
  app.register(scheduleRoutes, { prefix: '/api/schedules' })
  app.register(deviceInfoRoutes, { prefix: '/api/device-info' })
  app.register(authRoutes, { prefix: '/api/auth' })
  app.register(systemRoutes, { prefix: '/api/system' })

  app.get('/api/health', async () => ({ status: 'ok' }))

  // Serves the built React frontend (packages/pi-portal/web's `dist`,
  // copied alongside this server at deploy time — see install.sh) so the
  // whole portal is a single same-origin process, no CORS needed for the
  // browser at all. Only present once actually built; harmless 404s
  // instead of a crash if it's missing (e.g. running the server alone in
  // dev without having built the frontend yet).
  const webDist = path.resolve(__dirname, '../../web-dist')
  app.register(fastifyStatic, { root: webDist, wildcard: false })
  app.setNotFoundHandler((request, reply) => {
    if (request.raw.url?.startsWith('/api/')) return reply.code(404).send({ error: 'Not found' })
    reply.sendFile('index.html')
  })

  try {
    await app.listen({ port: PORT, host: HOST })
  } catch (err) {
    app.log.error(err)
    process.exit(1)
  }

  // After listen, not before — backfill/poll only touch the DB and
  // filesystem, but starting them before the server is confirmed bound
  // would mean a listen failure above still left a background ffmpeg job
  // running against a process that's about to exit anyway.
  startMulticastTranscodeJob()
}

start()
