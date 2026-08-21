import type { EngineState } from '../lib/types'

interface Props {
  engine: EngineState
  detail?: string | undefined
  modelName: string
  engineVersion: string
  ctxSize: number | null
  threads: number
  portable: boolean
  portableError: string | null
}

const LABEL: Record<EngineState, string> = {
  connected: 'AI Engine: Connected',
  starting: 'AI Engine: Starting',
  disconnected: 'AI Engine: Disconnected',
}

/**
 * The honesty strip. It states plainly that the app is offline, whether the
 * engine is actually reachable, and where chats are being stored -- rather than
 * letting the user assume any of it.
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
}: Props) {
  return (
    <div className="statusbar">
      <span className="chip chip-offline" title="No network requests leave this computer.">
        <span className="dot dot-offline" />
        Offline Mode
      </span>

      <span
        className={`chip chip-${engine}`}
        title={detail ?? LABEL[engine]}
        aria-live="polite"
      >
        <span className={`dot dot-${engine}`} />
        {LABEL[engine]}
        {engine === 'starting' && detail ? ` (${detail})` : ''}
      </span>

      <span className="chip chip-quiet" title={`Model file: ${modelName}`}>
        {shortModel(modelName)}
      </span>

      <span className="chip chip-quiet" title="llama.cpp build actually running">
        llama.cpp {engineVersion}
      </span>

      {ctxSize !== null && (
        <span className="chip chip-quiet" title="Context window fixed by the launcher at startup">
          ctx {ctxSize.toLocaleString()}
        </span>
      )}

      <span className="chip chip-quiet" title="CPU threads chosen by the launcher at startup">
        {threads} threads
      </span>

      <span
        className={`chip ${portableError ? 'chip-disconnected' : portable ? 'chip-connected' : 'chip-quiet'}`}
        title={
          portableError
            ? `Portable history error: ${portableError}`
            : portable
              ? 'Chats are saved to data/chats/chats.json on the drive, so they travel with it.'
              : 'Chats are saved in this browser only and will stay on this computer.'
        }
      >
        {portableError
          ? 'History: write failed'
          : portable
            ? 'History: on the drive'
            : 'History: this browser only'}
      </span>
    </div>
  )
}

function shortModel(name: string): string {
  const base = name.replace(/\.gguf$/i, '')
  return base.length > 34 ? `${base.slice(0, 31)}...` : base || 'model'
}
