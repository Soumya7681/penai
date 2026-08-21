import { useState } from 'react'
import type { Message } from '../lib/types'
import { renderMarkdown } from '../lib/markdown'

interface Props {
  message: Message
  /** True while this message is the one currently being streamed into. */
  streaming: boolean
  onRetry?: (() => void) | undefined
}

export function MessageBubble({ message, streaming, onRetry }: Props) {
  const [showReasoning, setShowReasoning] = useState(false)
  const isUser = message.role === 'user'

  return (
    <article className={`msg msg-${message.role}`}>
      <div className="msg-gutter" aria-hidden="true">
        <span className={`avatar avatar-${message.role}`}>{isUser ? 'You' : 'AI'}</span>
      </div>

      <div className="msg-body">
        {message.reasoning && (
          <div className="reasoning">
            <button
              type="button"
              className="reasoning-toggle"
              onClick={() => setShowReasoning((v) => !v)}
              aria-expanded={showReasoning}
            >
              {showReasoning ? 'Hide reasoning' : 'Show reasoning'}
            </button>
            {showReasoning && <div className="reasoning-body">{message.reasoning}</div>}
          </div>
        )}

        {message.error ? (
          <div className="msg-error" role="alert">
            <strong>Could not get a reply.</strong>
            <p>{message.error}</p>
            {onRetry && (
              <button type="button" className="btn btn-ghost btn-small" onClick={onRetry}>
                Try again
              </button>
            )}
          </div>
        ) : isUser ? (
          // User text is rendered verbatim. Running it through the markdown
          // parser would mangle pasted code and change what the user typed.
          <div className="msg-plain">{message.content}</div>
        ) : (
          <div className="msg-markdown">
            {message.content ? (
              renderMarkdown(message.content)
            ) : streaming ? (
              <span className="thinking" aria-label="Generating">
                <span className="tdot" />
                <span className="tdot" />
                <span className="tdot" />
              </span>
            ) : (
              <span className="msg-empty">(empty reply)</span>
            )}
            {streaming && message.content && <span className="caret" aria-hidden="true" />}
          </div>
        )}

        <footer className="msg-meta">
          <time dateTime={new Date(message.createdAt).toISOString()}>
            {new Date(message.createdAt).toLocaleTimeString()}
          </time>
          {message.stopped && <span className="tag tag-warn">stopped</span>}
          {message.tokensPerSecond !== undefined && (
            <span className="tag" title="Generation speed reported by llama.cpp">
              {message.tokensPerSecond.toFixed(1)} tok/s
            </span>
          )}
        </footer>
      </div>
    </article>
  )
}
