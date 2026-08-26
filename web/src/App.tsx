import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Sidebar } from './components/Sidebar'
import { StatusBar } from './components/StatusBar'
import { MessageBubble } from './components/MessageBubble'
import { Composer } from './components/Composer'
import { SettingsPanel } from './components/SettingsPanel'
import { BrandMark } from './components/BrandMark'
import { Icon } from './components/Icon'
import {
  buildWireMessages,
  checkHealth,
  fetchPage,
  fetchProps,
  searchWeb,
  loadRuntimeConfig,
  streamChat,
} from './lib/api'
import {
  deleteChatLocal,
  detectStore,
  exportToFile,
  importFromFile,
  loadSettingsRaw,
  mergeSnapshots,
  putChatLocal,
  putMessagesLocal,
  readLocal,
  readPortable,
  saveSettingsRaw,
  visibleChats,
  writeLocalAll,
  writePortable,
} from './lib/storage'
import type {
  Chat,
  EngineState,
  Message,
  Paste,
  RuntimeConfig,
  Settings,
  StoreSnapshot,
} from './lib/types'
import { newId } from './lib/types'

const EMPTY: StoreSnapshot = { version: 1, chats: [], messages: [] }

/** Below this width the chat list is a drawer over the thread, not a column. */
const NARROW = '(max-width: 860px)'

function isNarrow(): boolean {
  return typeof window !== 'undefined' && window.matchMedia(NARROW).matches
}

function defaultSettings(cfg: RuntimeConfig): Settings {
  return {
    temperature: cfg.defaults.temperature,
    topP: cfg.defaults.topP,
    maxTokens: cfg.defaults.maxTokens,
    ctxSize: cfg.defaults.ctxSize,
    threads: 0,
    systemPrompt: cfg.defaults.systemPrompt,
    portableStorage: true,
    theme: 'system',
  }
}

export default function App() {
  const [cfg, setCfg] = useState<RuntimeConfig | null>(null)
  const [settings, setSettings] = useState<Settings | null>(null)
  const [snap, setSnap] = useState<StoreSnapshot>(EMPTY)
  const [activeId, setActiveId] = useState<string | null>(null)
  const [engine, setEngine] = useState<EngineState>('starting')
  const [engineDetail, setEngineDetail] = useState<string | undefined>(undefined)
  const [ctxFromEngine, setCtxFromEngine] = useState<number | null>(null)
  const [portableBase, setPortableBase] = useState<string | null>(null)
  // Web fetching is a launcher setting, so the page asks the launcher.
  const [canFetch, setCanFetch] = useState(false)
  const [canSearch, setCanSearch] = useState(false)
  const [portableError, setPortableError] = useState<string | null>(null)
  const [draft, setDraft] = useState('')
  // Long pasted blocks wait here until the message is sent.
  const [pastes, setPastes] = useState<Paste[]>([])
  const [busy, setBusy] = useState(false)
  const [banner, setBanner] = useState<string | null>(null)
  const [showSettings, setShowSettings] = useState(false)
  // Open as a column on a desktop, shut as a drawer on a phone.
  const [sidebarOpen, setSidebarOpen] = useState(() => !isNarrow())
  const [showJump, setShowJump] = useState(false)
  const [booted, setBooted] = useState(false)

  const abortRef = useRef<AbortController | null>(null)
  const scrollRef = useRef<HTMLDivElement>(null)
  const pinnedRef = useRef(true)
  const snapRef = useRef<StoreSnapshot>(EMPTY)
  snapRef.current = snap

  // ------------------------------------------------------------------ boot
  useEffect(() => {
    let cancelled = false
    ;(async () => {
      const rc = await loadRuntimeConfig()
      if (cancelled) return
      setCfg(rc)

      const raw = loadSettingsRaw() as Partial<Settings> | null
      const base = defaultSettings(rc)
      setSettings(raw ? { ...base, ...raw } : base)

      const local = await readLocal()
      const store = await detectStore(rc.storeBase)
      const base2 = store?.base ?? null
      if (cancelled) return
      setPortableBase(base2)
      setCanFetch(store?.fetch === true)
      setCanSearch(store?.search === true)

      let merged = local
      if (base2) {
        const remote = await readPortable(base2)
        if (remote) {
          merged = mergeSnapshots(local, remote)
          // Write the merged view back to both sides so they converge.
          try {
            await writeLocalAll(merged)
          } catch (e) {
            console.warn('[PenAI] could not update local copy:', e)
          }
        }
      }
      if (cancelled) return
      setSnap(merged)
      const first = visibleChats(merged)[0]
      setActiveId(first ? first.id : null)
      setBooted(true)
    })()
    return () => {
      cancelled = true
    }
  }, [])

  // Persist settings whenever they change.
  useEffect(() => {
    if (settings) saveSettingsRaw(settings)
  }, [settings])

  // Theme.
  useEffect(() => {
    const t = settings?.theme ?? 'system'
    const root = document.documentElement
    if (t === 'system') root.removeAttribute('data-theme')
    else root.setAttribute('data-theme', t)
  }, [settings?.theme])

  // ------------------------------------------------------- health polling
  useEffect(() => {
    if (!cfg) return
    let stop = false
    let timer: number | undefined

    const tick = async () => {
      const h = await checkHealth(cfg)
      if (stop) return
      setEngine(h.state)
      setEngineDetail(h.detail)
      if (h.state === 'connected' && ctxFromEngine === null) {
        const p = await fetchProps(cfg)
        if (!stop && p.ctxSize) setCtxFromEngine(p.ctxSize)
      }
      // Poll fast while it is coming up, slowly once it is healthy.
      const delay = h.state === 'connected' ? 8000 : 1500
      timer = window.setTimeout(tick, delay)
    }
    tick()
    return () => {
      stop = true
      if (timer) window.clearTimeout(timer)
    }
  }, [cfg, ctxFromEngine])

  // ------------------------------------------------------------ persistence
  const persist = useCallback(
    async (next: StoreSnapshot, opts?: { chat?: Chat; messages?: Message[] }) => {
      // Local first: it is fast and always available.
      try {
        if (opts?.chat) await putChatLocal(opts.chat)
        if (opts?.messages) await putMessagesLocal(opts.messages)
        if (!opts) await writeLocalAll(next)
      } catch (e) {
        console.warn('[PenAI] local save failed:', e)
      }
      // Then the drive, if enabled and available.
      if (portableBase && settings?.portableStorage) {
        try {
          await writePortable(portableBase, next)
          setPortableError(null)
        } catch (e) {
          setPortableError((e as Error).message)
        }
      }
    },
    [portableBase, settings?.portableStorage],
  )

  // Debounced full-snapshot sync to the drive, so a long stream does not write
  // the whole history on every token.
  const syncTimer = useRef<number | undefined>(undefined)
  const scheduleSync = useCallback(() => {
    if (syncTimer.current) window.clearTimeout(syncTimer.current)
    syncTimer.current = window.setTimeout(() => {
      void persist(snapRef.current)
    }, 1500)
  }, [persist])

  // ------------------------------------------------------------- scrolling
  const onScroll = useCallback(() => {
    const el = scrollRef.current
    if (!el) return
    // "Pinned" means the user is at the bottom; only then do we auto-scroll.
    const pinned = el.scrollHeight - el.scrollTop - el.clientHeight < 80
    pinnedRef.current = pinned
    setShowJump(!pinned && el.scrollHeight > el.clientHeight + 160)
  }, [])

  const jumpToLatest = useCallback(() => {
    const el = scrollRef.current
    if (!el) return
    el.scrollTop = el.scrollHeight
    pinnedRef.current = true
    setShowJump(false)
  }, [])

  const messages = useMemo(
    () => snap.messages.filter((m) => m.chatId === activeId),
    [snap.messages, activeId],
  )

  useEffect(() => {
    if (!pinnedRef.current) return
    const el = scrollRef.current
    if (el) el.scrollTop = el.scrollHeight
  }, [messages, busy])

  // Switching chats starts at the newest message with no jump prompt showing.
  useEffect(() => {
    setShowJump(false)
  }, [activeId])

  // -------------------------------------------------------------- actions
  const newChat = useCallback(() => {
    if (busy) return
    const now = Date.now()
    const chat: Chat = { id: newId('chat'), title: 'New chat', createdAt: now, updatedAt: now }
    setSnap((s) => {
      const next = { ...s, chats: [chat, ...s.chats] }
      void persist(next, { chat })
      return next
    })
    setActiveId(chat.id)
    setDraft('')
    setPastes([])
    setBanner(null)
  }, [busy, persist])

  const renameChat = useCallback(
    (id: string, title: string) => {
      setSnap((s) => {
        const chats = s.chats.map((c) =>
          c.id === id ? { ...c, title, updatedAt: Date.now() } : c,
        )
        const next = { ...s, chats }
        const chat = chats.find((c) => c.id === id)
        void persist(next, chat ? { chat } : undefined)
        return next
      })
    },
    [persist],
  )

  const deleteChat = useCallback(
    (id: string) => {
      if (busy && id === activeId) return
      const doomed = snapRef.current.messages.filter((m) => m.chatId === id).map((m) => m.id)
      setSnap((s) => {
        // Keep a tombstone so the delete survives a sync from another computer.
        const chats = s.chats.map((c) =>
          c.id === id ? { ...c, deleted: true, updatedAt: Date.now() } : c,
        )
        const next = { chats, messages: s.messages.filter((m) => m.chatId !== id), version: 1 as const }
        void (async () => {
          try {
            await deleteChatLocal(id, doomed)
            const tomb = chats.find((c) => c.id === id)
            if (tomb) await putChatLocal(tomb)
          } catch (e) {
            console.warn('[PenAI] delete failed locally:', e)
          }
          void persist(next)
        })()
        return next
      })
      if (id === activeId) {
        const remaining = visibleChats(snapRef.current).filter((c) => c.id !== id)
        setActiveId(remaining[0]?.id ?? null)
      }
    },
    [activeId, busy, persist],
  )

  const stop = useCallback(() => {
    abortRef.current?.abort()
  }, [])

  const send = useCallback(
    async (text: string, retryOf?: string) => {
      if (!cfg || !settings || busy) return
      const content = text.trim()
      if (!content) return

      let chatId = activeId
      const now = Date.now()
      let createdChat: Chat | undefined

      if (!chatId) {
        createdChat = {
          id: newId('chat'),
          title: titleFrom(content),
          createdAt: now,
          updatedAt: now,
        }
        chatId = createdChat.id
      }

      const userMsg: Message = {
        id: newId('msg'),
        chatId,
        role: 'user',
        content,
        createdAt: now,
      }
      const aiMsg: Message = {
        id: newId('msg'),
        chatId,
        role: 'assistant',
        content: '',
        createdAt: now + 1,
      }

      // History sent to the model: everything already in this chat, plus the new
      // question. A retry drops the failed assistant turn first.
      const priorAll = snapRef.current.messages.filter((m) => m.chatId === chatId)
      const prior = retryOf ? priorAll.filter((m) => m.id !== retryOf) : priorAll

      setSnap((s) => {
        const chats = createdChat
          ? [createdChat, ...s.chats]
          : s.chats.map((c) =>
              c.id === chatId
                ? {
                    ...c,
                    updatedAt: now,
                    title: c.title === 'New chat' ? titleFrom(content) : c.title,
                  }
                : c,
            )
        const kept = retryOf ? s.messages.filter((m) => m.id !== retryOf) : s.messages
        return { version: 1, chats, messages: [...kept, userMsg, aiMsg] }
      })
      setActiveId(chatId)
      setDraft('')
      setPastes([])
      setBanner(null)
      setBusy(true)
      pinnedRef.current = true

      const controller = new AbortController()
      abortRef.current = controller

      let acc = ''
      let reasoning = ''
      let tps: number | null = null
      let stopped = false

      const patch = (fields: Partial<Message>) => {
        setSnap((s) => ({
          ...s,
          messages: s.messages.map((m) => (m.id === aiMsg.id ? { ...m, ...fields } : m)),
        }))
      }

      try {
        await streamChat(
          cfg,
          buildWireMessages(settings.systemPrompt, [...prior, userMsg]),
          {
            temperature: settings.temperature,
            topP: settings.topP,
            maxTokens: settings.maxTokens,
          },
          {
            onContent: (d) => {
              acc += d
              patch({ content: acc })
            },
            onReasoning: (d) => {
              reasoning += d
              patch({ reasoning })
            },
            onUsage: (v) => {
              tps = v
            },
          },
          controller.signal,
        )
      } catch (e) {
        const err = e as Error
        if (err.name === 'AbortError') {
          stopped = true
        } else {
          patch({ error: err.message || 'The engine did not respond.' })
          setBanner(err.message)
        }
      } finally {
        abortRef.current = null
        setBusy(false)

        const final: Partial<Message> = {
          content: acc,
          ...(reasoning ? { reasoning } : {}),
          ...(stopped ? { stopped: true } : {}),
          ...(tps !== null ? { tokensPerSecond: tps } : {}),
        }
        patch(final)

        // Save once at the end rather than on every token.
        const latest: StoreSnapshot = {
          version: 1,
          chats: snapRef.current.chats,
          messages: snapRef.current.messages.map((m) =>
            m.id === aiMsg.id ? { ...m, ...final } : m,
          ),
        }
        snapRef.current = latest
        const chat = latest.chats.find((c) => c.id === chatId)
        void persist(latest, {
          ...(chat ? { chat } : {}),
          messages: [userMsg, { ...aiMsg, ...final }],
        })
        scheduleSync()
      }
    },
    [activeId, busy, cfg, persist, scheduleSync, settings],
  )

  const retry = useCallback(
    (failedId: string) => {
      const msgs = snapRef.current.messages.filter((m) => m.chatId === activeId)
      const idx = msgs.findIndex((m) => m.id === failedId)
      // The user question is the message immediately before the failed reply.
      for (let i = idx - 1; i >= 0; i -= 1) {
        const m = msgs[i]
        if (m && m.role === 'user') {
          setSnap((s) => ({
            ...s,
            messages: s.messages.filter((x) => x.id !== failedId && x.id !== m.id),
          }))
          void send(m.content, failedId)
          return
        }
      }
    },
    [activeId, send],
  )

  const addPage = useCallback(
    async (url: string) => {
      if (!portableBase) throw new Error('the launcher is not running, so nothing can be fetched')
      const page = await fetchPage(portableBase, url)
      if (!page.text.trim()) throw new Error('that page had no readable text in it')
      const host = hostOf(page.url)
      setPastes((p) => [
        ...p,
        {
          id: newId('page'),
          // The model is told where this came from, because it is not the
          // user's own words and it should not be treated as an instruction.
          text: `Web page fetched from ${page.url}${page.title ? `\nTitle: ${page.title}` : ''}\n\n${page.text}`,
          source: host,
          title: page.title || host,
        },
      ])
    },
    [portableBase],
  )

  const runSearch = useCallback(
    async (q: string) => {
      if (!portableBase) throw new Error('the launcher is not running, so nothing can be searched')
      return searchWeb(portableBase, q)
    },
    [portableBase],
  )

  const clearAll = useCallback(() => {
    if (busy) return
    if (!window.confirm('Delete every chat on this drive and in this browser? This cannot be undone.')) {
      return
    }
    const next: StoreSnapshot = { version: 1, chats: [], messages: [] }
    setSnap(next)
    setActiveId(null)
    void persist(next)
  }, [busy, persist])

  const doImport = useCallback(
    async (file: File) => {
      try {
        const incoming = await importFromFile(file)
        const merged = mergeSnapshots(snapRef.current, incoming)
        setSnap(merged)
        const first = visibleChats(merged)[0]
        setActiveId(first ? first.id : null)
        await persist(merged)
        setBanner(
          `Imported ${incoming.chats.length} chat(s) and ${incoming.messages.length} message(s).`,
        )
      } catch (e) {
        setBanner(`Import failed: ${(e as Error).message}`)
      }
    },
    [persist],
  )

  // ----------------------------------------------------------------- render
  if (!cfg || !settings || !booted) {
    return (
      <div className="boot">
        <div className="boot-card">
          <BrandMark size={40} engine="starting" />
          <h1>PenAI</h1>
          <p>Loading the model from the drive. The first start is the slow one.</p>
          <div className="boot-bar" role="progressbar" aria-label="Starting" />
        </div>
      </div>
    )
  }

  const chats = visibleChats(snap)
  const activeChat = chats.find((c) => c.id === activeId) ?? null
  const engineReady = engine === 'connected'

  return (
    <div className={`app ${sidebarOpen ? '' : 'app-collapsed'}`}>
      <Sidebar
        chats={chats}
        activeId={activeId}
        busy={busy}
        engine={engine}
        onNew={() => {
          newChat()
          if (isNarrow()) setSidebarOpen(false)
        }}
        onSelect={(id) => {
          setActiveId(id)
          pinnedRef.current = true
          if (isNarrow()) setSidebarOpen(false)
        }}
        onRename={renameChat}
        canFetch={canFetch}
        onDelete={deleteChat}
        onOpenSettings={() => {
          setShowSettings(true)
          if (isNarrow()) setSidebarOpen(false)
        }}
        open={sidebarOpen}
        onClose={() => setSidebarOpen(false)}
      />

      {sidebarOpen && (
        <button
          type="button"
          className="scrim"
          onClick={() => setSidebarOpen(false)}
          aria-label="Hide chats"
        />
      )}

      <main className="main">
        <StatusBar
          engine={engine}
          detail={engineDetail}
          modelName={cfg.modelName}
          engineVersion={cfg.engineVersion}
          ctxSize={ctxFromEngine ?? settings.ctxSize}
          threads={settings.threads || navigatorThreadHint()}
          portable={Boolean(portableBase && settings.portableStorage)}
          portableError={portableError}
          canFetch={canFetch}
          onMenu={() => setSidebarOpen(true)}
        />

        {banner && (
          <div className="banner" role="status">
            <span>{banner}</span>
            <button
              type="button"
              className="icon-btn icon-btn-sm"
              onClick={() => setBanner(null)}
              aria-label="Dismiss"
            >
              <Icon name="close" size={15} />
            </button>
          </div>
        )}

        {engine === 'disconnected' && (
          <div className="banner banner-error" role="alert">
            <span>
              The engine is not answering{engineDetail ? ` (${engineDetail})` : ''}. It may still
              be loading, or the launcher window may have been closed. Check the launcher window,
              then reload this page.
            </span>
          </div>
        )}

        <div className="thread-area">
          <div className="scroll" ref={scrollRef} onScroll={onScroll}>
            {!activeChat || messages.length === 0 ? (
              <Welcome
                modelName={cfg.modelName}
                canFetch={canFetch}
                canSearch={canSearch}
                onPick={(q) => {
                  setDraft(q)
                }}
              />
            ) : (
              <div className="thread">
                {messages.map((m) => (
                  <MessageBubble
                    key={m.id}
                    message={m}
                    streaming={busy && m.role === 'assistant' && m === messages[messages.length - 1]}
                    onRetry={m.role === 'assistant' && !busy ? () => retry(m.id) : undefined}
                  />
                ))}
              </div>
            )}
          </div>

          {showJump && (
            <button type="button" className="jump" onClick={jumpToLatest}>
              <Icon name="arrowDown" size={15} />
              Latest message
            </button>
          )}
        </div>

        <Composer
          value={draft}
          pastes={pastes}
          busy={busy}
          disabled={!engineReady && !busy}
          disabledReason={
            engine === 'starting'
              ? 'The model is still loading. This can take a while on a USB drive.'
              : 'The AI engine is not reachable.'
          }
          onChange={setDraft}
          onAddPaste={(text) =>
            setPastes((p) => [...p, { id: newId('paste'), text }])
          }
          canFetch={canFetch}
          canSearch={canSearch}
          onFetch={addPage}
          onSearch={runSearch}
          onRemovePaste={(id) => setPastes((p) => p.filter((x) => x.id !== id))}
          onSend={() => void send(composeMessage(pastes, draft))}
          onStop={stop}
        />
      </main>

      {showSettings && (
        <SettingsPanel
          settings={settings}
          ctxFromEngine={ctxFromEngine}
          threadsFromLauncher={settings.threads || navigatorThreadHint()}
          portableAvailable={Boolean(portableBase)}
          onChange={(patch) => setSettings((s) => (s ? { ...s, ...patch } : s))}
          onClose={() => setShowSettings(false)}
          onExport={() => exportToFile(snapRef.current)}
          onImport={(f) => void doImport(f)}
          onClearAll={clearAll}
        />
      )}
    </div>
  )
}

function Welcome({
  modelName,
  canFetch,
  canSearch,
  onPick,
}: {
  modelName: string
  canFetch: boolean
  canSearch: boolean
  onPick(q: string): void
}) {
  // Labelled by the kind of task, not numbered: these are four alternatives, so
  // numbering them would claim an order that is not there.
  const samples = [
    { kind: 'explain', text: 'Explain what a mutex is, with a short example.' },
    { kind: 'write', text: 'Write a Python function that parses a CSV file into a list of dicts.' },
    { kind: 'debug', text: 'Why does my React component re-render on every keystroke?' },
    { kind: 'compare', text: 'Compare TCP and UDP in five bullet points.' },
  ]
  return (
    <div className="welcome">
      <div className="welcome-top">
        <BrandMark size={32} />
        <span className="kicker">PenAI</span>
      </div>

      <h1>
        {canFetch
          ? 'Ask anything. The model answers here.'
          : 'Ask anything. Nothing leaves this computer.'}
      </h1>
      <p className="welcome-sub">
        <b>{modelName.replace(/\.gguf$/i, '')}</b> is loaded from the drive and answers on
        this machine&apos;s own CPU. No account and no telemetry.{' '}
        {!canFetch
          ? 'No network either.'
          : canSearch
            ? 'Web access is on, so you can search from the composer and open a result. The launcher makes those requests; nothing else leaves the machine, and the model never browses on its own.'
            : 'Web access is on, so a page you fetch by address is requested by the launcher. Nothing else leaves the machine.'}
      </p>

      <div className="samples">
        {samples.map((s) => (
          <button key={s.kind} type="button" className="sample" onClick={() => onPick(s.text)}>
            <span className="kicker">{s.kind}</span>
            {s.text}
          </button>
        ))}
      </div>
    </div>
  )
}

/**
 * The attachments come first and the typed question last, which is the order the
 * model reads best: material, then the instruction about it.
 */
/** Just the host, for a chip label. Falls back to the raw string. */
function hostOf(url: string): string {
  try {
    return new URL(url).host.replace(/^www\./, '')
  } catch {
    return url
  }
}

function composeMessage(pastes: Paste[], draft: string): string {
  const parts = [...pastes.map((p) => p.text.trim()), draft.trim()]
  return parts.filter(Boolean).join('\n\n')
}

function titleFrom(text: string): string {
  const t = text.replace(/\s+/g, ' ').trim()
  return t.length > 48 ? `${t.slice(0, 45)}...` : t || 'New chat'
}

/**
 * The launcher decides the real thread count; the browser cannot see it. This is
 * only a display hint, and it is labelled read-only in the UI.
 */
function navigatorThreadHint(): number {
  const n = navigator.hardwareConcurrency
  if (!n || n < 1) return 4
  return n <= 2 ? n : n <= 4 ? n - 1 : Math.max(4, Math.floor(n / 2))
}
