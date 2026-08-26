/**
 * Client for the local llama.cpp server.
 *
 * Every request goes to the same origin that served this page, which the
 * launcher bound to 127.0.0.1. There is no cloud provider, no API key and no
 * configurable remote host -- `assertLocal` enforces that at run time.
 *
 * The wire format is llama.cpp's OpenAI-compatible endpoint. Everything below
 * was verified against the packaged build (b10549):
 *   GET  /v1/health              200 ready / 503 still loading
 *   GET  /props                  context size and engine details
 *   POST /v1/chat/completions    SSE stream, `data: {...}`, ends `data: [DONE]`
 *   delta.content                normal tokens
 *   delta.reasoning_content      thinking tokens (Qwen3 thinking variants)
 *   stream_options.include_usage final chunk carries usage + timings
 *   aborting the request frees the server slot -- that is how Stop works
 */

import type { Message, RuntimeConfig, Role } from './types'

const FALLBACK_CONFIG: RuntimeConfig = {
  apiBase: '',
  storeBase: null,
  llamaPort: null,
  modelName: 'model.gguf',
  engineVersion: 'unknown',
  offline: true,
  defaults: {
    temperature: 0.7,
    topP: 0.95,
    maxTokens: 1024,
    ctxSize: 4096,
    systemPrompt:
      'You are PenAI, a helpful offline assistant running entirely on the ' +
      "user's own computer. Be concise and correct. When you write code, use " +
      'fenced code blocks with a language tag.',
  },
}

/**
 * Refuse any base URL that is not loopback. Defence in depth: even a tampered
 * runtime-config.json cannot point this app at a remote server.
 */
function assertLocal(base: string): string {
  if (base === '') return '' // same origin, always fine
  let u: URL
  try {
    u = new URL(base)
  } catch {
    return ''
  }
  const ok =
    u.protocol === 'http:' && (u.hostname === '127.0.0.1' || u.hostname === 'localhost')
  if (!ok) {
    console.error('[PenAI] refusing non-loopback API base:', base)
    return ''
  }
  return u.origin
}

let cached: RuntimeConfig | null = null

/**
 * The launcher writes `web/runtime-config.json` at startup. If the drive was
 * read-only it will be missing, so fall back to same-origin defaults and probe
 * for the chat-history sidecar.
 */
export async function loadRuntimeConfig(): Promise<RuntimeConfig> {
  if (cached) return cached
  let cfg: RuntimeConfig = FALLBACK_CONFIG
  try {
    const r = await fetch('./runtime-config.json', { cache: 'no-store' })
    if (r.ok) {
      const raw = (await r.json()) as Partial<RuntimeConfig>
      cfg = {
        ...FALLBACK_CONFIG,
        ...raw,
        defaults: { ...FALLBACK_CONFIG.defaults, ...(raw.defaults ?? {}) },
      }
    }
  } catch {
    // Expected when the file is absent; not an error worth showing the user.
  }
  cfg.apiBase = assertLocal(cfg.apiBase)
  cfg.storeBase = cfg.storeBase ? assertLocal(cfg.storeBase) || null : null
  cached = cfg
  return cfg
}

function url(cfg: RuntimeConfig, path: string): string {
  return `${cfg.apiBase}${path}`
}

// ---------------------------------------------------------------- health

export interface HealthResult {
  state: 'connected' | 'starting' | 'disconnected'
  detail?: string
}

export async function checkHealth(cfg: RuntimeConfig): Promise<HealthResult> {
  for (const path of ['/v1/health', '/health']) {
    try {
      const r = await fetch(url(cfg, path), { cache: 'no-store' })
      if (r.status === 200) return { state: 'connected' }
      if (r.status === 503) return { state: 'starting', detail: 'loading model' }
      if (r.status === 404) continue // older/newer build: try the other route
      return { state: 'disconnected', detail: `HTTP ${r.status}` }
    } catch (e) {
      return { state: 'disconnected', detail: (e as Error).message }
    }
  }
  return { state: 'disconnected', detail: 'no health endpoint' }
}

export interface EngineProps {
  ctxSize: number | null
  modelPath: string | null
}

export async function fetchProps(cfg: RuntimeConfig): Promise<EngineProps> {
  try {
    const r = await fetch(url(cfg, '/props'), { cache: 'no-store' })
    if (!r.ok) return { ctxSize: null, modelPath: null }
    const j = (await r.json()) as Record<string, unknown>
    const settings = j['default_generation_settings'] as Record<string, unknown> | undefined
    const n =
      (settings?.['n_ctx'] as number | undefined) ??
      (j['n_ctx'] as number | undefined) ??
      null
    return {
      ctxSize: typeof n === 'number' ? n : null,
      modelPath: (j['model_path'] as string | undefined) ?? null,
    }
  } catch {
    return { ctxSize: null, modelPath: null }
  }
}

// ------------------------------------------------------------- completions

export interface StreamParams {
  temperature: number
  topP: number
  maxTokens: number
}

export interface StreamCallbacks {
  onContent(delta: string): void
  onReasoning(delta: string): void
  /** Fired once at the end with llama.cpp's own timing numbers. */
  onUsage(tokensPerSecond: number | null): void
}

export interface WireMessage {
  role: Role
  content: string
}

/** Build the request payload: system prompt first, then the conversation. */
export function buildWireMessages(
  systemPrompt: string,
  history: Message[],
): WireMessage[] {
  const out: WireMessage[] = []
  const sys = systemPrompt.trim()
  if (sys) out.push({ role: 'system', content: sys })
  for (const m of history) {
    if (m.role === 'system') continue
    if (m.error) continue // never feed a failed turn back to the model
    if (!m.content.trim()) continue
    out.push({ role: m.role, content: m.content })
  }
  return out
}

/**
 * Stream a completion. Resolves when the stream ends normally.
 *
 * Cancellation: abort `signal`. llama.cpp notices the dropped connection and
 * frees the slot (verified: `/slots` shows `is_processing: false` afterwards),
 * so there is no separate stop endpoint to call.
 */
export async function streamChat(
  cfg: RuntimeConfig,
  messages: WireMessage[],
  params: StreamParams,
  cb: StreamCallbacks,
  signal: AbortSignal,
): Promise<void> {
  const res = await fetch(url(cfg, '/v1/chat/completions'), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    signal,
    body: JSON.stringify({
      messages,
      stream: true,
      stream_options: { include_usage: true },
      temperature: params.temperature,
      top_p: params.topP,
      max_tokens: params.maxTokens,
      cache_prompt: true,
    }),
  })

  if (!res.ok) {
    throw new Error(await describeHttpError(res))
  }
  if (!res.body) {
    throw new Error('the engine returned no response body')
  }

  const reader = res.body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''

  // SSE frames are separated by a blank line. Accumulate until we have one.
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    buffer += decoder.decode(value, { stream: true })

    let sep: number
    while ((sep = indexOfFrameEnd(buffer)) !== -1) {
      const frame = buffer.slice(0, sep)
      buffer = buffer.slice(sep).replace(/^(\r?\n){2}/, '')
      handleFrame(frame, cb)
    }
  }
  // Flush a trailing frame with no blank line after it.
  if (buffer.trim()) handleFrame(buffer, cb)
}

function indexOfFrameEnd(s: string): number {
  const a = s.indexOf('\n\n')
  const b = s.indexOf('\r\n\r\n')
  if (a === -1) return b
  if (b === -1) return a
  return Math.min(a, b)
}

function handleFrame(frame: string, cb: StreamCallbacks): void {
  for (const rawLine of frame.split(/\r?\n/)) {
    const line = rawLine.trimStart()
    if (!line.startsWith('data:')) continue
    const payload = line.slice(5).trim()
    if (!payload) continue
    if (payload === '[DONE]') continue

    let json: any
    try {
      json = JSON.parse(payload)
    } catch {
      // A partial frame should be impossible here, but never let one bad chunk
      // abort a whole answer.
      console.warn('[PenAI] skipping unparseable SSE payload')
      continue
    }

    if (json?.error) {
      throw new Error(String(json.error.message ?? json.error))
    }

    const choice = json?.choices?.[0]
    const delta = choice?.delta
    if (delta) {
      if (typeof delta.content === 'string' && delta.content) cb.onContent(delta.content)
      if (typeof delta.reasoning_content === 'string' && delta.reasoning_content) {
        cb.onReasoning(delta.reasoning_content)
      }
    }

    // Final chunk: `choices` is empty and `timings` carries the rate.
    const tps = json?.timings?.predicted_per_second
    if (typeof tps === 'number') cb.onUsage(tps)
  }
}

async function describeHttpError(res: Response): Promise<string> {
  let detail = ''
  try {
    const text = await res.text()
    try {
      const j = JSON.parse(text)
      detail = j?.error?.message ?? j?.message ?? text
    } catch {
      detail = text
    }
  } catch {
    /* body already consumed or unreadable */
  }
  detail = detail.slice(0, 400)

  if (res.status === 503) {
    return 'The engine is still loading the model. Wait a few seconds and try again.'
  }
  if (res.status === 400 && /context|n_ctx|too long/i.test(detail)) {
    return (
      'This conversation is longer than the context window. Start a new chat, ' +
      'or restart with a larger --ctx.'
    )
  }
  return `Engine error (HTTP ${res.status})${detail ? `: ${detail}` : ''}`
}

// ------------------------------------------------------------------- fetch

export interface FetchedPage {
  url: string
  title: string
  text: string
  bytes: number
  truncated: boolean
}

/**
 * Ask the launcher to retrieve one page.
 *
 * The browser cannot do this itself, and that is deliberate: the page's own
 * Content-Security-Policy allows nothing but 127.0.0.1, so the request goes to
 * the local sidecar, which checks the address and refuses anything on this
 * machine or this network. Off unless config.json turns it on.
 */
export async function fetchPage(storeBase: string, url: string): Promise<FetchedPage> {
  const r = await fetch(`${storeBase}/api/fetch`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ url }),
  })
  const j = (await r.json().catch(() => ({}))) as Partial<FetchedPage> & { error?: string }
  if (!r.ok) throw new Error(j.error || `the launcher answered ${r.status}`)
  return {
    url: j.url ?? url,
    title: j.title ?? '',
    text: j.text ?? '',
    bytes: j.bytes ?? 0,
    truncated: j.truncated === true,
  }
}
