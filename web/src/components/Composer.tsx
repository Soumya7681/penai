import { useEffect, useRef } from 'react'
import { Icon } from './Icon'

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
    const line = 23
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
      <div className="composer-inner">
        <div className={`composer-box ${disabled ? 'composer-disabled' : ''}`}>
          <textarea
            ref={ref}
            className="composer-input"
            rows={1}
            value={value}
            disabled={disabled}
            placeholder={
              disabled
                ? (disabledReason ?? 'Waiting for the engine')
                : 'Ask anything'
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
            <button type="button" className="stop-btn" onClick={onStop}>
              <Icon name="stop" size={14} />
              Stop
            </button>
          ) : (
            <button
              type="button"
              className="send"
              onClick={submit}
              disabled={disabled || !value.trim()}
              title="Send message"
              aria-label="Send message"
            >
              <Icon name="send" size={18} />
            </button>
          )}
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
