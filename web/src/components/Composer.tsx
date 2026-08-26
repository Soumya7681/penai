import { useEffect, useRef, useState } from 'react'
import type { Paste } from '../lib/types'
import { Icon } from './Icon'

interface Props {
  value: string
  pastes: Paste[]
  busy: boolean
  disabled: boolean
  disabledReason?: string | undefined
  /** True only when the launcher's config turns web access on. */
  canFetch: boolean
  onChange(v: string): void
  onAddPaste(text: string): void
  onRemovePaste(id: string): void
  onFetch(url: string): Promise<void>
  onSend(): void
  onStop(): void
}

const MAX_ROWS = 12

/**
 * Anything longer than this arrives as an attachment instead of as text in the
 * box. A whole file pasted into a chat input is still the message -- it just
 * should not push the thing you are writing off the screen.
 */
const PASTE_MAX_CHARS = 1200
const PASTE_MAX_LINES = 20

export function Composer({
  value,
  pastes,
  busy,
  disabled,
  disabledReason,
  canFetch,
  onChange,
  onAddPaste,
  onRemovePaste,
  onFetch,
  onSend,
  onStop,
}: Props) {
  const ref = useRef<HTMLTextAreaElement>(null)
  const urlRef = useRef<HTMLInputElement>(null)
  const [open, setOpen] = useState<string | null>(null)
  const [urlOpen, setUrlOpen] = useState(false)
  const [url, setUrl] = useState('')
  const [fetching, setFetching] = useState(false)
  const [fetchError, setFetchError] = useState<string | null>(null)

  useEffect(() => {
    if (urlOpen) urlRef.current?.focus()
  }, [urlOpen])

  const runFetch = async () => {
    const target = url.trim()
    if (!target || fetching) return
    setFetching(true)
    setFetchError(null)
    try {
      // A bare domain is what people actually type.
      await onFetch(/^https?:\/\//i.test(target) ? target : `https://${target}`)
      setUrl('')
      setUrlOpen(false)
    } catch (e) {
      setFetchError((e as Error).message)
    } finally {
      setFetching(false)
    }
  }

  // Grow with the content, up to a ceiling, then scroll.
  useEffect(() => {
    const el = ref.current
    if (!el) return
    el.style.height = 'auto'
    const line = 23
    const max = line * MAX_ROWS
    el.style.height = `${Math.min(el.scrollHeight, max)}px`
    el.style.overflowY = el.scrollHeight > max ? 'auto' : 'hidden'
  }, [value])

  useEffect(() => {
    if (!busy && !disabled) ref.current?.focus()
  }, [busy, disabled])

  const canSend = Boolean(value.trim() || pastes.length)

  const submit = () => {
    if (busy || disabled || !canSend) return
    onSend()
  }

  const handlePaste = (e: React.ClipboardEvent<HTMLTextAreaElement>) => {
    const text = e.clipboardData.getData('text/plain')
    if (!isLong(text)) return
    // Keep it out of the box, and out of the undo stack, as an attachment.
    e.preventDefault()
    onAddPaste(text)
  }

  return (
    <div className="composer">
      <div className="composer-inner">
        <div className={`composer-box ${disabled ? 'composer-disabled' : ''}`}>
          {pastes.length > 0 && (
            <div className="pastes">
              {pastes.map((p, i) => (
                <div key={p.id} className="paste">
                  <button
                    type="button"
                    className="paste-chip"
                    onClick={() => setOpen((v) => (v === p.id ? null : p.id))}
                    aria-expanded={open === p.id}
                    title={open === p.id ? 'Hide the pasted text' : 'Show the pasted text'}
                  >
                    <Icon name={p.source ? 'globe' : 'paste'} size={14} />
                    <span className="paste-name">
                      {p.source ?? `Pasted text${pastes.length > 1 ? ` ${i + 1}` : ''}`}
                    </span>
                    <span className="paste-meta">{describe(p.text)}</span>
                  </button>
                  <button
                    type="button"
                    className="icon-btn icon-btn-sm"
                    onClick={() => {
                      if (open === p.id) setOpen(null)
                      onRemovePaste(p.id)
                    }}
                    title="Remove"
                    aria-label={`Remove pasted text ${i + 1}`}
                  >
                    <Icon name="close" size={14} />
                  </button>

                  {open === p.id && (
                    <pre className="paste-preview">
                      <code>{p.text}</code>
                    </pre>
                  )}
                </div>
              ))}
            </div>
          )}

          {urlOpen && (
            <div className="urlbar">
              <Icon name="globe" size={15} />
              <input
                ref={urlRef}
                className="urlbar-input"
                value={url}
                onChange={(e) => setUrl(e.target.value)}
                placeholder="example.com/page"
                aria-label="Address to fetch"
                spellCheck={false}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') {
                    e.preventDefault()
                    void runFetch()
                  }
                  if (e.key === 'Escape') {
                    setUrlOpen(false)
                    setFetchError(null)
                  }
                }}
              />
              <button
                type="button"
                className="btn btn-primary btn-small"
                onClick={() => void runFetch()}
                disabled={!url.trim() || fetching}
              >
                {fetching ? 'Fetching' : 'Fetch'}
              </button>
              <button
                type="button"
                className="icon-btn icon-btn-sm"
                onClick={() => {
                  setUrlOpen(false)
                  setFetchError(null)
                }}
                aria-label="Cancel"
              >
                <Icon name="close" size={15} />
              </button>
            </div>
          )}

          {fetchError && (
            <p className="urlbar-error" role="alert">
              {fetchError}
            </p>
          )}

          <div className="composer-row">
            <textarea
              ref={ref}
              className="composer-input"
              rows={1}
              value={value}
              disabled={disabled}
              placeholder={
                disabled
                  ? (disabledReason ?? 'Waiting for the engine')
                  : pastes.length
                    ? `Add a question about the ${
                        pastes.some((p) => p.source) ? 'page' : 'pasted text'
                      }, or send it as it is`
                    : 'Ask anything'
              }
              onChange={(e) => onChange(e.target.value)}
              onPaste={handlePaste}
              onKeyDown={(e) => {
                if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) {
                  e.preventDefault()
                  submit()
                }
              }}
              aria-label="Message"
            />

            {canFetch && !busy && (
              <button
                type="button"
                className={`icon-btn ${urlOpen ? 'icon-btn-on' : ''}`}
                onClick={() => {
                  setUrlOpen((v) => !v)
                  setFetchError(null)
                }}
                title="Fetch a web page"
                aria-label="Fetch a web page"
                aria-expanded={urlOpen}
              >
                <Icon name="globe" size={18} />
              </button>
            )}

            {busy ? (
              <button type="button" className="stop-btn" onClick={onStop}>
                <Icon name="stop" size={14} />
                Stop
              </button>
            ) : (
              <button
                type="button"
                className="send"
                onClick={submit}
                disabled={disabled || !canSend}
                title="Send message"
                aria-label="Send message"
              >
                <Icon name="send" size={18} />
              </button>
            )}
          </div>
        </div>

        <div className="composer-hint">
          <p>Replies come from a model on this computer, so check anything that matters.</p>
          <span className="keys">
            <kbd>Enter</kbd> sends
            <span className="keys-sep">·</span>
            <kbd>Shift</kbd>+<kbd>Enter</kbd> adds a line
          </span>
        </div>
      </div>
    </div>
  )
}

function isLong(text: string): boolean {
  if (text.length > PASTE_MAX_CHARS) return true
  let lines = 1
  for (const ch of text) {
    if (ch === '\n' && ++lines > PASTE_MAX_LINES) return true
  }
  return false
}

/** "212 lines · 8.4 KB", or just the size when it is a single long line. */
function describe(text: string): string {
  const lines = text.split('\n').length
  const bytes = new Blob([text]).size
  const size =
    bytes >= 1024 * 1024
      ? `${(bytes / 1048576).toFixed(1)} MB`
      : bytes >= 1024
        ? `${(bytes / 1024).toFixed(1)} KB`
        : `${bytes} B`
  return lines > 1 ? `${lines.toLocaleString()} lines · ${size}` : size
}
