# Overview

What PendriveAI is, how the pieces fit together, and what it can do.

[← All documentation](README.md) · [Project home](../README.md)

---

## What PendriveAI is

PendriveAI is a self-contained AI chat system that lives on a USB pendrive.
There is no desktop application and no installer. The drive carries three things:

1. A CPU build of **llama.cpp** (the `llama-server` HTTP server).
2. One **GGUF model file**.
3. A **React production build** plus a small native **launcher**.

The launcher starts `llama-server` bound to `127.0.0.1`, points it at the model
and at the web build, waits until the engine reports healthy, and opens your
default browser. From that point on it behaves like a website that happens to be
served from your pocket: the page and the AI API are on the same local port.

Nothing leaves the machine. There is no account, no telemetry and no network
dependency once the drive has been prepared.

## How it works

```
Plug in pendrive
      |
      v
Run the launcher  (StartAI / sh StartAI.sh / StartAI.exe / StartAI.bat)
      |
      v
Launcher probes hardware, finds the model, picks a free loopback port
      |
      v
llama-server starts on 127.0.0.1:<PORT>
      |     serves the React UI at /   (via --path)
      |     serves the OpenAI-compatible API at /v1/...
      v
Launcher polls /v1/health until it returns 200
      |
      v
Default browser opens http://127.0.0.1:<PORT>
      |
      v
Offline AI chat
```

The single most important design consequence: **one process serves both the UI
and the API on one port**. Same origin, so there is no CORS problem, no second
static file server, and no Node.js runtime on the target computer.

## Features

**Chat**

- New chat, send, streaming token-by-token responses.
- Stop generation mid-stream.
- Markdown rendering and fenced code blocks with a copy button.
- Auto-scroll, explicit loading states and explicit error states.
- Sidebar chat history with rename and delete.

**Reasoning models**

- Qwen3 *thinking* variants send `choices[0].delta.reasoning_content` alongside
  the normal content deltas. The UI renders that in a separate collapsible block.
  The model shipped in v1 is the non-thinking Instruct variant, so this path is
  mostly dormant by default.

**Settings**

- Temperature, top-p and maximum output tokens, stored in browser `localStorage`.
- Context size and CPU thread count are shown **read-only**. Both are fixed by
  the launcher before the server starts, so the UI reports them rather than
  pretending it can change them live.

**Status**

- An indicator shows "Offline Mode" and "AI Engine: Connected / Starting / Disconnected".

**Launcher**

- Automatic hardware probe, automatic thread selection, automatic port selection.
- A RAM gate that reduces context or refuses to start rather than thrashing.
- Rotating logs, single-instance guard, clean shutdown on Ctrl+C.
- Optional portable chat-history sidecar so chats travel with the drive.

**Deliberately not included:** syntax highlighting, client-side routing, GPU
acceleration, authentication, more than one model. See [Known limitations](LIMITATIONS.md).

## Architecture

```
                    Browser (default browser on the host)
                    http://127.0.0.1:<PORT>
                              |
              +---------------+----------------+
              |                                |
        GET /  and /assets/*            POST /v1/chat/completions
        (React build, served by         GET /v1/health, /props, /slots
         llama-server --path)           (OpenAI-compatible API)
              |                                |
              +---------------+----------------+
                              |
                   llama-server (llama.cpp b10549)
                   bound to 127.0.0.1 only
                              |
                    models/model.gguf (Q4_K_M)
                              ^
                              |
                    StartAI launcher (Rust, std only)
                    spawns and supervises the child,
                    writes web/runtime-config.json,
                    opens the browser
                              |
                    Optional storage sidecar
                    127.0.0.1:47611 -> data/chats/chats.json
```

Components:

| Component | Technology | Notes |
|---|---|---|
| AI runtime | llama.cpp, prebuilt release `b10549` | CPU only, 15 bundled CPU-feature variants |
| Launcher | Rust, edition 2021, **zero external crates** | `opt-level = "s"`, LTO, one codegen unit, stripped |
| Web UI | React 18 + TypeScript, Vite 6 | Runtime deps are only `react` and `react-dom` |
| Model | Qwen3-4B-Instruct-2507, Q4_K_M GGUF | Apache-2.0 |
| Chat storage | IndexedDB, plus an optional portable JSON sidecar | See [Privacy](PRIVACY.md) |

The launcher's own modules are `main.rs`, `paths.rs`, `config.rs`, `sysinfo.rs`,
`net.rs`, `child.rs`, `logging.rs`, `json.rs`, `lock.rs`, `store.rs`,
`browser.rs` and `signals.rs`.

The deeper design rationale, including why llama.cpp's `--path` was chosen over
shipping a separate static server, is in [Architecture](ARCHITECTURE.md).
