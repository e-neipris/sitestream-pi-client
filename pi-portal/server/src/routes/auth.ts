import { FastifyInstance } from 'fastify'
import { z } from 'zod'
import { verifyLogin, changePassword, createSession, isValidSession, destroySession, bearerToken, requirePortalAuth } from '../auth'

const loginSchema = z.object({ username: z.string().min(1), password: z.string().min(1) })
const changePasswordSchema = z.object({ currentPassword: z.string().min(1), newPassword: z.string().min(8) })

export default async function authRoutes(app: FastifyInstance) {
  /** POST /api/auth/login */
  app.post('/login', async (request, reply) => {
    const body = loginSchema.safeParse(request.body)
    if (!body.success) return reply.code(400).send({ error: body.error.flatten() })

    const result = verifyLogin(body.data.username, body.data.password)
    if (!result.ok) return reply.code(401).send({ error: 'Invalid username or password' })

    return { token: createSession(), mustChangePassword: result.mustChangePassword }
  })

  /**
   * POST /api/auth/change-password — the only route reachable while
   * mustChangePassword is still set (everything under /api/system requires
   * it to be cleared first, see requirePortalAuth in ../auth.ts).
   */
  app.post('/change-password', async (request, reply) => {
    const token = bearerToken(request)
    if (!isValidSession(token)) return reply.code(401).send({ error: 'Not authenticated' })

    const body = changePasswordSchema.safeParse(request.body)
    if (!body.success) return reply.code(400).send({ error: body.error.flatten() })

    if (!changePassword(body.data.currentPassword, body.data.newPassword)) {
      return reply.code(400).send({ error: 'Current password is incorrect' })
    }
    return { ok: true }
  })

  app.post('/logout', async (request) => {
    const token = bearerToken(request)
    if (token) destroySession(token)
    return { ok: true }
  })

  /**
   * GET /api/auth/status — App.tsx's mount-time probe for the whole portal
   * gate. Lives under /api/auth so the blanket auth check in index.ts (which
   * exempts that whole prefix, since login/change-password must be
   * reachable without a session) would otherwise skip it — the explicit
   * preHandler here is what actually protects it regardless.
   */
  app.get('/status', { preHandler: requirePortalAuth }, async () => ({ ok: true }))
}
