/** Shared data shapes. Kept in one place so storage and UI cannot drift apart. */

export type Role = 'system' | 'user' | 'assistant'

export interface Chat {
  id: string
  title: string
  createdAt: number
  updatedAt: number
  /** Tombstone, so a delete on one computer survives a sync from another. */
  deleted?: boolean
}

export interface Message {
  id: string
  chatId: string
  role: Role
  content: string
  createdAt: number
  /** Qwen3-style `reasoning_content`, shown in a collapsible block. */
  reasoning?: string
  /** Set when generation was cut short. */
  stopped?: boolean
  error?: string
  /** Tokens/second reported by llama.cpp for this turn. */
  tokensPerSecond?: number
}

export interface Settings {
  temperature: number
  topP: number
  maxTokens: number
  /** Display only: the real context size is fixed by the launcher at startup. */
  ctxSize: number
  /** Display only: threads are chosen by the launcher before the server starts. */
  threads: number
  systemPrompt: string
  portableStorage: boolean
  theme: 'system' | 'dark' | 'light'
}

export interface RuntimeConfig {
  /** Empty string means "same origin" -- the normal, packaged case. */
  apiBase: string
  /** Loopback URL of the optional chat-history sidecar, or null. */
  storeBase: string | null
  llamaPort: number | null
  modelName: string
  engineVersion: string
  offline: boolean
  defaults: {
    temperature: number
    topP: number
    maxTokens: number
    ctxSize: number
    systemPrompt: string
  }
}

export type EngineState = 'starting' | 'connected' | 'disconnected'

/** The single document persisted to `data/chats/chats.json` on the drive. */
export interface StoreSnapshot {
  version: 1
  chats: Chat[]
  messages: Message[]
  savedAt?: number
}

export function newId(prefix: string): string {
  // crypto.randomUUID needs a secure context; http://127.0.0.1 counts as one in
  // Chrome and Firefox, but fall back anyway so nothing depends on it.
  const uuid =
    typeof crypto !== 'undefined' && 'randomUUID' in crypto
      ? crypto.randomUUID()
      : Math.random().toString(36).slice(2) + Date.now().toString(36)
  return `${prefix}_${uuid}`
}
