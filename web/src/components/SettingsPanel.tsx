import { useEffect, useRef } from 'react'
import type { Settings } from '../lib/types'
import { Icon } from './Icon'

interface Props {
  settings: Settings
  ctxFromEngine: number | null
  threadsFromLauncher: number
  portableAvailable: boolean
  onChange(patch: Partial<Settings>): void
  onClose(): void
  onExport(): void
  onImport(file: File): void
  onClearAll(): void
}

export function SettingsPanel({
  settings,
  ctxFromEngine,
  threadsFromLauncher,
  portableAvailable,
  onChange,
  onClose,
  onExport,
  onImport,
  onClearAll,
}: Props) {
  const fileRef = useRef<HTMLInputElement>(null)
  const closeRef = useRef<HTMLButtonElement>(null)

  // Escape closes the panel, and focus starts inside it, so the dialog can be
  // opened and dismissed without a pointer.
  useEffect(() => {
    closeRef.current?.focus()
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  return (
    <div className="modal-backdrop" onClick={onClose} role="presentation">
      <div
        className="modal"
        onClick={(e) => e.stopPropagation()}
        role="dialog"
        aria-modal="true"
        aria-label="Settings"
      >
        <header className="modal-head">
          <h2>Settings</h2>
          <button
            ref={closeRef}
            type="button"
            className="icon-btn"
            onClick={onClose}
            aria-label="Close settings"
          >
            <Icon name="close" size={18} />
          </button>
        </header>

        <div className="modal-body">
          <section className="setting-group">
            <h3>Generation</h3>

            <Slider
              label="Temperature"
              hint="Higher is more creative, lower is more focused and repeatable."
              min={0}
              max={2}
              step={0.05}
              value={settings.temperature}
              onChange={(v) => onChange({ temperature: v })}
            />

            <Slider
              label="Top P"
              hint="Nucleus sampling. 1.0 disables it."
              min={0.05}
              max={1}
              step={0.05}
              value={settings.topP}
              onChange={(v) => onChange({ topP: v })}
            />

            <label className="field">
              <span className="field-label">Maximum output tokens</span>
              <input
                type="number"
                min={16}
                max={32768}
                step={16}
                value={settings.maxTokens}
                onChange={(e) => {
                  const n = Number(e.target.value)
                  if (Number.isFinite(n)) onChange({ maxTokens: clamp(Math.round(n), 16, 32768) })
                }}
              />
              <span className="field-hint">
                How long a single reply may be. Generation is CPU-bound, so large
                values take proportionally longer.
              </span>
            </label>
          </section>

          <section className="setting-group">
            <h3>Engine</h3>
            <p className="explainer">
              Context size and CPU thread count are chosen by the launcher before
              llama.cpp starts, so they cannot be changed from this page. To change
              them, edit <code>config/config.json</code> on the drive or start with{' '}
              <code>--ctx</code> / <code>--threads</code>, then restart.
            </p>

            <label className="field">
              <span className="field-label">Context size (read-only)</span>
              <input
                type="text"
                readOnly
                value={
                  ctxFromEngine !== null
                    ? `${ctxFromEngine.toLocaleString()} tokens (reported by the engine)`
                    : `${settings.ctxSize.toLocaleString()} tokens (from config)`
                }
              />
            </label>

            <label className="field">
              <span className="field-label">CPU threads (read-only)</span>
              <input type="text" readOnly value={`${threadsFromLauncher}`} />
            </label>
          </section>

          <section className="setting-group">
            <h3>System prompt</h3>
            <textarea
              className="prompt-box"
              rows={5}
              value={settings.systemPrompt}
              onChange={(e) => onChange({ systemPrompt: e.target.value })}
              placeholder="Instructions the model receives before every conversation."
            />
            <span className="field-hint">
              Applied to new messages in every chat. Leave empty to send none.
            </span>
          </section>

          <section className="setting-group">
            <h3>Appearance</h3>
            <div className="seg">
              {(['system', 'dark', 'light'] as const).map((t) => (
                <button
                  key={t}
                  type="button"
                  className={`seg-btn ${settings.theme === t ? 'seg-active' : ''}`}
                  onClick={() => onChange({ theme: t })}
                >
                  {t}
                </button>
              ))}
            </div>
          </section>

          <section className="setting-group">
            <h3>Chat history</h3>
            <label className="check">
              <input
                type="checkbox"
                checked={settings.portableStorage && portableAvailable}
                disabled={!portableAvailable}
                onChange={(e) => onChange({ portableStorage: e.target.checked })}
              />
              <span>
                Also save history to the drive
                {!portableAvailable && ' (unavailable this session)'}
              </span>
            </label>
            <p className="explainer">
              {portableAvailable ? (
                <>
                  When enabled, chats are written to{' '}
                  <code>data/chats/chats.json</code> on the pendrive, so they travel
                  with it. They are also kept in this browser for speed.
                </>
              ) : (
                <>
                  The launcher&apos;s portable-history service is not running, so chats
                  are stored only in this browser&apos;s IndexedDB. That storage belongs
                  to this computer and this browser profile, so it will{' '}
                  <strong>not</strong> follow the pendrive to another machine. Use
                  Export below to carry it manually.
                </>
              )}
            </p>

            <div className="row-buttons">
              <button type="button" className="btn btn-ghost" onClick={onExport}>
                <Icon name="download" size={15} />
                Export all chats
              </button>
              <button
                type="button"
                className="btn btn-ghost"
                onClick={() => fileRef.current?.click()}
              >
                <Icon name="upload" size={15} />
                Import from file
              </button>
              <input
                ref={fileRef}
                type="file"
                accept="application/json,.json"
                style={{ display: 'none' }}
                onChange={(e) => {
                  const f = e.target.files?.[0]
                  if (f) onImport(f)
                  e.target.value = ''
                }}
              />
              <button type="button" className="btn btn-danger" onClick={onClearAll}>
                <Icon name="trash" size={15} />
                Delete all chats
              </button>
            </div>
          </section>

          <section className="setting-group">
            <h3>Privacy</h3>
            <p className="explainer">
              This page only ever talks to <code>127.0.0.1</code> on this computer.
              There is no account, no telemetry and no outbound request. The model
              runs as a local process; unplugging the network changes nothing.
            </p>
          </section>
        </div>
      </div>
    </div>
  )
}

function Slider({
  label,
  hint,
  min,
  max,
  step,
  value,
  onChange,
}: {
  label: string
  hint: string
  min: number
  max: number
  step: number
  value: number
  onChange(v: number): void
}) {
  return (
    <label className="field">
      <span className="field-label">
        {label} <span className="field-value">{value.toFixed(2)}</span>
      </span>
      <input
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={(e) => onChange(Number(e.target.value))}
      />
      <span className="field-hint">{hint}</span>
    </label>
  )
}

function clamp(n: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, n))
}
