import { useCallback, useState } from 'react'
import type { Message } from '../lib/types'
import { renderMarkdown } from '../lib/markdown'
import { Icon } from './Icon'

interface Props {
  message: Message
  /** True while this message is the one currently being streamed into. */
  streaming: boolean
  /** Re-asks the question that produced this reply. Absent while busy. */
  onRetry?: (() => void) | undefined
}

/** A user message past this size is clamped in the thread with a Show more. */
const CLAMP_CHARS = 900
const CLAMP_LINES = 14

export function MessageBubble({ message, streaming, onRetry }: Props) {
  const [showReasoning, setShowReasoning] = useState(false)
  const [copied, setCopied] = useState(false)
  const [expanded, setExpanded] = useState(false)
  const isUser = message.role === 'user'
  // A pasted file should not push the reply off the screen.
  const clamped =
    isUser &&
    !expanded &&
    (message.content.length > CLAMP_CHARS ||
      message.content.split('\n').length > CLAMP_LINES)

  const copy = useCallback(() => {
    void (async () => {
      try {
        await navigator.clipboard.writeText(message.content)
        setCopied(true)
        setTimeout(() => setCopied(false), 1400)
      } catch {
        // Clipboard permission can be refused; the text is still selectable.
      }
    })()
  }, [message.content])

  const hasText = message.content.length > 0
  const showTools = !streaming && hasText && !message.error

  return (
    <article className={`turn turn-${message.role}`}>
      {!isUser && (
        <div className="turn-head">
          <span className="role">Reply</span>
          <span className="meta">
            <time dateTime={new Date(message.createdAt).toISOString()}>
              {new Date(message.createdAt).toLocaleTimeString([], {
                hour: '2-digit',
                minute: '2-digit',
              })}
            </time>
            {message.stopped && <span className="tag tag-warn">stopped</span>}
            {message.tokensPerSecond !== undefined && (
              <span className="tag" title="Generation speed reported by llama.cpp">
                {message.tokensPerSecond.toFixed(1)} tok/s
              </span>
            )}
          </span>
        </div>
      )}

      <div className="turn-body">
        {message.reasoning && (
          <div className="reasoning">
            <button
              type="button"
              className="reasoning-toggle"
              onClick={() => setShowReasoning((v) => !v)}
              aria-expanded={showReasoning}
            >
              {showReasoning ? 'Hide thinking' : 'Show thinking'}
            </button>
            {showReasoning && <div className="reasoning-body">{message.reasoning}</div>}
          </div>
        )}

        {message.error ? (
          <div className="msg-error" role="alert">
            <strong>No reply came back.</strong>
            <p>{message.error}</p>
            {onRetry && (
              <button type="button" className="btn btn-ghost btn-small" onClick={onRetry}>
                <Icon name="refresh" size={14} />
                Ask again
              </button>
            )}
          </div>
        ) : isUser ? (
          // User text is shown verbatim. Running it through the markdown parser
          // would mangle pasted code and change what the user typed.
          <div className={`bubble ${clamped ? 'bubble-clamped' : ''}`}>
            {message.content}
            {(clamped || expanded) && (
              <button
                type="button"
                className="bubble-more"
                onClick={() => setExpanded((v) => !v)}
                aria-expanded={expanded}
              >
                {expanded ? 'Show less' : 'Show all'}
              </button>
            )}
          </div>
        ) : (
          <div className="md">
            {hasText ? (
              renderMarkdown(message.content)
            ) : streaming ? (
              <span className="thinking" aria-label="Writing a reply">
                <span className="tdot" />
                <span className="tdot" />
                <span className="tdot" />
              </span>
            ) : (
              <span className="msg-empty">The model returned nothing.</span>
            )}
            {streaming && hasText && <span className="caret" aria-hidden="true" />}
          </div>
        )}

        {showTools && (
          <div className={`turn-tools ${copied ? 'turn-tools-open' : ''}`}>
            <button
              type="button"
              className={`icon-btn icon-btn-sm ${copied ? 'icon-btn-ok' : ''}`}
              onClick={copy}
              title={copied ? 'Copied' : 'Copy text'}
              aria-label="Copy this message"
            >
              <Icon name={copied ? 'check' : 'copy'} size={15} />
            </button>
            {!isUser && onRetry && (
              <button
                type="button"
                className="icon-btn icon-btn-sm"
                onClick={onRetry}
                title="Ask again"
                aria-label="Ask the same question again"
              >
                <Icon name="refresh" size={15} />
              </button>
            )}
          </div>
        )}
      </div>
    </article>
  )
}
