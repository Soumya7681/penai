import type { EngineState } from '../lib/types'

interface Props {
  /** When given, the drive's indicator light reports the engine state. */
  engine?: EngineState
  size?: number
}

/**
 * The product mark: the drive itself, with its activity light.
 *
 * The light is not decoration. It carries the same three states as the readout
 * strip, so the mark in the sidebar corner is a live indicator you can read from
 * across the room -- amber while the model loads, jade once it answers, coral if
 * the engine goes away.
 */
export function BrandMark({ engine, size = 24 }: Props) {
  const state = engine ?? 'idle'
  return (
    <span
      className={`mark mark-${state}`}
      style={{ width: size, height: size }}
      aria-hidden="true"
    >
      <svg viewBox="0 0 24 24" width={size} height={size} fill="none">
        <rect
          className="mark-body"
          x="3"
          y="6.5"
          width="14"
          height="11"
          rx="3"
          stroke="currentColor"
          strokeWidth="1.6"
        />
        <path
          className="mark-plug"
          d="M17 10h3.4a.6.6 0 0 1 .6.6v2.8a.6.6 0 0 1-.6.6H17z"
          stroke="currentColor"
          strokeWidth="1.6"
          strokeLinejoin="round"
        />
        <circle className="mark-led" cx="7.4" cy="12" r="1.9" />
      </svg>
    </span>
  )
}
