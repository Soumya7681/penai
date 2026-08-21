import { useEffect, useRef, useState } from 'react'
import type { Chat } from '../lib/types'

interface Props {
  chats: Chat[]
  activeId: string | null
  busy: boolean
  onNew(): void
  onSelect(id: string): void
  onRename(id: string, title: string): void
  onDelete(id: string): void
  onOpenSettings(): void
  open: boolean
  onToggle(): void
}

export function Sidebar({
  chats,
  activeId,
  busy,
  onNew,
  onSelect,
  onRename,
  onDelete,
  onOpenSettings,
  open,
  onToggle,
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
    <>
      <button
        type="button"
        className="sidebar-toggle"
        onClick={onToggle}
        aria-label={open ? 'Hide chat list' : 'Show chat list'}
        aria-expanded={open}
      >
        {open ? '‹' : '›'}
      </button>

      <aside className={`sidebar ${open ? '' : 'sidebar-closed'}`} aria-label="Chat history">
        <div className="sidebar-head">
          <div className="brand">
            <span className="brand-mark" aria-hidden="true" />
            <span className="brand-text">PendriveAI</span>
          </div>
          <button type="button" className="btn btn-primary btn-block" onClick={onNew}>
            + New chat
          </button>
        </div>

        <nav className="chat-list">
          {chats.length === 0 && (
            <p className="empty-note">No chats yet. Ask something to begin.</p>
          )}
          {chats.map((c) => {
            const isActive = c.id === activeId
            return (
              <div key={c.id} className={`chat-row ${isActive ? 'chat-row-active' : ''}`}>
                {editing === c.id ? (
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
                  <button
                    type="button"
                    className="chat-title"
                    onClick={() => onSelect(c.id)}
                    title={c.title}
                  >
                    <span className="chat-title-text">{c.title}</span>
                    <span className="chat-date">{relativeTime(c.updatedAt)}</span>
                  </button>
                )}

                {editing !== c.id && (
                  <div className="chat-actions">
                    <button
                      type="button"
                      className="icon-btn"
                      onClick={() => startRename(c)}
                      title="Rename"
                      aria-label={`Rename ${c.title}`}
                    >
                      Rename
                    </button>
                    {confirmDelete === c.id ? (
                      <>
                        <button
                          type="button"
                          className="icon-btn icon-danger"
                          onClick={() => {
                            onDelete(c.id)
                            setConfirmDelete(null)
                          }}
                          disabled={busy && isActive}
                          title={
                            busy && isActive
                              ? 'Stop the response before deleting this chat'
                              : 'Confirm delete'
                          }
                        >
                          Confirm
                        </button>
                        <button
                          type="button"
                          className="icon-btn"
                          onClick={() => setConfirmDelete(null)}
                        >
                          Cancel
                        </button>
                      </>
                    ) : (
                      <button
                        type="button"
                        className="icon-btn icon-danger"
                        onClick={() => setConfirmDelete(c.id)}
                        title="Delete"
                        aria-label={`Delete ${c.title}`}
                      >
                        Delete
                      </button>
                    )}
                  </div>
                )}
              </div>
            )
          })}
        </nav>

        <div className="sidebar-foot">
          <button type="button" className="btn btn-ghost btn-block" onClick={onOpenSettings}>
            Settings
          </button>
          <p className="foot-note">Runs entirely on this computer.</p>
        </div>
      </aside>
    </>
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
