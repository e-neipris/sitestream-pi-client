// Login/change-password gating now happens once, at the top of App.tsx, for
// the whole portal — not just this tab (see PortalAuth.tsx). By the time
// this renders, the caller has already guaranteed an authenticated,
// password-changed session.
import { useState, useEffect, useRef } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { systemApi } from '@/lib/api'

function apiErrorMessage(err: any, fallback: string): string {
  const data = err?.response?.data?.error
  return typeof data === 'string' ? data : fallback
}

export default function SystemPanel() {
  return <SettingsView />
}

function SettingsView() {
  const qc = useQueryClient()
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')

  const { data: info } = useQuery({
    queryKey: ['system-info'],
    queryFn: () => systemApi.info().then((r) => r.data),
    refetchInterval: 15_000,
  })
  const { data: timezones } = useQuery({
    queryKey: ['timezones'],
    queryFn: () => systemApi.timezones().then((r) => r.data),
  })
  const { data: networks, refetch: rescan, isFetching: scanning } = useQuery({
    queryKey: ['wifi-scan'],
    queryFn: () => systemApi.scanWifi().then((r) => r.data),
    enabled: false,
  })

  const invalidateInfo = () => qc.invalidateQueries({ queryKey: ['system-info'] })

  const [timezone, setTimezone] = useState('')
  useEffect(() => { if (info?.timezone && !timezone) setTimezone(info.timezone) }, [info?.timezone]) // eslint-disable-line react-hooks/exhaustive-deps

  const setTimezoneMut = useMutation({
    mutationFn: (tz: string) => systemApi.setTimezone(tz),
    onSuccess: () => { setNotice('Timezone updated.'); invalidateInfo() },
    onError: (err: any) => setError(apiErrorMessage(err, 'Could not set timezone')),
  })

  const setNtpMut = useMutation({
    mutationFn: (enabled: boolean) => systemApi.setNtp(enabled),
    onSuccess: invalidateInfo,
    onError: (err: any) => setError(apiErrorMessage(err, 'Could not change the NTP setting')),
  })

  const [manualDatetime, setManualDatetime] = useState('')
  const setDatetimeMut = useMutation({
    mutationFn: (iso: string) => systemApi.setDatetime(iso),
    onSuccess: () => { setNotice('Date/time updated.'); invalidateInfo() },
    onError: (err: any) => setError(apiErrorMessage(err, 'Could not set date/time')),
  })

  const [hostname, setHostname] = useState('')
  useEffect(() => { if (info?.hostname && !hostname) setHostname(info.hostname) }, [info?.hostname]) // eslint-disable-line react-hooks/exhaustive-deps

  const setHostnameMut = useMutation({
    mutationFn: (h: string) => systemApi.setHostname(h),
    onSuccess: (res) => { setNotice(res.data.note ?? 'Hostname updated.'); invalidateInfo() },
    onError: (err: any) => setError(apiErrorMessage(err, 'Could not set hostname')),
  })

  const [wifiCountry, setWifiCountry] = useState('')
  const setWifiCountryMut = useMutation({
    mutationFn: (cc: string) => systemApi.setWifiCountry(cc),
    onSuccess: () => { setNotice('Wi-Fi country set — radio should be unblocked now.'); invalidateInfo() },
    onError: (err: any) => setError(apiErrorMessage(err, 'Could not set Wi-Fi country')),
  })

  const [ssid, setSsid] = useState('')
  const [wifiPassword, setWifiPassword] = useState('')
  const [countryCode, setCountryCode] = useState('')
  const connectWifiMut = useMutation({
    mutationFn: () => systemApi.connectWifi({ ssid, password: wifiPassword || undefined, countryCode: countryCode || undefined }),
    onSuccess: () => { setNotice(`Joining "${ssid}"… this can take a few seconds to take effect.`); invalidateInfo() },
    onError: (err: any) => setError(apiErrorMessage(err, 'Could not join that network')),
  })

  const { data: networkInterfaces } = useQuery({
    queryKey: ['network-interfaces'],
    queryFn: () => systemApi.networkInterfaces().then((r) => r.data),
  })

  // Seeded once via a ref (not the `!multicastEnabled` pattern used for
  // timezone/hostname above) — `enabled: false` is a legitimate saved state,
  // and that guard would re-clobber it from a stale `info` on every 15s
  // refetch, right in the middle of someone editing these fields.
  const multicastSeeded = useRef(false)
  const [multicastEnabled, setMulticastEnabled] = useState(false)
  const [multicastAddress, setMulticastAddress] = useState('')
  const [multicastPort, setMulticastPort] = useState('')
  const [multicastInterface, setMulticastInterface] = useState('')
  useEffect(() => {
    if (info?.multicast && !multicastSeeded.current) {
      multicastSeeded.current = true
      setMulticastEnabled(info.multicast.enabled)
      setMulticastAddress(info.multicast.address ?? '')
      setMulticastPort(info.multicast.port?.toString() ?? '')
      setMulticastInterface(info.multicast.interface ?? '')
    }
  }, [info?.multicast])

  const setMulticastMut = useMutation({
    mutationFn: () => systemApi.setMulticast({
      enabled: multicastEnabled,
      address: multicastEnabled ? multicastAddress.trim() : undefined,
      port: multicastEnabled ? Number(multicastPort) : undefined,
      interface: multicastEnabled ? (multicastInterface || undefined) : undefined,
    }),
    onSuccess: () => { setNotice('Multicast settings saved — player.sh picks this up within ~30s, no restart needed.'); invalidateInfo() },
    onError: (err: any) => setError(apiErrorMessage(err, 'Could not save multicast settings')),
  })

  const fileRef = useRef<HTMLInputElement>(null)
  const [uploading, setUploading] = useState(false)
  const handleFirmwareUpload = async (e: React.FormEvent) => {
    e.preventDefault()
    const file = fileRef.current?.files?.[0]
    if (!file) return
    setError('')
    setUploading(true)
    try {
      const { data } = await systemApi.uploadFirmware(file)
      setNotice(data.message)
      if (fileRef.current) fileRef.current.value = ''
    } catch (err: any) {
      setError(apiErrorMessage(err, 'Upload failed'))
    } finally {
      setUploading(false)
    }
  }

  const timezoneOptions = timezones ?? (info?.timezone ? [info.timezone] : [])

  const [showResetConfirm, setShowResetConfirm] = useState(false)
  const [resetForgetWifi, setResetForgetWifi] = useState(false)
  const factoryResetMut = useMutation({
    mutationFn: () => systemApi.factoryReset({ forgetWifi: resetForgetWifi }),
    onSuccess: (res) => { setNotice(res.data.message); setShowResetConfirm(false) },
    onError: (err: any) => { setError(apiErrorMessage(err, 'Could not start factory reset')); setShowResetConfirm(false) },
  })

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
      {notice && (
        <div style={noticeBanner}>
          {notice}
          <button style={dismissBtn} onClick={() => setNotice('')}>✕</button>
        </div>
      )}
      {error && (
        <div style={errorBanner}>
          {error}
          <button style={dismissBtn} onClick={() => setError('')}>✕</button>
        </div>
      )}

      <div style={card}>
        <h2 style={h2}>Overview</h2>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14, fontSize: 13 }}>
          <Stat label="Hostname" value={info?.hostname ?? '—'} />
          <Stat label="Installed Version" value={info?.installedVersion ?? 'unknown'} />
          <Stat label="Timezone" value={info?.timezone ?? '—'} />
          <Stat
            label="Clock"
            // info.currentTime is a UTC instant — formatting it with no
            // `timeZone` option renders it in the BROWSER's local timezone,
            // not the device's, so this looked "stuck" on whatever timezone
            // the viewing laptop/phone happened to be in regardless of what
            // was actually applied on the Pi. Pin formatting to the device's
            // own reported timezone (Timezone stat above, straight from
            // `timedatectl show`) instead.
            value={info ? new Date(info.currentTime).toLocaleString(undefined, info.timezone ? { timeZone: info.timezone } : undefined) : '—'}
            valueColor={info?.ntpEnabled ? (info?.ntpSynced ? '#22c55e' : '#f59e0b') : '#94a3b8'}
            sub={info ? `NTP ${info.ntpEnabled ? (info.ntpSynced ? 'synced' : 'syncing…') : 'off'}` : undefined}
          />
        </div>
      </div>

      <div style={card}>
        <h2 style={h2}>Wi-Fi</h2>
        <div style={{ display: 'flex', gap: 24, flexWrap: 'wrap' }}>
          <div style={{ flex: '1 1 320px', minWidth: 280 }}>
            {info?.wifiBlocked && (
              <div style={{ ...noticeBanner, background: '#451a03', borderColor: '#78350f', color: '#fbbf24', marginBottom: 12 }}>
                Wi-Fi radio is disabled until a country is set (a regulatory requirement, not a bug) — set one below,
                then Scan/Join will work.
              </div>
            )}
            <div style={{ display: 'flex', gap: 8, alignItems: 'flex-end', marginBottom: 16, maxWidth: 360 }}>
              <label style={{ ...label, flex: 1 }}>
                Wi-Fi Country (e.g. US)
                <input
                  style={{ ...input, textTransform: 'uppercase' }}
                  maxLength={2}
                  value={wifiCountry}
                  onChange={(e) => setWifiCountry(e.target.value)}
                />
              </label>
              <button
                type="button" style={btn}
                disabled={wifiCountry.length !== 2 || setWifiCountryMut.isPending}
                onClick={() => setWifiCountryMut.mutate(wifiCountry)}
              >
                {setWifiCountryMut.isPending ? 'Saving…' : 'Set Country'}
              </button>
            </div>
            <button type="button" style={{ ...ghostBtn, marginBottom: 12 }} onClick={() => rescan()} disabled={scanning}>
              {scanning ? 'Scanning…' : 'Scan for networks'}
            </button>
            {networks && networks.length > 0 && (
              <select style={{ ...input, marginBottom: 12 }} value={ssid} onChange={(e) => setSsid(e.target.value)}>
                <option value="">Select a network…</option>
                {networks.map((n) => <option key={n.ssid} value={n.ssid}>{n.ssid}{n.signal ? ` (${n.signal}%)` : ''}</option>)}
              </select>
            )}
            <div style={{ display: 'flex', flexDirection: 'column', gap: 10, maxWidth: 360 }}>
              <label style={label}>
                Network Name (SSID)
                <input style={input} value={ssid} onChange={(e) => setSsid(e.target.value)} placeholder="e.g. StoreWifi" />
              </label>
              <label style={label}>
                Password
                <input style={input} type="password" value={wifiPassword} onChange={(e) => setWifiPassword(e.target.value)} placeholder="Leave blank for an open network" />
              </label>
              <label style={label}>
                Country Code (optional, e.g. US)
                <input style={{ ...input, textTransform: 'uppercase' }} maxLength={2} value={countryCode} onChange={(e) => setCountryCode(e.target.value)} />
              </label>
              <button
                type="button" style={btn} disabled={!ssid || connectWifiMut.isPending}
                onClick={() => {
                  if (!wifiPassword && !window.confirm(
                    `No password entered — this will join "${ssid}" as an OPEN network. If "${ssid}" actually requires a ` +
                    'password, this will silently fail to connect (and won\'t reconnect on its own). Continue with no password?',
                  )) return
                  connectWifiMut.mutate()
                }}
              >
                {connectWifiMut.isPending ? 'Joining…' : 'Join Network'}
              </button>
            </div>
          </div>

          <div style={{ flex: '0 0 220px', borderLeft: '1px solid #334155', paddingLeft: 20 }}>
            <div style={{ marginBottom: 14 }}>
              <span style={muted}>Status</span>
              <div style={{ fontSize: 13, color: info?.wifi.ssid ? '#22c55e' : '#94a3b8' }}>
                {info?.wifi.ssid ? `Connected to "${info.wifi.ssid}"` : 'Not connected'}
              </div>
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
              <IpStat label="IP Address" value={info?.wifi.ipAddress} />
              <IpStat label="Subnet Mask" value={info?.wifi.subnetMask} />
              <IpStat label="Default Gateway" value={info?.wifi.gateway} />
              <IpStat label="DNS" value={info?.wifi.dns.length ? info.wifi.dns.join(', ') : null} />
            </div>
          </div>
        </div>
      </div>

      <div style={card}>
        <h2 style={h2}>Multicast</h2>
        <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, color: '#e2e8f0', marginBottom: 12, cursor: 'pointer' }}>
          <input type="checkbox" checked={multicastEnabled} onChange={(e) => setMulticastEnabled(e.target.checked)} />
          Also output via multicast (in addition to HDMI) — for feeding an IPTV tuner
        </label>
        {multicastEnabled && (
          <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 12, maxWidth: 520, marginBottom: 12 }}>
            <label style={label}>
              Multicast Address
              <input
                style={{ ...input, fontFamily: 'monospace' }}
                value={multicastAddress}
                onChange={(e) => setMulticastAddress(e.target.value)}
                placeholder="e.g. 239.1.1.1"
              />
            </label>
            <label style={label}>
              Port
              <input
                style={{ ...input, fontFamily: 'monospace' }}
                type="number"
                min={1}
                max={65535}
                value={multicastPort}
                onChange={(e) => setMulticastPort(e.target.value)}
                placeholder="5004"
              />
            </label>
            <label style={{ ...label, gridColumn: '1 / -1' }}>
              Output Interface (optional)
              <select
                style={input}
                value={multicastInterface}
                onChange={(e) => setMulticastInterface(e.target.value)}
              >
                <option value="">Auto (let the OS decide)</option>
                {networkInterfaces?.map((iface) => <option key={iface} value={iface}>{iface}</option>)}
              </select>
              <span style={{ color: '#475569', fontSize: 11 }}>
                Only needed if this device also uses Wi-Fi for its own SaaS traffic — pins the multicast stream to
                this specific NIC (e.g. the wired port feeding an IPTV tuner) instead of leaving it to the OS.
              </span>
            </label>
          </div>
        )}
        <button
          type="button" style={btn}
          disabled={setMulticastMut.isPending || (multicastEnabled && (!multicastAddress.trim() || !multicastPort))}
          onClick={() => setMulticastMut.mutate()}
        >
          {setMulticastMut.isPending ? 'Saving…' : 'Save Multicast Settings'}
        </button>
      </div>

      <div style={card}>
        <h2 style={h2}>Timezone</h2>
        <div style={{ display: 'flex', gap: 8, maxWidth: 420 }}>
          <select style={{ ...input, flex: 1 }} value={timezone} onChange={(e) => setTimezone(e.target.value)}>
            {timezoneOptions.map((tz) => <option key={tz} value={tz}>{tz}</option>)}
          </select>
          <button type="button" style={btn} disabled={!timezone || setTimezoneMut.isPending} onClick={() => setTimezoneMut.mutate(timezone)}>
            {setTimezoneMut.isPending ? 'Saving…' : 'Apply'}
          </button>
        </div>
      </div>

      <div style={card}>
        <h2 style={h2}>Date &amp; Time</h2>
        <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, color: '#e2e8f0', marginBottom: 12, cursor: 'pointer' }}>
          <input
            type="checkbox"
            checked={!!info?.ntpEnabled}
            disabled={setNtpMut.isPending}
            onChange={(e) => setNtpMut.mutate(e.target.checked)}
          />
          Keep clock synced automatically (NTP) — recommended
        </label>
        {!info?.ntpEnabled && (
          <div style={{ display: 'flex', gap: 8, maxWidth: 420 }}>
            <input
              style={{ ...input, flex: 1 }}
              type="datetime-local"
              value={manualDatetime}
              onChange={(e) => setManualDatetime(e.target.value)}
            />
            <button type="button" style={btn} disabled={!manualDatetime || setDatetimeMut.isPending} onClick={() => setDatetimeMut.mutate(manualDatetime)}>
              {setDatetimeMut.isPending ? 'Saving…' : 'Set'}
            </button>
          </div>
        )}
      </div>

      <div style={card}>
        <h2 style={h2}>Device Name</h2>
        <div style={{ display: 'flex', gap: 8, maxWidth: 420 }}>
          <input style={{ ...input, flex: 1 }} value={hostname} onChange={(e) => setHostname(e.target.value)} />
          <button type="button" style={btn} disabled={!hostname || setHostnameMut.isPending} onClick={() => setHostnameMut.mutate(hostname)}>
            {setHostnameMut.isPending ? 'Saving…' : 'Apply'}
          </button>
        </div>
      </div>

      <div style={card}>
        <h2 style={h2}>Firmware</h2>
        <p style={{ color: '#64748b', fontSize: 12, marginBottom: 12 }}>
          Currently installed: <strong style={{ color: '#e2e8f0' }}>{info?.installedVersion ?? 'unknown'}</strong>.
          Upload a release tarball (.tar.gz) to update this device directly — no cloud connection needed.
        </p>
        <form onSubmit={handleFirmwareUpload} style={{ display: 'flex', gap: 8 }}>
          <input ref={fileRef} type="file" accept=".gz,.tar.gz,application/gzip" style={input} required />
          <button type="submit" style={btn} disabled={uploading}>{uploading ? 'Uploading…' : 'Upload & Install'}</button>
        </form>
      </div>

      <div style={{ ...card, borderColor: '#7f1d1d' }}>
        <h2 style={{ ...h2, color: '#f87171' }}>Danger Zone</h2>
        <p style={{ color: '#64748b', fontSize: 12, marginBottom: 12 }}>
          Wipes this device's local videos, schedule, and portal login back to a fresh install. Does not remove it
          from SiteStream Cloud if it's claimed — do that from the SaaS separately.
        </p>
        <button type="button" style={dangerBtn} onClick={() => setShowResetConfirm(true)}>
          Factory Reset…
        </button>
      </div>

      {showResetConfirm && (
        <FactoryResetModal
          forgetWifi={resetForgetWifi}
          onForgetWifiChange={setResetForgetWifi}
          pending={factoryResetMut.isPending}
          onCancel={() => setShowResetConfirm(false)}
          onConfirm={() => factoryResetMut.mutate()}
        />
      )}
    </div>
  )
}

function FactoryResetModal({ forgetWifi, onForgetWifiChange, pending, onCancel, onConfirm }: {
  forgetWifi: boolean
  onForgetWifiChange: (v: boolean) => void
  pending: boolean
  onCancel: () => void
  onConfirm: () => void
}) {
  return (
    <Overlay onClose={pending ? () => {} : onCancel}>
      <h2 style={{ ...modalTitle, color: '#f87171' }}>Factory Reset This Device</h2>
      <p style={{ color: '#94a3b8', fontSize: 13, marginBottom: 12 }}>
        This permanently deletes this device's local videos, schedule, and cached state, and resets the portal
        login back to <code>admin</code> / <code>SiteStream</code> (forcing a password change again next login).
        <strong style={{ color: '#e2e8f0' }}> This cannot be undone.</strong>
      </p>
      <p style={{ color: '#94a3b8', fontSize: 13, marginBottom: 16 }}>
        If this device is claimed in SiteStream Cloud, it is <strong style={{ color: '#e2e8f0' }}>not</strong> released
        or removed from its Zone — that's a separate step an admin has to do from the SaaS. This only resets what's
        stored locally on the device itself.
      </p>
      <label style={{ display: 'flex', alignItems: 'flex-start', gap: 8, fontSize: 13, color: '#e2e8f0', marginBottom: 20, cursor: pending ? 'default' : 'pointer' }}>
        <input
          type="checkbox"
          checked={forgetWifi}
          disabled={pending}
          onChange={(e) => onForgetWifiChange(e.target.checked)}
          style={{ marginTop: 2 }}
        />
        <span>
          Also forget this device's Wi-Fi network(s)
          <br />
          <span style={{ color: '#64748b', fontSize: 12 }}>
            The device will reboot automatically afterward and show its setup hotspot again — you'll need to rejoin
            it to Wi-Fi from scratch, the same as a brand new unit.
          </span>
        </span>
      </label>
      <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8 }}>
        <button type="button" style={ghostBtn} disabled={pending} onClick={onCancel}>Cancel</button>
        <button type="button" style={dangerBtn} disabled={pending} onClick={onConfirm}>
          {pending ? 'Resetting…' : 'Factory Reset This Device'}
        </button>
      </div>
    </Overlay>
  )
}

function Overlay({ children, onClose }: { children: React.ReactNode; onClose: () => void }) {
  return (
    <div style={overlay} onClick={onClose}>
      <div style={modal} onClick={(e) => e.stopPropagation()}>{children}</div>
    </div>
  )
}

function Stat({ label, value, valueColor, sub }: { label: string; value: string; valueColor?: string; sub?: string }) {
  return (
    <div>
      <span style={muted}>{label}</span>
      <div style={{ color: valueColor ?? '#e2e8f0' }}>{value}</div>
      {sub && <div style={{ color: '#475569', fontSize: 11 }}>{sub}</div>}
    </div>
  )
}

function IpStat({ label, value }: { label: string; value: string | null | undefined }) {
  return (
    <div>
      <span style={muted}>{label}</span>
      <div style={{ fontSize: 13, color: value ? '#e2e8f0' : '#475569', fontFamily: value ? 'monospace' : undefined }}>
        {value ?? '—'}
      </div>
    </div>
  )
}

const h2: React.CSSProperties = { fontSize: 15, fontWeight: 700, color: '#e2e8f0', marginBottom: 12 }
const muted: React.CSSProperties = { color: '#64748b', fontSize: 12 }
const card: React.CSSProperties = { background: '#1e293b', border: '1px solid #334155', borderRadius: 10, padding: 20 }
const label: React.CSSProperties = { display: 'flex', flexDirection: 'column', gap: 6, fontSize: 13, color: '#94a3b8' }
const input: React.CSSProperties = { background: '#0f172a', border: '1px solid #334155', borderRadius: 6, padding: '7px 12px', color: '#e2e8f0', fontSize: 13, outline: 'none', width: '100%' }
const btn: React.CSSProperties = { background: '#0ea5e9', color: '#fff', border: 'none', borderRadius: 6, padding: '7px 14px', fontSize: 13, fontWeight: 600, cursor: 'pointer' }
const ghostBtn: React.CSSProperties = { background: 'transparent', color: '#94a3b8', border: '1px solid #334155', borderRadius: 6, padding: '7px 12px', fontSize: 13, cursor: 'pointer' }
const dangerBtn: React.CSSProperties = { background: '#450a0a', color: '#f87171', border: '1px solid #7f1d1d', borderRadius: 6, padding: '7px 14px', fontSize: 13, fontWeight: 600, cursor: 'pointer' }
const overlay: React.CSSProperties = { position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.7)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 100 }
const modal: React.CSSProperties = { background: '#1e293b', border: '1px solid #334155', borderRadius: 12, padding: 24, width: 460, maxWidth: '90vw', maxHeight: '90vh', overflowY: 'auto' }
const modalTitle: React.CSSProperties = { fontSize: 16, fontWeight: 700, color: '#e2e8f0', marginBottom: 16 }
const noticeBanner: React.CSSProperties = {
  display: 'flex', justifyContent: 'space-between', alignItems: 'center',
  background: '#0c2d1e', border: '1px solid #14532d', color: '#86efac',
  borderRadius: 8, padding: '10px 14px', fontSize: 13,
}
const errorBanner: React.CSSProperties = {
  display: 'flex', justifyContent: 'space-between', alignItems: 'center',
  background: '#450a0a', border: '1px solid #7f1d1d', color: '#fca5a5',
  borderRadius: 8, padding: '10px 14px', fontSize: 13,
}
const dismissBtn: React.CSSProperties = { background: 'transparent', border: 'none', color: 'inherit', cursor: 'pointer', fontSize: 13 }
