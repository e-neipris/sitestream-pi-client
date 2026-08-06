// Copied verbatim from packages/web/src/components/MediaPanel.tsx — its only
// dependencies (react-query, @/lib/api, dayjs) are matched exactly by this
// project's own lib/api.ts, so it runs unmodified against the local
// pi-portal server instead of the cloud API. If the cloud version changes,
// re-sync this copy by hand (no shared package between the two yet).
import { useState, useRef, useMemo } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { filesApi, type VideoFile } from '@/lib/api'
import dayjs from 'dayjs'

export interface MediaContext {
  /** Zone IDs whose uploaded files should be visible (sourceZoneId match) */
  sourceZoneIds: string[]
  /** File IDs pulled in via schedules */
  scheduleFileIds: string[]
  /** Zone to attach on upload — omit for group-level context (user picks zone at schedule time) */
  uploadZoneId?: string
  /** Tenant to scope files to — needed when SUPER_ADMIN views without impersonating */
  tenantId?: string
  /** Skip zone/schedule filtering and show all files for the tenant (used by TenantDetail) */
  showAll?: boolean
}

interface Props {
  /** When omitted the panel shows all files (global Media Library view) */
  context?: MediaContext
}

function formatBytes(bytes: string | number): string {
  const n = Number(bytes)
  if (n < 1024) return `${n} B`
  if (n < 1_048_576) return `${(n / 1024).toFixed(1)} KB`
  if (n < 1_073_741_824) return `${(n / 1_048_576).toFixed(1)} MB`
  return `${(n / 1_073_741_824).toFixed(2)} GB`
}

export default function MediaPanel({ context }: Props) {
  const qc = useQueryClient()
  const [uploading, setUploading] = useState(false)
  const [uploadProgress, setUploadProgress] = useState(0)
  const [pendingDuplicate, setPendingDuplicate] = useState<{ file: File; existing: VideoFile } | null>(null)
  const fileRef = useRef<HTMLInputElement>(null)

  const { data: files, isLoading } = useQuery({
    queryKey: ['files', { tenantId: context?.tenantId }],
    queryFn: () => filesApi.list(context?.tenantId).then(r => r.data),
    // Poll while any file has a transcode in flight, so "Transcoding for
    // multicast..." resolves to Ready/Failed on its own instead of needing a
    // manual page refresh — stops polling once nothing is actually pending.
    refetchInterval: (query) => {
      const data = query.state.data as VideoFile[] | undefined
      const hasInFlight = data?.some(f => f.multicastTranscodeStatus === 'PENDING' || f.multicastTranscodeStatus === 'PROCESSING')
      return hasInFlight ? 10_000 : false
    },
  })

  const displayedFiles = useMemo(() => {
    if (!context || !files) return files
    if (context.showAll) return files
    const scheduleIds = new Set(context.scheduleFileIds)
    const zoneIds = new Set(context.sourceZoneIds)
    return files.filter(f =>
      scheduleIds.has(f.id) || (f.sourceZoneId != null && zoneIds.has(f.sourceZoneId))
    )
  }, [files, context])

  const deleteFile = useMutation({
    mutationFn: (id: string) => filesApi.delete(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['files'] }),
    onError: (err: any) => {
      alert(`Delete failed: ${err.response?.data?.error ?? err.message ?? 'Unknown error'}`)
    },
  })

  const runUpload = async (file: File, replaceFileId?: string) => {
    setUploading(true)
    setUploadProgress(0)
    try {
      let initiateData: { fileId: string; presignedPost: { url: string; fields: Record<string, string> } }
      try {
        const res = await filesApi.initiateUpload({
          filename: file.name,
          contentType: file.type as any,
          sizeBytes: file.size,
          zoneId: context?.uploadZoneId,
          replaceFileId,
        })
        initiateData = res.data
      } catch (err: any) {
        throw new Error(`API error (step 1 – initiate): ${err.response?.data?.error ?? err.message ?? 'Unknown error'}`)
      }

      const formData = new FormData()
      Object.entries(initiateData.presignedPost.fields).forEach(([k, v]) => formData.append(k, v))
      formData.append('file', file)

      const xhr = new XMLHttpRequest()
      xhr.upload.onprogress = (ev) => {
        if (ev.lengthComputable) setUploadProgress(Math.round((ev.loaded / ev.total) * 100))
      }

      await new Promise<void>((resolve, reject) => {
        xhr.onload = () => xhr.status < 300
          ? resolve()
          : reject(new Error(`S3 rejected upload (step 2 – S3 POST): HTTP ${xhr.status}\n${xhr.responseText}`))
        xhr.onerror = () => reject(new Error('Step 2 – S3 POST: network error (check S3 CORS configuration)'))
        xhr.open('POST', initiateData.presignedPost.url)
        xhr.send(formData)
      })

      const etag = xhr.getResponseHeader('ETag') ?? ''
      try {
        await filesApi.confirm(initiateData.fileId, etag)
      } catch (err: any) {
        throw new Error(`API error (step 3 – confirm): ${err.response?.data?.error ?? err.message}`)
      }

      qc.invalidateQueries({ queryKey: ['files'] })
    } catch (err: any) {
      alert(`Upload failed: ${err.message}`)
    } finally {
      setUploading(false)
      setUploadProgress(0)
      if (fileRef.current) fileRef.current.value = ''
    }
  }

  const handleFileChange = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (!file) return

    const existing = files?.find(f => f.filename === file.name)
    if (existing) {
      setPendingDuplicate({ file, existing })
      return
    }

    await runUpload(file)
  }

  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'flex-end', marginBottom: 16 }}>
        <input
          ref={fileRef}
          type="file"
          accept="video/mp4,video/quicktime,video/webm,video/mpeg"
          style={{ display: 'none' }}
          onChange={handleFileChange}
        />
        <button style={btn} disabled={uploading} onClick={() => fileRef.current?.click()}>
          {uploading ? `Uploading ${uploadProgress}%…` : '↑ Upload Video'}
        </button>
      </div>

      {uploading && (
        <div style={progressBar}>
          <div style={{ ...progressFill, width: `${uploadProgress}%` }} />
        </div>
      )}

      {pendingDuplicate && (
        <DuplicateFileModal
          filename={pendingDuplicate.file.name}
          existing={pendingDuplicate.existing}
          onCancel={() => {
            setPendingDuplicate(null)
            if (fileRef.current) fileRef.current.value = ''
          }}
          onReplace={() => {
            const { file, existing } = pendingDuplicate
            setPendingDuplicate(null)
            runUpload(file, existing.id)
          }}
          onUploadAsNew={() => {
            const { file } = pendingDuplicate
            setPendingDuplicate(null)
            runUpload(file)
          }}
        />
      )}

      <table style={table}>
        <thead>
          <tr>
            {['Filename', 'Size', 'Duration', 'Used In', 'Uploaded', ''].map(col => (
              <th key={col} style={th}>{col}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {displayedFiles?.map((f: VideoFile) => (
            <tr key={f.id} style={tr}>
              <td style={td}>
                <span style={{ color: '#e2e8f0', fontSize: 14 }}>{f.filename}</span>
                <div style={{ color: '#475569', fontSize: 11, fontFamily: 'monospace', marginTop: 2 }}>
                  {f.etag || <span style={{ color: '#f59e0b' }}>Pending confirmation</span>}
                </div>
                <MulticastTranscodeBadge file={f} />
              </td>
              <td style={td}><span style={mutedText}>{formatBytes(f.sizeBytes)}</span></td>
              <td style={td}>
                <span style={mutedText}>
                  {f.durationSeconds ? `${Math.floor(f.durationSeconds / 60)}m ${f.durationSeconds % 60}s` : '—'}
                </span>
              </td>
              <td style={td}><span style={mutedText}>{f._count?.schedules ?? 0} schedules</span></td>
              <td style={td}><span style={mutedText}>{dayjs(f.uploadedAt).format('MMM D, YYYY')}</span></td>
              <td style={td}>
                <button
                  style={dangerBtnSm}
                  disabled={(f._count?.schedules ?? 0) > 0}
                  title={(f._count?.schedules ?? 0) > 0 ? 'Remove from all schedules first' : undefined}
                  onClick={() => deleteFile.mutate(f.id)}
                >
                  Delete
                </button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      {!isLoading && !displayedFiles?.length && (
        <p style={{ color: '#475569', fontSize: 13, textAlign: 'center', padding: 40 }}>
          {context
            ? 'No media here yet. Upload a video or add a schedule to bring files into this zone.'
            : 'No videos uploaded yet.'}
        </p>
      )}
    </div>
  )
}

/**
 * Only rendered once a file's multicastTranscodeStatus leaves NOT_NEEDED
 * (the default for the vast majority of files, which never touch a
 * multicast-enabled device) — silent until it's actually relevant.
 */
function MulticastTranscodeBadge({ file }: { file: VideoFile }) {
  if (file.multicastTranscodeStatus === 'NOT_NEEDED') return null

  const { label, color } = {
    PENDING: { label: 'Queued for multicast transcode', color: '#94a3b8' },
    PROCESSING: { label: 'Transcoding for multicast — this can take a few minutes', color: '#0ea5e9' },
    READY: { label: 'Multicast-ready (MPEG-2)', color: '#22c55e' },
    FAILED: { label: 'Multicast transcode failed', color: '#f87171' },
  }[file.multicastTranscodeStatus]

  return (
    <div
      style={{ color, fontSize: 11, marginTop: 2 }}
      title={file.multicastTranscodeStatus === 'FAILED' ? (file.multicastTranscodeError ?? undefined) : undefined}
    >
      {label}
    </div>
  )
}

function DuplicateFileModal({ filename, existing, onCancel, onReplace, onUploadAsNew }: {
  filename: string
  existing: VideoFile
  onCancel: () => void
  onReplace: () => void
  onUploadAsNew: () => void
}) {
  return (
    <Overlay onClose={onCancel}>
      <h2 style={modalTitle}>File already exists</h2>
      <p style={{ color: '#94a3b8', fontSize: 13, marginBottom: 8 }}>
        A file named <strong style={{ color: '#e2e8f0' }}>{filename}</strong> was already uploaded
        {existing._count?.schedules ? ` and is used in ${existing._count.schedules} schedule(s)` : ''}.
      </p>
      <p style={{ color: '#94a3b8', fontSize: 13, marginBottom: 20 }}>
        Replace it to update the existing file in place (schedules keep pointing at it), or upload this as a separate new copy.
      </p>
      <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8 }}>
        <button style={ghostBtn} onClick={onCancel}>Cancel</button>
        <button style={ghostBtn} onClick={onUploadAsNew}>Upload as new copy</button>
        <button style={btn} onClick={onReplace}>Replace existing</button>
      </div>
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

const table: React.CSSProperties = { width: '100%', borderCollapse: 'collapse' }
const th: React.CSSProperties = { textAlign: 'left', padding: '10px 12px', fontSize: 11, color: '#64748b', textTransform: 'uppercase', letterSpacing: '0.05em', borderBottom: '1px solid #1e293b' }
const tr: React.CSSProperties = { borderBottom: '1px solid #1e293b' }
const td: React.CSSProperties = { padding: '12px', verticalAlign: 'middle' }
const mutedText: React.CSSProperties = { color: '#64748b', fontSize: 13 }
const btn: React.CSSProperties = { background: '#0ea5e9', color: '#fff', border: 'none', borderRadius: 6, padding: '7px 14px', fontSize: 13, fontWeight: 600, cursor: 'pointer' }
const dangerBtnSm: React.CSSProperties = { background: 'transparent', color: '#f87171', border: '1px solid #7f1d1d', borderRadius: 6, padding: '4px 8px', fontSize: 11, cursor: 'pointer' }
const progressBar: React.CSSProperties = { height: 4, background: '#1e293b', borderRadius: 2, marginBottom: 16, overflow: 'hidden' }
const progressFill: React.CSSProperties = { height: '100%', background: '#0ea5e9', transition: 'width 0.2s' }
const ghostBtn: React.CSSProperties = { background: 'transparent', color: '#94a3b8', border: '1px solid #334155', borderRadius: 6, padding: '7px 12px', fontSize: 13, cursor: 'pointer' }
const overlay: React.CSSProperties = { position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.7)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 100 }
const modal: React.CSSProperties = { background: '#1e293b', border: '1px solid #334155', borderRadius: 12, padding: 24, width: 460, maxWidth: '90vw', maxHeight: '90vh', overflowY: 'auto' }
const modalTitle: React.CSSProperties = { fontSize: 16, fontWeight: 700, color: '#e2e8f0', marginBottom: 16 }
