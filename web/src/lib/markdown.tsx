/**
 * A small Markdown renderer that emits React elements.
 *
 * Why hand-written instead of react-markdown + remark + rehype: those pull in
 * roughly a megabyte of dependencies for a chat bubble, and this whole app has
 * to live on a slow USB drive. More importantly, this renderer never touches
 * `innerHTML` / `dangerouslySetInnerHTML`, so model output cannot inject markup
 * or script. Anything it does not understand falls through as literal text,
 * which is the safe direction.
 *
 * Supported: fenced code blocks with a language label, ATX headings, unordered
 * and ordered lists (one level), blockquotes, horizontal rules, pipe tables,
 * paragraphs, and inline code / bold / italic / strikethrough / links.
 */

import type { ReactNode } from 'react'
import { CodeBlock } from '../components/CodeBlock'

export function renderMarkdown(src: string): ReactNode[] {
  const lines = src.replace(/\r\n/g, '\n').split('\n')
  const out: ReactNode[] = []
  let i = 0
  let key = 0
  const k = () => `md${key++}`

  while (i < lines.length) {
    const line = lines[i] ?? ''

    // ---- fenced code block ----
    const fence = /^\s*(`{3,}|~{3,})\s*([\w+#.-]*)\s*$/.exec(line)
    if (fence) {
      const marker = fence[1] as string
      const lang = (fence[2] ?? '').trim()
      const body: string[] = []
      i++
      let closed = false
      while (i < lines.length) {
        const cur = lines[i] ?? ''
        // A closing fence must use the same character and be at least as long.
        const close = new RegExp(`^\\s*${marker[0] === '`' ? '`' : '~'}{${marker.length},}\\s*$`)
        if (close.test(cur)) {
          closed = true
          i++
          break
        }
        body.push(cur)
        i++
      }
      out.push(
        <CodeBlock key={k()} language={lang} code={body.join('\n')} unterminated={!closed} />,
      )
      continue
    }

    // ---- blank line ----
    if (!line.trim()) {
      i++
      continue
    }

    // ---- horizontal rule ----
    if (/^\s*([-*_])\s*(\1\s*){2,}$/.test(line)) {
      out.push(<hr key={k()} className="md-hr" />)
      i++
      continue
    }

    // ---- heading ----
    const h = /^(#{1,6})\s+(.*)$/.exec(line)
    if (h) {
      const level = (h[1] as string).length
      const text = h[2] ?? ''
      const Tag = `h${Math.min(level + 2, 6)}` as 'h3' | 'h4' | 'h5' | 'h6'
      out.push(
        <Tag key={k()} className={`md-h md-h${level}`}>
          {renderInline(text)}
        </Tag>,
      )
      i++
      continue
    }

    // ---- blockquote ----
    if (/^\s*>/.test(line)) {
      const body: string[] = []
      while (i < lines.length && /^\s*>/.test(lines[i] ?? '')) {
        body.push((lines[i] ?? '').replace(/^\s*>\s?/, ''))
        i++
      }
      out.push(
        <blockquote key={k()} className="md-quote">
          {renderMarkdown(body.join('\n'))}
        </blockquote>,
      )
      continue
    }

    // ---- table ----
    if (isTableStart(lines, i)) {
      const header = splitRow(lines[i] as string)
      i += 2 // header + delimiter
      const rows: string[][] = []
      while (i < lines.length && (lines[i] ?? '').includes('|') && (lines[i] ?? '').trim()) {
        rows.push(splitRow(lines[i] as string))
        i++
      }
      out.push(
        <div key={k()} className="md-table-wrap">
          <table className="md-table">
            <thead>
              <tr>
                {header.map((c, n) => (
                  <th key={n}>{renderInline(c)}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {rows.map((r, rn) => (
                <tr key={rn}>
                  {header.map((_, cn) => (
                    <td key={cn}>{renderInline(r[cn] ?? '')}</td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>,
      )
      continue
    }

    // ---- list ----
    const bullet = /^\s*([-*+])\s+(.*)$/
    const ordered = /^\s*(\d{1,9})[.)]\s+(.*)$/
    if (bullet.test(line) || ordered.test(line)) {
      const isOrdered = !bullet.test(line)
      const items: string[] = []
      while (i < lines.length) {
        const cur = lines[i] ?? ''
        const m = isOrdered ? ordered.exec(cur) : bullet.exec(cur)
        if (m) {
          items.push(m[2] ?? '')
          i++
          continue
        }
        // A continuation line is indented and not a new block.
        if (/^\s{2,}\S/.test(cur) && items.length) {
          items[items.length - 1] += ' ' + cur.trim()
          i++
          continue
        }
        break
      }
      const children = items.map((t, n) => <li key={n}>{renderInline(t)}</li>)
      out.push(
        isOrdered ? (
          <ol key={k()} className="md-list">
            {children}
          </ol>
        ) : (
          <ul key={k()} className="md-list">
            {children}
          </ul>
        ),
      )
      continue
    }

    // ---- paragraph ----
    const para: string[] = []
    while (i < lines.length) {
      const cur = lines[i] ?? ''
      if (
        !cur.trim() ||
        /^\s*(`{3,}|~{3,})/.test(cur) ||
        /^(#{1,6})\s+/.test(cur) ||
        /^\s*>/.test(cur) ||
        bullet.test(cur) ||
        ordered.test(cur) ||
        /^\s*([-*_])\s*(\1\s*){2,}$/.test(cur) ||
        isTableStart(lines, i)
      ) {
        break
      }
      para.push(cur)
      i++
    }
    out.push(
      <p key={k()} className="md-p">
        {renderInline(para.join('\n'))}
      </p>,
    )
  }

  return out
}

function isTableStart(lines: string[], i: number): boolean {
  const head = lines[i] ?? ''
  const sep = lines[i + 1] ?? ''
  if (!head.includes('|')) return false
  // The delimiter row is what actually identifies a table.
  return /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/.test(sep)
}

function splitRow(row: string): string[] {
  return row
    .trim()
    .replace(/^\|/, '')
    .replace(/\|$/, '')
    .split('|')
    .map((c) => c.trim())
}

/**
 * Inline formatting. Scans left to right and never re-parses its own output, so
 * a construct inside a code span stays literal.
 */
export function renderInline(text: string): ReactNode[] {
  const out: ReactNode[] = []
  let buf = ''
  let key = 0
  const k = () => `in${key++}`
  const flush = () => {
    if (buf) {
      out.push(buf)
      buf = ''
    }
  }

  let i = 0
  while (i < text.length) {
    const rest = text.slice(i)

    // Inline code first: its contents are literal.
    const code = /^(`+)([^`]|[^`][\s\S]*?)\1(?!`)/.exec(rest)
    if (code) {
      flush()
      out.push(
        <code key={k()} className="md-code-inline">
          {code[2]}
        </code>,
      )
      i += code[0].length
      continue
    }

    const strong = /^(\*\*|__)(?=\S)([\s\S]*?\S)\1/.exec(rest)
    if (strong) {
      flush()
      out.push(<strong key={k()}>{renderInline(strong[2] ?? '')}</strong>)
      i += strong[0].length
      continue
    }

    const strike = /^~~(?=\S)([\s\S]*?\S)~~/.exec(rest)
    if (strike) {
      flush()
      out.push(<del key={k()}>{renderInline(strike[1] ?? '')}</del>)
      i += strike[0].length
      continue
    }

    // Single-character emphasis. Requires a non-space neighbour so `a * b` and
    // `snake_case_name` are left alone.
    const em = /^([*_])(?=\S)([^*_]*?\S)\1(?![*_\w])/.exec(rest)
    if (em) {
      flush()
      out.push(<em key={k()}>{renderInline(em[2] ?? '')}</em>)
      i += em[0].length
      continue
    }

    const link = /^\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/.exec(rest)
    if (link) {
      flush()
      const href = link[2] ?? ''
      const label = link[1] ?? href
      if (isSafeHref(href)) {
        out.push(
          <a key={k()} href={href} target="_blank" rel="noreferrer noopener">
            {renderInline(label)}
          </a>,
        )
      } else {
        // Never emit a javascript:/data: URL. Show it as text instead.
        out.push(
          <span key={k()} className="md-unsafe-link" title="link scheme not allowed">
            {label} ({href})
          </span>,
        )
      }
      i += link[0].length
      continue
    }

    if (rest.startsWith('\n')) {
      flush()
      out.push(<br key={k()} />)
      i += 1
      continue
    }

    buf += text[i]
    i += 1
  }
  flush()
  return out
}

function isSafeHref(href: string): boolean {
  const h = href.trim().toLowerCase()
  if (h.startsWith('#') || h.startsWith('/') || h.startsWith('./') || h.startsWith('../')) {
    return true
  }
  return h.startsWith('http://') || h.startsWith('https://') || h.startsWith('mailto:')
}
