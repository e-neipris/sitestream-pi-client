import axios from 'axios'

export const api = axios.create({
  baseURL: '/api',
  headers: { 'Content-Type': 'application/json' },
})

const PORTAL_TOKEN_KEY = 'ss_portal_token'

api.interceptors.request.use((config) => {
  const token = localStorage.getItem(PORTAL_TOKEN_KEY)
  if (token) config.headers.Authorization = `Bearer ${token}`
  return config
})

// Matches the shape packages/web/src/components/MediaPanel.tsx expects —
// copied into this project rather than imported cross-package (it has zero
// AuthContext/tenant coupling, so a same-shaped local api.ts is all it
// needs to run unmodified against this server instead of the cloud one).
export interface VideoFile {
  id: string
  filename: string
  sizeBytes: string | number
  etag: string
  durationSeconds: number | null
  uploadedAt: string
  sourceZoneId: string | null
  _count?: { schedules: number }
}

export const filesApi = {
  list: (_tenantId?: string) => api.get<VideoFile[]>('/files'),
  initiateUpload: (data: { filename: string; contentType: string; sizeBytes: number; durationSeconds?: number; zoneId?: string; replaceFileId?: string }) =>
    api.post<{ fileId: string; presignedPost: { url: string; fields: Record<string, string> } }>('/files/initiate-upload', data),
  confirm: (id: string, etag: string) => api.post<VideoFile>(`/files/${id}/confirm`, { etag }),
  delete: (id: string) => api.delete(`/files/${id}`),
}

export interface Schedule {
  id: string
  videoFileId: string
  startTime: string
  endTime: string
  daysOfWeek: number[]
  validFrom: string | null
  validUntil: string | null
  priority: number
  label: string | null
  videoFile: { id: string; filename: string; durationSeconds: number | null } | null
}

export interface ScheduleCreate {
  videoFileId: string
  startTime: string
  endTime: string
  daysOfWeek: number[]
  validFrom?: string | null
  validUntil?: string | null
  priority: number
  label?: string | null
}

export const schedulesApi = {
  list: () => api.get<Schedule[]>('/schedules'),
  create: (data: ScheduleCreate) => api.post<Schedule>('/schedules', data),
  update: (id: string, data: Partial<ScheduleCreate>) => api.patch<Schedule>(`/schedules/${id}`, data),
  delete: (id: string) => api.delete(`/schedules/${id}`),
}

export interface DeviceInfo {
  serial: string | null
  appUrl: string
  cloudManaged: boolean
}

export const deviceInfoApi = {
  get: () => api.get<DeviceInfo>('/device-info'),
}

// ── Portal auth (System tab) ────────────────────────────────────────────────
// Separate from the cloud app's real multi-user auth — this portal only
// ever has one operator. Username is matched case-insensitively server-side.
export const portalAuthApi = {
  login: (username: string, password: string) =>
    api.post<{ token: string; mustChangePassword: boolean }>('/auth/login', { username, password }),
  changePassword: (currentPassword: string, newPassword: string) =>
    api.post<{ ok: boolean }>('/auth/change-password', { currentPassword, newPassword }),
  logout: () => api.post<{ ok: boolean }>('/auth/logout'),
  // Mount-time probe for the whole-portal gate in App.tsx — a stored token
  // might be expired, or the account might still be on the default password
  // (this 403s on that regardless of a valid session, same as every other
  // route now — see requirePortalAuth server-side).
  status: () => api.get<{ ok: boolean }>('/auth/status'),
  saveToken: (token: string) => localStorage.setItem(PORTAL_TOKEN_KEY, token),
  clearToken: () => localStorage.removeItem(PORTAL_TOKEN_KEY),
  hasToken: () => !!localStorage.getItem(PORTAL_TOKEN_KEY),
}

export interface SystemInfo {
  hostname: string
  timezone: string
  ntpEnabled: boolean
  ntpSynced: boolean
  currentTime: string
  installedVersion: string | null
  nextCheckinAt: string | null
  // Raspberry Pi OS soft-blocks the radio via rfkill until a regulatory
  // country is set — a device that's never been through that can't scan or
  // join anything at all until it is. See system.ts's isWifiRadioBlocked.
  wifiBlocked: boolean
  wifi: WifiStatus
  multicast: MulticastConfig
}

export interface WifiStatus {
  ssid: string | null
  ipAddress: string | null
  subnetMask: string | null
  gateway: string | null
  dns: string[]
}

export interface WifiNetwork {
  ssid: string
  signal: number
}

// Standalone-mode equivalent of the cloud's per-device multicast fields (see
// the SaaS web app's EditDeviceModal) — same shape, same MULTICAST_* keys
// underneath (see system.ts's getMulticastConfig).
export interface MulticastConfig {
  enabled: boolean
  address: string | null
  port: number | null
  interface: string | null
  // Null = player.sh's own fleet-wide default (6000 kbps as of writing).
  maxBitrateKbps: number | null
}

export const systemApi = {
  info: () => api.get<SystemInfo>('/system/info'),
  timezones: () => api.get<string[]>('/system/timezones'),
  setTimezone: (timezone: string) => api.post<{ ok: boolean }>('/system/timezone', { timezone }),
  setNtp: (enabled: boolean) => api.post<{ ok: boolean }>('/system/ntp', { enabled }),
  setDatetime: (isoDatetime: string) => api.post<{ ok: boolean }>('/system/datetime', { isoDatetime }),
  setHostname: (hostname: string) => api.post<{ ok: boolean; note?: string }>('/system/hostname', { hostname }),
  scanWifi: () => api.get<WifiNetwork[]>('/system/wifi/scan'),
  setWifiCountry: (countryCode: string) => api.post<{ ok: boolean }>('/system/wifi/country', { countryCode }),
  connectWifi: (data: { ssid: string; password?: string; countryCode?: string }) =>
    api.post<{ ok: boolean }>('/system/wifi/connect', data),
  networkInterfaces: () => api.get<string[]>('/system/network-interfaces'),
  setMulticast: (data: { enabled: boolean; address?: string; port?: number; interface?: string; maxBitrateKbps?: number | null }) =>
    api.post<{ ok: boolean }>('/system/multicast', data),
  uploadFirmware: (file: File) => {
    const formData = new FormData()
    formData.append('file', file)
    return api.post<{ ok: boolean; message: string }>('/system/firmware/upload', formData, {
      headers: { 'Content-Type': 'multipart/form-data' },
    })
  },
  factoryReset: (data: { forgetWifi: boolean }) =>
    api.post<{ ok: boolean; message: string }>('/system/factory-reset', data),
}
