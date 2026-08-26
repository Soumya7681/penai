import type { EngineState } from '../lib/types'
import { Icon } from './Icon'

interface Props {
  engine: EngineState
  detail?: string | undefined
  modelName: string
  engineVersion: string
  ctxSize: number | null
  threads: number
  portable: boolean
  portableError: string | null
  onMenu(): void
}

const ENGINE_VALUE: Record<EngineState, string> = {
  connected: 'ready',
  starting: 'loading',
  disconnected: 'no reply',
}

const ENGINE_TONE: Record<EngineState, string> = {
  connected: 'readout-ok',
  starting: 'readout-wait',
  disconnected: 'readout-down',
}

/**
 * The readout strip: the honest facts about what is running, written like the
 * label on a piece of hardware.
 *
 * Every value here answers a question the user would otherwise have to take on
 * trust -- is anything actually listening, which weights are loaded, which
 * llama.cpp build, how much context there really is, and whether chats are
 * being written to the drive or only to this browser.
 */
export function StatusBar({
  engine,
  detail,
  modelName,
  engineVersion,
  ctxSize,
  threads,
  portable,
  portableError,
  onMenu,
}: Props) {
  const history = portableError ? 'write failed' : portable ? 'drive' : 'browser'
  const historyTone = portableError ? 'readout-down' : portable ? 'readout-ok' : ''

  return (
    <div className="plate">
      <button
        type="button"
        className="icon-btn plate-menu"
        onClick={onMenu}
        aria-label="Show chats"
      >
        <Icon name="menu" size={18} />
      </button>

      <div className="readout" aria-label="Runtime status">
        <Cell
          k="link"
          v="offline"
          title="This page can only reach 127.0.0.1. No request leaves the computer."
          led
        />

        <Cell
          k="engine"
          v={engine === 'starting' && detail ? `${ENGINE_VALUE[engine]} - ${detail}` : ENGINE_VALUE[engine]}
          tone={ENGINE_TONE[engine]}
          title={detail ?? `The llama.cpp server is ${ENGINE_VALUE[engine]}.`}
          led
          live
        />

        <Cell k="model" v={shortModel(modelName)} title={`Model file: ${modelName}`} />

        <Cell k="build" v={engineVersion} title="llama.cpp build actually running" />

        {ctxSize !== null && (
          <Cell
            k="ctx"
            v={ctxSize.toLocaleString()}
            title="Context window, fixed by the launcher at startup"
          />
        )}

        <Cell
          k="thr"
          v={String(threads)}
          title="CPU threads, chosen by the launcher at startup"
        />

        <Cell
          k="history"
          v={history}
          tone={historyTone}
          title={
            portableError
              ? `Could not write to the drive: ${portableError}`
              : portable
                ? 'Chats are written to data/chats/chats.json on the drive, so they travel with it.'
                : 'Chats stay in this browser on this computer. Export them to carry them.'
          }
        />
      </div>
    </div>
  )
}

function Cell({
  k,
  v,
  title,
  tone,
  led,
  live,
}: {
  k: string
  v: string
  title: string
  tone?: string
  led?: boolean
  live?: boolean
}) {
  return (
    <span
      className={`readout-item ${tone ?? ''} ${led ? 'readout-state' : ''}`}
      title={title}
      {...(live ? { 'aria-live': 'polite' as const } : {})}
    >
      {led && <span className="led" />}
      <span className="readout-k">{k}</span>
      <span className="readout-v">{v}</span>
    </span>
  )
}

function shortModel(name: string): string {
  const base = name.replace(/\.gguf$/i, '')
  return base.length > 30 ? `${base.slice(0, 27)}...` : base || 'model'
}
