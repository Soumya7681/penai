/**
 * The whole icon set, drawn inline.
 *
 * An icon font or an icon package would be the obvious choice, but both cost
 * bytes on a slow USB drive and an external font would be blocked by the page's
 * `font-src 'self'` policy. These are 16px stroke glyphs on a 24px grid, so they
 * stay sharp at any zoom and inherit `currentColor` from the button around them.
 */

import type { ReactNode } from 'react'

export type IconName =
  | 'menu'
  | 'plus'
  | 'pencil'
  | 'trash'
  | 'check'
  | 'close'
  | 'copy'
  | 'sliders'
  | 'send'
  | 'stop'
  | 'arrowDown'
  | 'refresh'
  | 'download'
  | 'upload'
  | 'panelLeft'

const PATHS: Record<IconName, ReactNode> = {
  menu: (
    <>
      <path d="M3 6h18" />
      <path d="M3 12h18" />
      <path d="M3 18h18" />
    </>
  ),
  plus: (
    <>
      <path d="M12 5v14" />
      <path d="M5 12h14" />
    </>
  ),
  pencil: (
    <>
      <path d="M4 20h4l10-10a2.8 2.8 0 0 0-4-4L4 16z" />
      <path d="M13.5 6.5l4 4" />
    </>
  ),
  trash: (
    <>
      <path d="M4 7h16" />
      <path d="M9 7V5h6v2" />
      <path d="M6 7l1 12h10l1-12" />
    </>
  ),
  check: <path d="M4 12.5l5 5L20 6.5" />,
  close: (
    <>
      <path d="M6 6l12 12" />
      <path d="M18 6L6 18" />
    </>
  ),
  copy: (
    <>
      <rect x="9" y="9" width="11" height="11" rx="2.5" />
      <path d="M15 5.5A2.5 2.5 0 0 0 12.5 4h-6A2.5 2.5 0 0 0 4 6.5v6A2.5 2.5 0 0 0 5.5 15" />
    </>
  ),
  sliders: (
    <>
      <path d="M4 8h10" />
      <path d="M18 8h2" />
      <path d="M4 16h4" />
      <path d="M12 16h8" />
      <circle cx="16" cy="8" r="2.2" />
      <circle cx="10" cy="16" r="2.2" />
    </>
  ),
  send: (
    <>
      <path d="M12 19V5" />
      <path d="M6 11l6-6 6 6" />
    </>
  ),
  stop: <rect x="7" y="7" width="10" height="10" rx="2" />,
  arrowDown: (
    <>
      <path d="M12 5v14" />
      <path d="M6 13l6 6 6-6" />
    </>
  ),
  refresh: (
    <>
      <path d="M20 12a8 8 0 1 1-2.6-5.9" />
      <path d="M20 4v5h-5" />
    </>
  ),
  download: (
    <>
      <path d="M12 4v11" />
      <path d="M7 11l5 5 5-5" />
      <path d="M5 20h14" />
    </>
  ),
  upload: (
    <>
      <path d="M12 20V9" />
      <path d="M7 13l5-5 5 5" />
      <path d="M5 4h14" />
    </>
  ),
  panelLeft: (
    <>
      <rect x="3.5" y="4.5" width="17" height="15" rx="2.5" />
      <path d="M10 4.5v15" />
    </>
  ),
}

interface Props {
  name: IconName
  /** Pixel size of the square box. Defaults to the 16px used across the UI. */
  size?: number
  className?: string
}

export function Icon({ name, size = 16, className }: Props) {
  return (
    <svg
      className={className ? `icon ${className}` : 'icon'}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.7"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {PATHS[name]}
    </svg>
  )
}
