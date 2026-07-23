// Adapted from packages/web/src/pages/Schedules.tsx — same CRUD form/logic,
// with the Zone concept removed entirely rather than just hidden: a
// standalone device has exactly one implicit location, so there's nothing
// to pick. If the cloud version's non-zone fields change, re-sync this by
// hand (no shared package between the two yet).
import { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { schedulesApi, filesApi, type ScheduleCreate, type Schedule } from '@/lib/api'

const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']

function apiErrorMessage(err: any, fallback: string): string {
  const data = err?.response?.data?.error
  if (typeof data === 'string') return data
  if (data && typeof data === 'object') {
    const parts = [
      ...(data.formErrors ?? []),
      ...Object.entries(data.fieldErrors ?? {}).map(([field, msgs]) => `${field}: ${(msgs as string[]).join(', ')}`),
    ]
    if (parts.length) return parts.join('; ')
  }
  return fallback
}

function isoToDateInput(iso: string | null | undefined) {
  if (!iso) return ''
  return iso.split('T')[0]
}

export default function SchedulePanel() {
  const qc = useQueryClient()
  const [showModal, setShowModal] = useState(false)
  const [editSchedule, setEditSchedule] = useState<Schedule | null>(null)

  const { data: schedules, isLoading } = useQuery({
    queryKey: ['schedules'],
    queryFn: () => schedulesApi.list().then(r => r.data),
  })

  const deleteSchedule = useMutation({
    mutationFn: (id: string) => schedulesApi.delete(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['schedules'] }),
  })

  return (
    <div>
      <div style={hdr}>
        <h1 style={h1}>Schedule</h1>
        <button style={btn} onClick={() => setShowModal(true)}>+ Add Schedule</button>
      </div>

      <table style={table}>
        <thead>
          <tr>
            {['Video', 'Time Window', 'Days', 'Valid', 'Priority', ''].map(col => (
              <th key={col} style={th}>{col}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {schedules?.map(s => (
            <tr key={s.id} style={tr}>
              <td style={td}>
                <span style={{ color: '#e2e8f0', fontSize: 13 }}>{s.videoFile?.filename}</span>
                {s.label && <div style={{ color: '#64748b', fontSize: 11 }}>{s.label}</div>}
              </td>
              <td style={td}>
                <span style={{ color: '#38bdf8', fontSize: 13, fontFamily: 'monospace' }}>
                  {s.startTime} – {s.endTime}
                </span>
              </td>
              <td style={td}>
                <span style={{ color: '#94a3b8', fontSize: 12 }}>
                  {s.daysOfWeek.length === 0 ? 'Every day' : s.daysOfWeek.map(d => DAYS[d]).join(', ')}
                </span>
              </td>
              <td style={td}>
                <span style={{ color: '#64748b', fontSize: 12 }}>
                  {s.validFrom ? new Date(s.validFrom).toLocaleDateString() : '∞'} –{' '}
                  {s.validUntil ? new Date(s.validUntil).toLocaleDateString() : '∞'}
                </span>
              </td>
              <td style={td}><span style={{ color: '#64748b', fontSize: 13 }}>{s.priority}</span></td>
              <td style={td}>
                <div style={{ display: 'flex', gap: 6 }}>
                  <button style={ghostBtnSm} onClick={() => setEditSchedule(s)}>Edit</button>
                  <button style={dangerBtnSm} onClick={() => deleteSchedule.mutate(s.id)}>Remove</button>
                </div>
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      {!isLoading && !schedules?.length && (
        <p style={{ color: '#475569', fontSize: 13, textAlign: 'center', padding: 40 }}>
          No schedules yet. Add one to define what plays when.
        </p>
      )}

      {showModal && (
        <ScheduleModal
          onClose={() => setShowModal(false)}
          onSaved={() => { setShowModal(false); qc.invalidateQueries({ queryKey: ['schedules'] }) }}
        />
      )}

      {editSchedule && (
        <ScheduleModal
          editSchedule={editSchedule}
          onClose={() => setEditSchedule(null)}
          onSaved={() => { setEditSchedule(null); qc.invalidateQueries({ queryKey: ['schedules'] }) }}
        />
      )}
    </div>
  )
}

function ScheduleModal({ editSchedule, onClose, onSaved }: {
  editSchedule?: Schedule
  onClose: () => void
  onSaved: () => void
}) {
  const [form, setForm] = useState<Partial<ScheduleCreate>>(
    editSchedule ? {
      videoFileId: editSchedule.videoFileId,
      startTime: editSchedule.startTime,
      endTime: editSchedule.endTime,
      daysOfWeek: editSchedule.daysOfWeek,
      validFrom: editSchedule.validFrom ?? null,
      validUntil: editSchedule.validUntil ?? null,
      priority: editSchedule.priority,
      label: editSchedule.label ?? null,
    } : { startTime: '00:00', endTime: '23:59', daysOfWeek: [], priority: 0 }
  )
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')

  const { data: files } = useQuery({ queryKey: ['files'], queryFn: () => filesApi.list().then(r => r.data) })

  const toggleDay = (d: number) => {
    const cur = form.daysOfWeek ?? []
    setForm(f => ({ ...f, daysOfWeek: cur.includes(d) ? cur.filter(x => x !== d) : [...cur, d].sort() }))
  }

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setError('')
    setLoading(true)
    try {
      if (editSchedule) {
        await schedulesApi.update(editSchedule.id, form)
      } else {
        await schedulesApi.create(form as ScheduleCreate)
      }
      onSaved()
    } catch (err: any) {
      setError(apiErrorMessage(err, 'Could not save schedule'))
    } finally {
      setLoading(false)
    }
  }

  return (
    <Overlay onClose={onClose}>
      <h2 style={modalTitle}>{editSchedule ? 'Edit Schedule' : 'Add Schedule Entry'}</h2>
      <form onSubmit={handleSubmit} style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
        <Field label="Video File">
          <select style={input} value={form.videoFileId ?? ''} onChange={e => setForm(f => ({ ...f, videoFileId: e.target.value }))} required>
            <option value="">Select video…</option>
            {files?.filter(f => f.etag).map(f => <option key={f.id} value={f.id}>{f.filename}</option>)}
          </select>
        </Field>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <Field label="Start Time">
            <input style={input} type="time" value={form.startTime} onChange={e => setForm(f => ({ ...f, startTime: e.target.value }))} required />
          </Field>
          <Field label="End Time">
            <input style={input} type="time" value={form.endTime} onChange={e => setForm(f => ({ ...f, endTime: e.target.value }))} required />
          </Field>
        </div>
        <Field label="Days of Week (empty = every day)">
          <div style={{ display: 'flex', gap: 6, marginTop: 4 }}>
            {DAYS.map((d, i) => (
              <button key={i} type="button" onClick={() => toggleDay(i)} style={{
                padding: '4px 8px', borderRadius: 4, fontSize: 12, cursor: 'pointer', border: 'none',
                background: (form.daysOfWeek ?? []).includes(i) ? '#0ea5e9' : '#1e293b',
                color: (form.daysOfWeek ?? []).includes(i) ? '#fff' : '#64748b',
              }}>{d}</button>
            ))}
          </div>
        </Field>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <Field label="Valid From (optional)">
            <input style={input} type="date"
              defaultValue={isoToDateInput(editSchedule?.validFrom)}
              onChange={e => setForm(f => ({ ...f, validFrom: e.target.value ? new Date(e.target.value).toISOString() : null }))} />
          </Field>
          <Field label="Valid Until (optional)">
            <input style={input} type="date"
              defaultValue={isoToDateInput(editSchedule?.validUntil)}
              onChange={e => setForm(f => ({ ...f, validUntil: e.target.value ? new Date(e.target.value).toISOString() : null }))} />
          </Field>
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <Field label="Priority (higher wins on overlap)">
            <input style={input} type="number" min={0} value={form.priority ?? 0} onChange={e => setForm(f => ({ ...f, priority: Number(e.target.value) }))} />
          </Field>
          <Field label="Label (optional)">
            <input style={input} value={form.label ?? ''} onChange={e => setForm(f => ({ ...f, label: e.target.value || null }))} placeholder="e.g. Lunch Special" />
          </Field>
        </div>
        {error && <p style={{ color: '#f87171', fontSize: 13 }}>{error}</p>}
        <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', marginTop: 4 }}>
          <button type="button" style={ghostBtn} onClick={onClose}>Cancel</button>
          <button type="submit" style={btn} disabled={loading}>
            {loading ? 'Saving…' : editSchedule ? 'Save Changes' : 'Save Schedule'}
          </button>
        </div>
      </form>
    </Overlay>
  )
}

function Overlay({ children, onClose }: { children: React.ReactNode; onClose: () => void }) {
  return (
    <div style={overlay} onClick={onClose}>
      <div style={modal} onClick={e => e.stopPropagation()}>{children}</div>
    </div>
  )
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return <label style={{ display: 'flex', flexDirection: 'column', gap: 6, fontSize: 13, color: '#94a3b8' }}>{label}{children}</label>
}

const h1: React.CSSProperties = { fontSize: 24, fontWeight: 700, color: '#e2e8f0' }
const hdr: React.CSSProperties = { display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 24 }
const table: React.CSSProperties = { width: '100%', borderCollapse: 'collapse' }
const th: React.CSSProperties = { textAlign: 'left', padding: '10px 12px', fontSize: 11, color: '#64748b', textTransform: 'uppercase', letterSpacing: '0.05em', borderBottom: '1px solid #1e293b' }
const tr: React.CSSProperties = { borderBottom: '1px solid #1e293b' }
const td: React.CSSProperties = { padding: '12px', verticalAlign: 'middle' }
const input: React.CSSProperties = { background: '#0f172a', border: '1px solid #334155', borderRadius: 6, padding: '7px 12px', color: '#e2e8f0', fontSize: 13, outline: 'none', width: '100%' }
const btn: React.CSSProperties = { background: '#0ea5e9', color: '#fff', border: 'none', borderRadius: 6, padding: '7px 14px', fontSize: 13, fontWeight: 600, cursor: 'pointer' }
const ghostBtn: React.CSSProperties = { background: 'transparent', color: '#94a3b8', border: '1px solid #334155', borderRadius: 6, padding: '7px 12px', fontSize: 13, cursor: 'pointer' }
const ghostBtnSm: React.CSSProperties = { ...ghostBtn, padding: '4px 8px', fontSize: 11 }
const dangerBtnSm: React.CSSProperties = { background: 'transparent', color: '#f87171', border: '1px solid #7f1d1d', borderRadius: 6, padding: '4px 8px', fontSize: 11, cursor: 'pointer' }
const overlay: React.CSSProperties = { position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.7)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 100 }
const modal: React.CSSProperties = { background: '#1e293b', border: '1px solid #334155', borderRadius: 12, padding: 24, width: 520, maxWidth: '90vw', maxHeight: '90vh', overflowY: 'auto' }
const modalTitle: React.CSSProperties = { fontSize: 16, fontWeight: 700, color: '#e2e8f0', marginBottom: 16 }
