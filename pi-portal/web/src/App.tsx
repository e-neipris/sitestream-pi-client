import { useState, useEffect } from 'react'
import { useQuery } from '@tanstack/react-query'
import MediaPanel from '@/components/MediaPanel'
import SchedulePanel from '@/components/SchedulePanel'
import SystemPanel from '@/components/SystemPanel'
import { LoginForm, ChangePasswordForm } from '@/components/PortalAuth'
import { deviceInfoApi, portalAuthApi } from '@/lib/api'

type Tab = 'media' | 'schedule' | 'system'
type AuthView = 'checking' | 'login' | 'change-password' | 'app'

export default function App() {
  const [authView, setAuthView] = useState<AuthView>('checking')
  const [tab, setTab] = useState<Tab>('media')

  // The whole portal requires login now — probe once on mount rather than
  // assuming a saved token is still good (it may have expired, or the
  // account might still be stuck on the default password, which 403s
  // regardless of session validity — see requirePortalAuth server-side).
  useEffect(() => {
    if (!portalAuthApi.hasToken()) {
      setAuthView('login')
      return
    }
    portalAuthApi.status()
      .then(() => setAuthView('app'))
      .catch((err) => {
        if (err?.response?.status === 403 && err.response.data?.mustChangePassword) {
          setAuthView('change-password')
        } else {
          portalAuthApi.clearToken()
          setAuthView('login')
        }
      })
  }, [])

  const { data: deviceInfo } = useQuery({
    queryKey: ['device-info'],
    queryFn: () => deviceInfoApi.get().then(r => r.data),
    refetchInterval: 15_000,
    enabled: authView === 'app',
  })

  const claimUrl = deviceInfo?.serial ? `${deviceInfo.appUrl}/devices?claim=${deviceInfo.serial}` : null

  const header = (
    <header style={{ marginBottom: 24 }}>
      <h1 style={{ fontSize: 22, fontWeight: 700, color: '#38bdf8' }}>SiteStream</h1>
      <p style={{ color: '#64748b', fontSize: 13, marginTop: 4 }}>
        Standalone device setup {deviceInfo?.serial ? `— Serial ${deviceInfo.serial}` : ''}
      </p>
    </header>
  )

  if (authView === 'checking') {
    return (
      <div style={{ maxWidth: 960, margin: '0 auto', padding: '32px 24px' }}>
        <p style={{ color: '#64748b', padding: 40, textAlign: 'center' }}>Loading…</p>
      </div>
    )
  }

  if (authView === 'login' || authView === 'change-password') {
    return (
      <div style={{ maxWidth: 960, margin: '0 auto', padding: '32px 24px' }}>
        {header}
        {authView === 'login' ? (
          <LoginForm onLoggedIn={(mustChange) => setAuthView(mustChange ? 'change-password' : 'app')} />
        ) : (
          <ChangePasswordForm onChanged={() => { setTab('system'); setAuthView('app') }} />
        )}
      </div>
    )
  }

  return (
    <div style={{ maxWidth: 960, margin: '0 auto', padding: '32px 24px' }}>
      {header}

      {deviceInfo?.cloudManaged ? (
        <div style={banner}>
          <strong style={{ color: '#e2e8f0' }}>This device is managed by SiteStream Cloud.</strong>{' '}
          Schedule and video changes now happen through the cloud portal — Media and Schedule here are read-only.
          The System tab (Wi-Fi, timezone, firmware) still works — useful for on-site setup even on a claimed device.
        </div>
      ) : (
        claimUrl && (
          <div style={{ ...banner, display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 16 }}>
            <span style={{ color: '#94a3b8', fontSize: 13 }}>
              Want more locations, users, or remote management? Connect this device to SiteStream Cloud any time —
              your local videos and schedule stay right where they are until you do.
            </span>
            <a href={claimUrl} target="_blank" rel="noreferrer" style={linkBtn}>Connect to Cloud</a>
          </div>
        )
      )}

      <nav style={{ display: 'flex', gap: 4, marginBottom: 24, borderBottom: '1px solid #1e293b' }}>
        {(['media', 'schedule', 'system'] as Tab[]).map(t => (
          <button
            key={t}
            onClick={() => setTab(t)}
            style={{
              ...tabBtn,
              color: tab === t ? '#38bdf8' : '#64748b',
              borderBottom: tab === t ? '2px solid #38bdf8' : '2px solid transparent',
            }}
          >
            {t === 'media' ? 'Media' : t === 'schedule' ? 'Schedule' : 'System'}
          </button>
        ))}
      </nav>

      {tab === 'system' ? (
        <SystemPanel />
      ) : (
        <fieldset disabled={deviceInfo?.cloudManaged} style={{ border: 'none', padding: 0, margin: 0 }}>
          {tab === 'media' ? <MediaPanel /> : <SchedulePanel />}
        </fieldset>
      )}
    </div>
  )
}

const banner: React.CSSProperties = {
  background: '#1e293b', border: '1px solid #334155', borderRadius: 8,
  padding: '12px 16px', marginBottom: 20, fontSize: 13,
}
const tabBtn: React.CSSProperties = {
  background: 'none', border: 'none', padding: '10px 4px', fontSize: 14, fontWeight: 600,
  cursor: 'pointer', marginRight: 20,
}
const linkBtn: React.CSSProperties = {
  background: '#0ea5e9', color: '#fff', borderRadius: 6, padding: '7px 14px',
  fontSize: 13, fontWeight: 600, textDecoration: 'none', whiteSpace: 'nowrap',
}
