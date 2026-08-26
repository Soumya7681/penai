import { useEffect, useRef, useState } from 'react'
import type { Chat, EngineState } from '../lib/types'
import { BrandMark } from './BrandMark'
import { Icon } from './Icon'

interface Props {
  chats: Chat[]
  activeId: string | null
  busy: boolean
  engine: EngineState
  onNew(): void
  onSelect(id: string): void
  onRename(id: string, title: string): void
  onDelete(id: string): void
  onOpenSettings(): void
  open: boolean
  onClose(): void
}

export function Sidebar({
  chats,
  activeId,
  busy,
  engine,
  onNew,
  onSelect,
  onRename,
  onDelete,
  onOpenSettings,
  open,
  onClose,
}: Props) {
  const [editing, setEditing] = useState<string | null>(null)
  const [draft, setDraft] = useState('')
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null)
  const inputRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    if (editing) inputRef.current?.select()
  }, [editing])

  const startRename = (c: Chat) => {
    setConfirmDelete(null)
    setEditing(c.id)
    setDraft(c.title)
  }

  const commit = () => {
    if (editing) {
      const t = draft.trim()
      // An empty title would make the row unclickable; keep the old one.
      if (t) onRename(editing, t.slice(0, 120))
    }
    setEditing(null)
  }

  return (
    <aside
      className={`sidebar ${open ? '' : 'sidebar-closed'}`}
      aria-label="Chats"
    >
      <div className="sidebar-head">
        <div className="brand">
          <BrandMark engine={engine} size={26} />
          <span>
            <span className="brand-name">PenAI</span>
            <span className="kicker brand-sub">local · offline</span>
          </span>
          <button
            type="button"
            className="icon-btn sidebar-collapse"
            onClick={onClose}
            aria-label="Hide chats"
          >
            <Icon name="panelLeft" size={18} />
          </button>
        </div>

        <button type="button" className="new-chat" onClick={onNew} disabled={busy}>
          <Icon name="plus" />
          New chat
        </button>
      </div>

      <nav className="chat-list">
        {chats.length > 0 && <span className="kicker list-kicker">Chats</span>}

        {chats.length === 0 && (
          <p className="empty-note">
            No chats yet. Ask the first question and one appears here.
          </p>
        )}

        {chats.map((c) => {
          const isActive = c.id === activeId
          const isEditing = editing === c.id
          return (
            <div key={c.id} className={`chat-row ${isActive ? 'chat-row-active' : ''}`}>
              {isEditing ? (
                <input
                  ref={inputRef}
                  className="chat-rename"
                  value={draft}
                  onChange={(e) => setDraft(e.target.value)}
                  onBlur={commit}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter') commit()
                    if (e.key === 'Escape') setEditing(null)
                  }}
                  aria-label="Chat title"
                />
              ) : (
                <>
                  <button
                    type="button"
                    className="chat-title"
                    onClick={() => onSelect(c.id)}
                    title={c.title}
                    aria-current={isActive ? 'true' : undefined}
                  >
                    <span className="chat-title-text">{c.title}</span>
                    <span className="chat-date">{relativeTime(c.updatedAt)}</span>
                  </button>

                  <div className="chat-actions">
                    {confirmDelete === c.id ? (
                      <>
                        <button
                          type="button"
                          className="icon-btn icon-btn-sm icon-btn-danger"
                          onClick={() => {
                            onDelete(c.id)
                            setConfirmDelete(null)
                          }}
                          disabled={busy && isActive}
                          title={
                            busy && isActive
                              ? 'Stop the reply before deleting this chat'
                              : 'Delete for good'
                          }
                          aria-label={`Delete ${c.title} for good`}
                        >
                          <Icon name="check" size={15} />
                        </button>
                        <button
                          type="button"
                          className="icon-btn icon-btn-sm"
                          onClick={() => setConfirmDelete(null)}
                          title="Keep it"
                          aria-label="Keep this chat"
                        >
                          <Icon name="close" size={15} />
                        </button>
                      </>
                    ) : (
                      <>
                        <button
                          type="button"
                          className="icon-btn icon-btn-sm ghost-icon"
                          onClick={() => startRename(c)}
                          title="Rename"
                          aria-label={`Rename ${c.title}`}
                        >
                          <Icon name="pencil" size={15} />
                        </button>
                        <button
                          type="button"
                          className="icon-btn icon-btn-sm icon-btn-danger ghost-icon"
                          onClick={() => setConfirmDelete(c.id)}
                          title="Delete"
                          aria-label={`Delete ${c.title}`}
                        >
                          <Icon name="trash" size={15} />
                        </button>
                      </>
                    )}
                  </div>
                </>
              )}
            </div>
          )
        })}
      </nav>

      <div className="sidebar-foot">
        <button type="button" className="btn btn-ghost btn-block" onClick={onOpenSettings}>
          <Icon name="sliders" />
          Settings
        </button>
        <p className="foot-note">Everything runs on this computer.</p>
      </div>
    </aside>
  )
}

function relativeTime(ts: number): string {
  const s = Math.max(0, Math.floor((Date.now() - ts) / 1000))
  if (s < 60) return 'just now'
  const m = Math.floor(s / 60)
  if (m < 60) return `${m}m ago`
  const h = Math.floor(m / 60)
  if (h < 24) return `${h}h ago`
  const d = Math.floor(h / 24)
  if (d < 7) return `${d}d ago`
  return new Date(ts).toLocaleDateString()
}
