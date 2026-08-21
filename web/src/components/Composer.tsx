import { useEffect, useRef } from 'react'

interface Props {
  value: string
  busy: boolean
  disabled: boolean
  disabledReason?: string | undefined
  onChange(v: string): void
  onSend(): void
  onStop(): void
}

const MAX_ROWS = 12

export function Composer({
  value,
  busy,
  disabled,
  disabledReason,
  onChange,
  onSend,
  onStop,
}: Props) {
  const ref = useRef<HTMLTextAreaElement>(null)

  // Grow with the content, up to a ceiling, then scroll.
  useEffect(() => {
    const el = ref.current
    if (!el) return
    el.style.height = 'auto'
    const line = 22
    const max = line * MAX_ROWS
    el.style.height = `${Math.min(el.scrollHeight, max)}px`
    el.style.overflowY = el.scrollHeight > max ? 'auto' : 'hidden'
  }, [value])

  useEffect(() => {
    if (!busy && !disabled) ref.current?.focus()
  }, [busy, disabled])

  const submit = () => {
    if (busy || disabled) return
    if (!value.trim()) return
    onSend()
  }

  return (
    <div className="composer">
      <div className={`composer-box ${disabled ? 'composer-disabled' : ''}`}>
        <textarea
          ref={ref}
          className="composer-input"
          rows={1}
          value={value}
          disabled={disabled}
          placeholder={
            disabled
              ? (disabledReason ?? 'Waiting for the AI engine...')
              : 'Ask anything. Enter to send, Shift+Enter for a new line.'
          }
          onChange={(e) => onChange(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) {
              e.preventDefault()
              submit()
            }
          }}
          aria-label="Message"
        />

        {busy ? (
          <button type="button" className="btn btn-stop" onClick={onStop}>
            Stop
          </button>
        ) : (
          <button
            type="button"
            className="btn btn-primary btn-send"
            onClick={submit}
            disabled={disabled || !value.trim()}
            aria-label="Send message"
          >
            Send
          </button>
        )}
      </div>
      <p className="composer-note">
        Runs on this computer only. The model can be wrong, so check anything that
        matters.
      </p>
    </div>
  )
}
