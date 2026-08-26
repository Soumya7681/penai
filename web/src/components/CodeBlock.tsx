import { useCallback, useState } from 'react'
import { Icon } from './Icon'

interface Props {
  code: string
  language: string
  /** True when the model was cut off mid-block, so the fence never closed. */
  unterminated?: boolean
}

/**
 * A fenced code block with a copy button.
 *
 * No syntax highlighting on purpose: a highlighter is the single biggest
 * dependency a chat UI tends to pull in, and this bundle has to live on a slow
 * USB drive. The language label is shown instead.
 */
export function CodeBlock({ code, language, unterminated }: Props) {
  const [copied, setCopied] = useState(false)
  const [failed, setFailed] = useState(false)

  const copy = useCallback(async () => {
    setFailed(false)
    try {
      // navigator.clipboard needs a secure context; http://127.0.0.1 qualifies.
      if (navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(code)
      } else {
        throw new Error('clipboard API unavailable')
      }
      setCopied(true)
      setTimeout(() => setCopied(false), 1400)
    } catch {
      // Fall back to the old selection trick, which works without permissions.
      try {
        const ta = document.createElement('textarea')
        ta.value = code
        ta.setAttribute('readonly', '')
        ta.style.position = 'fixed'
        ta.style.opacity = '0'
        document.body.appendChild(ta)
        ta.select()
        const ok = document.execCommand('copy')
        ta.remove()
        if (!ok) throw new Error('execCommand failed')
        setCopied(true)
        setTimeout(() => setCopied(false), 1400)
      } catch {
        setFailed(true)
        setTimeout(() => setFailed(false), 2500)
      }
    }
  }, [code])

  return (
    <div className="code-block">
      <div className="code-head">
        <span className="code-lang">{language || 'code'}</span>
        {unterminated && (
          <span className="code-warn" title="The reply ended before this block closed.">
            truncated
          </span>
        )}
        <button
          type="button"
          className={`code-copy ${copied ? 'code-copy-done' : ''}`}
          onClick={copy}
          aria-label="Copy code"
        >
          <Icon name={copied ? 'check' : 'copy'} size={13} />
          {failed ? 'Copy failed' : copied ? 'Copied' : 'Copy'}
        </button>
      </div>
      <pre className="code-pre">
        <code>{code}</code>
      </pre>
    </div>
  )
}
