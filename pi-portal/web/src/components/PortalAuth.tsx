// Shared by App.tsx (the whole portal now requires login) — previously lived
// only inside SystemPanel.tsx, back when the gate covered just the System
// tab. Kept as its own file since App.tsx and SystemPanel.tsx both used to
// import it; now only App.tsx does, but it's still a natural split from the
// tab content itself.
import { useState } from 'react'
import { portalAuthApi } from '@/lib/api'

function apiErrorMessage(err: any, fallback: string): string {
  const data = err?.response?.data?.error
  return typeof data === 'string' ? data : fallback
}

export function LoginForm({ onLoggedIn }: { onLoggedIn: (mustChangePassword: boolean) => void }) {
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setError('')
    setLoading(true)
    try {
      const { data } = await portalAuthApi.login(username, password)
      portalAuthApi.saveToken(data.token)
      onLoggedIn(data.mustChangePassword)
    } catch (err: any) {
      setError(apiErrorMessage(err, 'Login failed'))
    } finally {
      setLoading(false)
    }
  }

  return (
    <div style={card}>
      <h2 style={h2}>Log In</h2>
      <p style={{ color: '#64748b', fontSize: 12, marginBottom: 16 }}>
        Default is username <code>admin</code>, password <code>SiteStream</code> until you change it.
      </p>
      <form onSubmit={handleSubmit} style={{ display: 'flex', flexDirection: 'column', gap: 12, maxWidth: 320 }}>
        <label style={label}>
          Username
          <input style={input} value={username} onChange={(e) => setUsername(e.target.value)} autoFocus required />
        </label>
        <label style={label}>
          Password
          <input style={input} type="password" value={password} onChange={(e) => setPassword(e.target.value)} required />
        </label>
        {error && <p style={errorText}>{error}</p>}
        <button type="submit" style={btn} disabled={loading}>{loading ? 'Logging in…' : 'Log In'}</button>
      </form>
    </div>
  )
}

export function ChangePasswordForm({ onChanged }: { onChanged: () => void }) {
  const [currentPassword, setCurrentPassword] = useState('')
  const [newPassword, setNewPassword] = useState('')
  const [confirmPassword, setConfirmPassword] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setError('')
    if (newPassword !== confirmPassword) {
      setError('Passwords do not match')
      return
    }
    if (newPassword === 'SiteStream') {
      setError('Choose something other than the default password')
      return
    }
    setLoading(true)
    try {
      await portalAuthApi.changePassword(currentPassword, newPassword)
      onChanged()
    } catch (err: any) {
      setError(apiErrorMessage(err, 'Could not change password'))
    } finally {
      setLoading(false)
    }
  }

  return (
    <div style={card}>
      <h2 style={h2}>Set a New Password</h2>
      <p style={{ color: '#f59e0b', fontSize: 12, marginBottom: 16 }}>
        This account is still on the default password — choose a new one before continuing.
      </p>
      <form onSubmit={handleSubmit} style={{ display: 'flex', flexDirection: 'column', gap: 12, maxWidth: 320 }}>
        <label style={label}>
          Current Password
          <input style={input} type="password" value={currentPassword} onChange={(e) => setCurrentPassword(e.target.value)} required />
        </label>
        <label style={label}>
          New Password
          <input style={input} type="password" value={newPassword} onChange={(e) => setNewPassword(e.target.value)} required minLength={8} />
        </label>
        <label style={label}>
          Confirm New Password
          <input style={input} type="password" value={confirmPassword} onChange={(e) => setConfirmPassword(e.target.value)} required minLength={8} />
        </label>
        {error && <p style={errorText}>{error}</p>}
        <button type="submit" style={btn} disabled={loading}>{loading ? 'Saving…' : 'Change Password'}</button>
      </form>
    </div>
  )
}

const h2: React.CSSProperties = { fontSize: 15, fontWeight: 700, color: '#e2e8f0', marginBottom: 12 }
const card: React.CSSProperties = { background: '#1e293b', border: '1px solid #334155', borderRadius: 10, padding: 20 }
const label: React.CSSProperties = { display: 'flex', flexDirection: 'column', gap: 6, fontSize: 13, color: '#94a3b8' }
const input: React.CSSProperties = { background: '#0f172a', border: '1px solid #334155', borderRadius: 6, padding: '7px 12px', color: '#e2e8f0', fontSize: 13, outline: 'none', width: '100%' }
const btn: React.CSSProperties = { background: '#0ea5e9', color: '#fff', border: 'none', borderRadius: 6, padding: '7px 14px', fontSize: 13, fontWeight: 600, cursor: 'pointer' }
const errorText: React.CSSProperties = { color: '#f87171', fontSize: 13 }
