import { FastifyInstance } from 'fastify'
import { getAppUrl, getSerialNumber, isCloudManaged } from '../paths'

export default async function deviceInfoRoutes(app: FastifyInstance) {
  /**
   * GET /api/device-info — lets the frontend build the "Connect this device
   * to SiteStream Cloud" link to `${appUrl}/devices?claim=${serial}`, the
   * same ?claim= deep link the onboarding screen's QR code already uses
   * (see generate-onboarding-screen.sh) — claiming through that existing
   * flow is the entire "easy path to Managed mode": once claimed,
   * cloudManaged flips true and this portal goes read-only on its own,
   * no separate pairing mechanism needed.
   */
  app.get('/', async () => ({
    serial: getSerialNumber(),
    appUrl: getAppUrl(),
    cloudManaged: isCloudManaged(),
  }))
}
