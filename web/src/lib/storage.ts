/**
 * Chat persistence.
 *
 * Two layers, by design:
 *
 *  1. IndexedDB in the browser -- always available, survives a page reload.
 *     Limitation the user must know about: IndexedDB is scoped to the origin
 *     AND the browser profile on the host computer, so by default chats stay on
 *     that computer and do NOT travel with the pendrive.
 *
 *  2. The launcher's portable-storage sidecar -- optional. It writes one JSON
 *     document to `data/chats/chats.json` on the pendrive itself, so history
 *     moves with the drive. If it is absent we degrade to layer 1 silently.
 *
 * On startup both layers are read and merged (union by id, last write wins by
 * `updatedAt`, tombstones respected) so moving between computers converges
 * instead of losing data.
 */

import type { Chat, Message, StoreSnapshot } from './types'

// Data identity, not a brand name. Renaming the database would orphan every
// chat already stored in a browser, so it keeps the pre-rename value.
const DB_NAME = 'pendriveai'
const DB_VERSION = 1
const CHATS = 'chats'
const MESSAGES = 'messages'

// ------------------------------------------------------------------ IndexedDB

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    if (typeof indexedDB === 'undefined') {
      reject(new Error('IndexedDB is unavailable in this browser'))
      return
    }
    const req = indexedDB.open(DB_NAME, DB_VERSION)
    req.onupgradeneeded = () => {
      const db = req.result
      if (!db.objectStoreNames.contains(CHATS)) {
        db.createObjectStore(CHATS, { keyPath: 'id' })
      }
      if (!db.objectStoreNames.contains(MESSAGES)) {
        const s = db.createObjectStore(MESSAGES, { keyPath: 'id' })
        s.createIndex('byChat', 'chatId', { unique: false })
      }
    }
    req.onsuccess = () => resolve(req.result)
    req.onerror = () => reject(req.error ?? new Error('cannot open IndexedDB'))
  })
}

function txDone(tx: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve()
    tx.onabort = () => reject(tx.error ?? new Error('transaction aborted'))
    tx.onerror = () => reject(tx.error ?? new Error('transaction failed'))
  })
}

function getAll<T>(store: IDBObjectStore): Promise<T[]> {
  return new Promise((resolve, reject) => {
    const r = store.getAll()
    r.onsuccess = () => resolve(r.result as T[])
    r.onerror = () => reject(r.error ?? new Error('read failed'))
  })
}

export async function readLocal(): Promise<StoreSnapshot> {
  try {
    const db = await openDb()
    const tx = db.transaction([CHATS, MESSAGES], 'readonly')
    const [chats, messages] = await Promise.all([
      getAll<Chat>(tx.objectStore(CHATS)),
      getAll<Message>(tx.objectStore(MESSAGES)),
    ])
    db.close()
    return { version: 1, chats, messages }
  } catch (e) {
    console.warn('[PenAI] IndexedDB unreadable:', e)
    return { version: 1, chats: [], messages: [] }
  }
}

/** Replace the whole local database with `snap`. Used after a merge. */
export async function writeLocalAll(snap: StoreSnapshot): Promise<void> {
  const db = await openDb()
  const tx = db.transaction([CHATS, MESSAGES], 'readwrite')
  tx.objectStore(CHATS).clear()
  tx.objectStore(MESSAGES).clear()
  for (const c of snap.chats) tx.objectStore(CHATS).put(c)
  for (const m of snap.messages) tx.objectStore(MESSAGES).put(m)
  await txDone(tx)
  db.close()
}

export async function putChatLocal(chat: Chat): Promise<void> {
  const db = await openDb()
  const tx = db.transaction(CHATS, 'readwrite')
  tx.objectStore(CHATS).put(chat)
  await txDone(tx)
  db.close()
}

export async function putMessagesLocal(msgs: Message[]): Promise<void> {
  if (!msgs.length) return
  const db = await openDb()
  const tx = db.transaction(MESSAGES, 'readwrite')
  for (const m of msgs) tx.objectStore(MESSAGES).put(m)
  await txDone(tx)
  db.close()
}

export async function deleteChatLocal(chatId: string, messageIds: string[]): Promise<void> {
  const db = await openDb()
  const tx = db.transaction([CHATS, MESSAGES], 'readwrite')
  tx.objectStore(CHATS).delete(chatId)
  for (const id of messageIds) tx.objectStore(MESSAGES).delete(id)
  await txDone(tx)
  db.close()
}

// --------------------------------------------------------- portable sidecar

export interface PortableStore {
  available: boolean
  base: string | null
  /** Set when the last write failed, so the UI can surface it honestly. */
  lastError: string | null
}

/** Loopback ports the launcher may have used, if runtime-config.json is absent. */
const PROBE_PORTS = [47611, 47612, 47613]

export async function detectPortable(storeBase: string | null): Promise<string | null> {
  const candidates = storeBase
    ? [storeBase]
    : PROBE_PORTS.map((p) => `http://127.0.0.1:${p}`)
  for (const base of candidates) {
    try {
      const c = new AbortController()
      const t = setTimeout(() => c.abort(), 1200)
      const r = await fetch(`${base}/api/health`, { signal: c.signal, cache: 'no-store' })
      clearTimeout(t)
      if (r.ok) {
        const j = (await r.json()) as { kind?: string }
        if (j.kind === 'pendriveai-store') return base
      }
    } catch {
      // Not there; try the next candidate.
    }
  }
  return null
}

export async function readPortable(base: string): Promise<StoreSnapshot | null> {
  try {
    const r = await fetch(`${base}/api/chats`, { cache: 'no-store' })
    if (!r.ok) return null
    const j = (await r.json()) as Partial<StoreSnapshot>
    return {
      version: 1,
      chats: Array.isArray(j.chats) ? j.chats : [],
      messages: Array.isArray(j.messages) ? j.messages : [],
      savedAt: j.savedAt,
    }
  } catch (e) {
    console.warn('[PenAI] portable store unreadable:', e)
    return null
  }
}

export async function writePortable(base: string, snap: StoreSnapshot): Promise<void> {
  const body = JSON.stringify({ ...snap, version: 1, savedAt: Date.now() })
  const r = await fetch(`${base}/api/chats`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body,
  })
  if (!r.ok) {
    let detail = `HTTP ${r.status}`
    try {
      const j = (await r.json()) as { error?: string }
      if (j.error) detail = j.error
    } catch {
      /* keep the status code */
    }
    throw new Error(detail)
  }
}

// ------------------------------------------------------------------- merging

/**
 * Merge two snapshots.
 *
 * Chats: union by id; on conflict keep the one with the newer `updatedAt`. A
 * tombstone (`deleted: true`) wins if it is the newer record, so deleting a
 * chat on one computer is not resurrected by syncing with another.
 *
 * Messages: union by id. Messages are append-only in practice, so the first
 * copy seen is authoritative; a longer `content` wins, which resolves the case
 * where a stream was still in progress when one side was saved.
 */
export function mergeSnapshots(a: StoreSnapshot, b: StoreSnapshot): StoreSnapshot {
  const chats = new Map<string, Chat>()
  for (const c of [...a.chats, ...b.chats]) {
    const prev = chats.get(c.id)
    if (!prev || (c.updatedAt ?? 0) > (prev.updatedAt ?? 0)) chats.set(c.id, c)
  }

  const messages = new Map<string, Message>()
  for (const m of [...a.messages, ...b.messages]) {
    const prev = messages.get(m.id)
    if (!prev) {
      messages.set(m.id, m)
      continue
    }
    const prevLen = prev.content?.length ?? 0
    const curLen = m.content?.length ?? 0
    if (curLen > prevLen) messages.set(m.id, m)
  }

  // Drop messages belonging to chats that were deleted, so tombstones actually
  // reclaim space instead of leaving orphans behind forever.
  const live = new Set(
    [...chats.values()].filter((c) => !c.deleted).map((c) => c.id),
  )
  const keptMessages = [...messages.values()].filter((m) => live.has(m.chatId))

  return {
    version: 1,
    chats: [...chats.values()].sort((x, y) => y.updatedAt - x.updatedAt),
    messages: keptMessages.sort((x, y) => x.createdAt - y.createdAt),
  }
}

/** Chats that should be shown in the sidebar. */
export function visibleChats(snap: StoreSnapshot): Chat[] {
  return snap.chats.filter((c) => !c.deleted).sort((a, b) => b.updatedAt - a.updatedAt)
}

// ------------------------------------------------------------------ settings

// Kept for the same reason as DB_NAME: renaming it would silently reset
// everyone's settings.
const SETTINGS_KEY = 'pendriveai.settings.v1'

export function loadSettingsRaw(): unknown {
  try {
    const raw = localStorage.getItem(SETTINGS_KEY)
    return raw ? JSON.parse(raw) : null
  } catch {
    return null
  }
}

export function saveSettingsRaw(value: unknown): void {
  try {
    localStorage.setItem(SETTINGS_KEY, JSON.stringify(value))
  } catch (e) {
    // Private browsing or a full quota. Not fatal: settings just will not stick.
    console.warn('[PenAI] cannot save settings:', e)
  }
}

// ------------------------------------------------------------ export/import

/** Download the whole history as a file the user can keep on the pendrive. */
export function exportToFile(snap: StoreSnapshot): void {
  const body = JSON.stringify({ ...snap, version: 1, savedAt: Date.now() }, null, 2)
  const blob = new Blob([body], { type: 'application/json' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19)
  a.download = `penai-chats-${stamp}.json`
  document.body.appendChild(a)
  a.click()
  a.remove()
  // Revoke on the next tick so the download has definitely started.
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}

export async function importFromFile(file: File): Promise<StoreSnapshot> {
  const text = await file.text()
  const j = JSON.parse(text) as Partial<StoreSnapshot>
  if (!Array.isArray(j.chats) || !Array.isArray(j.messages)) {
    throw new Error('That file does not look like a PenAI export.')
  }
  return { version: 1, chats: j.chats, messages: j.messages }
}
