# PendriveAI Architecture

This document explains how PendriveAI is put together and, more usefully, *why*
each decision was made. Where a claim was measured, it says so. Where something
was not verified, it says that too.

Every technical statement here refers to llama.cpp release `b10549` (published
2026-08-21) from `ggml-org/llama.cpp`, and to the model
`Qwen3-4B-Instruct-2507-Q4_K_M.gguf`.

---

## Table of contents

1. [System architecture](#1-system-architecture)
2. [Process flow](#2-process-flow)
3. [Portable path strategy](#3-portable-path-strategy)
4. [Linux architecture](#4-linux-architecture)
5. [Windows architecture](#5-windows-architecture)
6. [Web serving strategy](#6-web-serving-strategy)
7. [LLM API integration](#7-llm-api-integration)
8. [Storage strategy](#8-storage-strategy)
9. [Security model](#9-security-model)
10. [Packaging strategy](#10-packaging-strategy)
    - [Preparing the drive: filesystem choice and formatting](#preparing-the-drive-filesystem-choice-and-formatting)
11. [The 8 GB storage budget](#11-the-8-gb-storage-budget)

---

## 1. System architecture

PendriveAI has exactly two processes at runtime, plus one thread pool inside the
first of them. That is the whole system.

```
+--------------------------------------------------------------------------+
|  Host computer (nothing installed, no admin rights, no network)          |
|                                                                          |
|   +------------------------+                                             |
|   |  Default browser       |                                             |
|   |  http://127.0.0.1:PORT |                                             |
|   +-----------+------------+                                             |
|               |                                                          |
|      HTTP on loopback (one origin, one port)                              |
|               |                                                          |
|      +--------+---------+--------------------------+                     |
|      |                  |                          |                     |
|   GET /             POST /v1/chat/completions   GET /api/chats            |
|   GET /assets/*     GET /v1/health, /props      PUT /api/chats            |
|      |              GET /slots                     |                     |
|      v                  v                          v                     |
|  +-----------------------------------+   +------------------------+       |
|  |  llama-server  (child process)    |   |  Storage sidecar       |       |
|  |  llama.cpp b10549, CPU only       |   |  thread inside StartAI |       |
|  |  bound to 127.0.0.1 ONLY          |   |  127.0.0.1:47611       |       |
|  |                                   |   +-----------+------------+       |
|  |  --path  -> serves web/ at /      |               |                    |
|  |  --model -> models/model.gguf     |               v                    |
|  +---------------+-------------------+   data/chats/chats.json (on drive) |
|                  ^                                                        |
|                  | spawn + supervise (argv array, no shell)               |
|                  |                                                        |
|  +---------------+-------------------------------------------+            |
|  |  StartAI  (Rust launcher, std only, single binary)        |            |
|  |  hardware probe, RAM gate, port pick, health wait,        |            |
|  |  log rotation, single-instance guard, browser open        |            |
|  +----------------------------------------------------------+            |
|                  ^                                                        |
+------------------|--------------------------------------------------------+
                   |
        +----------+-----------------------------------------+
        |  USB pendrive (8 GB, FAT32 or exFAT)               |
        |  runtime/  models/  web/  config/  data/           |
        +----------------------------------------------------+
```

### Component choices

| Layer | Choice | Why |
|---|---|---|
| Inference | llama.cpp prebuilt `b10549`, CPU | Official prebuilt binaries, 15 CPU-feature variants selected at runtime, so one drive runs on many machines |
| Launcher | Rust edition 2021, **zero external crates** | See below |
| UI | React 18 + TypeScript, Vite 6 | Runtime deps are only `react` and `react-dom` |
| Static serving | `llama-server --path` | No second server and no Node.js on the host. See section 6 |
| Chat storage | IndexedDB + optional JSON sidecar | See section 8 |

### Why Rust with zero dependencies

The launcher is written in Rust, edition 2021, using only `std` plus a handful of
`libc` and `kernel32` FFI symbols that are already linked into every Rust binary
on the respective platform. The HTTP client, the HTTP server, the JSON parser,
the memory query and the signal handling are all hand-written.

Three reasons:

1. It builds on an air-gapped machine that has nothing but a Rust toolchain.
   `cargo build --release` needs no registry access at all.
2. It produces one small native binary that needs no interpreter and no runtime
   on the target computer.
3. It keeps a crate supply chain out of an offline, security-sensitive tool.

Alternatives that were considered and rejected:

- **Go.** Not installed on the build machine, and it would need a toolchain
  download. Otherwise a reasonable fit.
- **C or C++.** Considerably more manual work to get safe process handling and
  safe thread handling right, for no size benefit worth the risk.

The release profile is tuned for size rather than speed, because the launcher
spends nearly all of its life waiting on a child process:

```toml
[profile.release]
opt-level = "s"
lto = true
codegen-units = 1
strip = true
panic = "unwind"
```

`panic = "unwind"` is deliberate rather than an oversight: a panicking sidecar
connection thread must not take down the whole process and orphan the engine.

### Launcher modules

| Module | Responsibility |
|---|---|
| `main.rs` | Orchestration and the startup sequence |
| `paths.rs` | Root discovery and portable layout construction |
| `config.rs` | Config parsing, defaults, clamping, warnings |
| `sysinfo.rs` | OS, arch, logical cores, total and available RAM |
| `net.rs` | Loopback port selection, HTTP client, health polling |
| `child.rs` | argv construction, spawn, supervise, terminate |
| `logging.rs` | Rotating logs, unwritable-destination degradation |
| `json.rs` | Minimal JSON parse and serialise |
| `lock.rs` | Single-instance guard and `instance.json` |
| `store.rs` | The portable chat-history sidecar |
| `browser.rs` | Default-browser launch with a URL allowlist |
| `signals.rs` | Ctrl+C handling and graceful shutdown |

---

## 2. Process flow

The launcher runs a fixed sixteen-step sequence. Each step either succeeds, or
degrades with a stated warning, or refuses with an explanation. It never guesses.

```
 1  resolve own directory                    std::env::current_exe()
 2  find project root                        marker -> structure -> env var
 3  read config                              config/config.json, defaults on absence
 4  create data dirs                         data/logs, data/chats, data/run
 5  open rotating log                        degrade to console if read-only
 6  enforce single instance                  bind 127.0.0.1:47610
 7  probe hardware                           OS, arch, cores, total + available RAM
 8  locate and sanity-check the model        name -> largest .gguf -> config
 9  query engine version                     llama-server --version
10  assess RAM, reduce context if tight      ok / tight / unlikely / unknown
11  pick a free loopback port                8080 -> 8081..8180 -> ephemeral
12  spawn llama-server                       argv array, no shell
13  stream child stdout/stderr to logs       dedicated threads
14  poll /v1/health until ready              fallback probe on /health
15  start sidecar, write runtime-config.json optional, non-fatal
16  open browser, supervise, clean shutdown  SIGTERM then kill
```

### Step 7 and 10: the RAM gate

The launcher refuses to make a capability claim it cannot support. It computes an
estimate from facts about the model, not from a guess:

- Weights: 2,497,281,120 bytes on disk.
- KV cache: the model has 36 layers, 8 KV heads (GQA) and head_dim 128, so the
  f16 KV cache is `2 * 36 * 8 * 128 * 2 = 147,456` bytes per token, that is
  144 KiB per token. At context 4096 that is roughly 0.6 GiB.
- Buffers: about 400 MiB.

Four outcomes:

| Assessment | Action |
|---|---|
| Fits with 512 MiB spare | Start normally |
| Tight | Warn, then halve the context repeatedly until it fits, floor 512 |
| Cannot fit | Refuse with an explanation, require `--force` to override |
| RAM unreadable | Warn, continue, make no capability claim |

The footprint estimate growing with context size is unit-tested, as are all four
assessment outcomes.

### Step 12: thread selection

```
cores <= 2   ->  all cores
cores <= 4   ->  cores - 1
otherwise    ->  max(cores / 2, 4)
always clamped to 1..16
```

llama.cpp CPU inference is memory-bandwidth-bound. Saturating every logical core
often makes generation *slower* while making the machine unusable for anything
else, so the default leaves headroom. `--threads` overrides it.

### Step 11: port selection

Preference order is 8080, then a scan of 8081 to 8180, then an OS-assigned
ephemeral port. If `llama-server` still fails to bind, the launcher retries on a
different port for up to 3 attempts. Port busy detection and the fallback path
are both unit-tested.

### Step 6: single instance

The mutex is a **bound loopback socket on port 47610**, not a lock file. A lock
file on a pendrive is actively dangerous: pull the drive out, or crash, and a
stale lock survives to block every future run. The OS releases a socket
unconditionally when the process dies.

The launcher writes `data/run/instance.json` containing the live URL, so a second
launch is not an error. It reads the file and reopens the browser at the session
that is already running. A corrupt `instance.json` is handled and tested.

### Step 16: shutdown

On Linux the child is given `PR_SET_PDEATHSIG` at spawn time, so `llama-server`
can never outlive the launcher, even if the launcher is killed. Shutdown sends
SIGTERM, waits a grace period, then escalates to a kill.

On Windows shutdown uses `TerminateProcess`. **Windows shutdown is therefore not
graceful.** This is a known limitation, not a bug to be discovered later.

---

## 3. Portable path strategy

A pendrive has no stable path. It is `/media/alice/PENDRIVEAI` on one machine,
`/run/media/bob/My Drive` on another, and `D:\PendriveAI` on Windows. The entire
launcher is built around never knowing its own location until runtime.

Rules the code obeys:

- No drive letters.
- No home directories.
- No absolute project paths anywhere in the source.

Root discovery, in order:

1. Start from `std::env::current_exe()`.
2. Walk up at most 4 levels looking for a `.pendriveai-root` marker file.
3. Fall back to structural detection, that is, a directory that contains the
   expected `runtime/`, `models/` and `web/` shape.
4. Allow an explicit override through the `PENDRIVEAI_ROOT` environment variable.

Step 4 is what makes the FAT32 bootstrap possible: `StartAI.sh` copies the
executable parts to a local temporary directory and then points
`PENDRIVEAI_ROOT` back at the pendrive, so the binary runs from local disk while
the model and web assets are still read from the drive.

Layout construction is written as a **pure function** from a root path to a set
of derived paths. That makes it directly unit-testable without touching a real
filesystem, and it is tested against four simulated roots including a
Windows-style one:

```
/media/someone/PENDRIVEAI
/run/media/other-user/My Drive     (note the space)
/tmp/x/y/z
D:\PendriveAI
```

Root discovery is separately tested through both the marker-file path and the
structural path.

---

## 4. Linux architecture

The tested platform.

```
runtime/linux/
├── llama-server            the only binary we launch
└── lib*.so                 trimmed shared library set, real files not symlinks
```

Verified properties of the prebuilt Linux runtime:

- Downloaded asset: `llama-b10549-bin-ubuntu-x64.tar.gz`, 16.7 MB.
- Extracted: 41 MB. After trimming to only what `llama-server` needs, roughly
  40 to 45 MB.
- Binaries carry `RUNPATH=$ORIGIN`, so **no `LD_LIBRARY_PATH` is required**. The
  launcher does not set one and does not need to.
- `objdump` shows a requirement of **glibc 2.34 or newer**. That means Ubuntu
  22.04+, Debian 12+, Fedora 35+. Older distributions will not run these
  binaries at all.
- `llama-server --version` prints
  `version: 0.1.2-dev (build 10549, commit b2e5e9b28)`. The launcher queries this
  and logs it, so a bug report always carries the exact engine build.

### The FAT32 execution problem

Measured on the real test drive, which was FAT32 mounted with `showexec`:

| Test | Result |
|---|---|
| `./binary` on a compiled ELF | "Permission denied", and `chmod +x` had no effect |
| Symlink creation | "Operation not permitted" |
| Hard link creation | "Operation not permitted" |
| Case sensitivity | Case-insensitive |
| Write speed | 3.4 MB/s |

Under `showexec`, only files named `.exe`, `.com` or `.bat` receive an execute
bit. A Linux ELF named `StartAI` can never be executed from such a mount, and no
amount of `chmod` changes that.

Two answers ship:

1. **`StartAI.sh`**, run as `sh StartAI.sh`. It copies the launcher and the
   llama.cpp runtime into a local temporary directory, marks them executable, and
   runs the launcher with `PENDRIVEAI_ROOT` pointing back at the pendrive. Only
   the small executable parts are copied; the 2.50 GB model is still read from
   the drive. **This bootstrap has not been tested end to end.**
2. **Reformat to exFAT.** This is the recommended fix. exFAT allows direct
   execution on Linux and removes the 4 GiB per-file limit, while staying
   readable on Windows and macOS.

```bash
lsblk                                     # CONFIRM the device first
sudo apt install exfatprogs
udisksctl unmount -b /dev/sdX1
sudo mkfs.exfat -n PENDRIVEAI /dev/sdX1   # ERASES THE DRIVE
```

The full procedure, including partition-table repair, GUI alternatives, and the
Windows and macOS equivalents, is in
[section 10, Preparing the drive](#preparing-the-drive-filesystem-choice-and-formatting).

---

## 5. Windows architecture

```
runtime/windows/
├── llama-server.exe
└── *.dll                   trimmed DLL set
```

Verified properties of the prebuilt Windows runtime:

- Downloaded asset: `llama-b10549-bin-win-cpu-x64.zip`, 18.6 MB.
- Extracted: 46 MB. Trimmed, roughly 40 to 45 MB.

Windows is architecturally simpler than Linux in exactly one respect that
matters: **`.exe` runs normally on FAT32**, so the `showexec` problem described
in section 4 does not exist there, and no staging bootstrap is needed.

It is harder in two respects:

- **`StartAI.exe` was not built.** The build machine has no mingw-w64 and no MSVC
  toolchain, and installing one was declined. It must be built on Windows with
  `cargo build --release` using the MSVC toolchain, or cross-compiled from Linux
  after `sudo apt install mingw-w64` and `rustup target add
  x86_64-pc-windows-gnu`, then `cargo build --release --target
  x86_64-pc-windows-gnu`.
- **A zero-compile fallback is shipped instead.** `StartAI.bat` uses only
  `cmd.exe` and PowerShell, both built into Windows, so the drive is usable on a
  Windows machine with no compiler present. It is one file: a batch header that
  reads the file back, cuts everything after a `#@PSBEGIN@` marker and hands
  that text to PowerShell as a *command*, so no temporary `.ps1` is written and
  the script-file execution policy does not apply.

  It reproduces config parsing, model resolution, the thread rule, the port
  scan, `web/runtime-config.json`, the llama-server argv and the health wait.
  It does not reproduce the RAM gate (it warns but never reduces the context),
  the single-instance guard, log rotation or the chat-history sidecar.

**The entire Windows path is untested on real Windows hardware.** `StartAI.bat`
is untested. Treat both as design intent that has been written but not
exercised.

Windows-specific behaviour inside the launcher: memory is queried through
`kernel32` FFI, and shutdown uses `TerminateProcess`, which means the engine is
killed rather than asked to stop.

---

## 6. Web serving strategy

This is the decision that shapes everything else, so it is worth spelling out.

The UI is a static Vite production build: `web/index.html` plus `web/assets/`.
Something has to serve it over HTTP. Three options were considered.

### Option A, chosen: `llama-server --path web/`

llama.cpp's own static file handler serves the build.

```
--path <dir>     serve static files from <dir>
```

Consequences, all of them good:

- **No second server process.** One `llama-server` handles the UI and the API.
- **No Node.js, no Python, no Docker on the target computer.** The whole point.
- **One port, one origin, therefore no CORS problem at all.** The page fetches
  `/v1/chat/completions` on its own origin.
- **Nothing extra to trim, ship or maintain.** The handler is already in the
  binary we were going to ship anyway.

Verified: `--path` serves a custom `index.html` and a custom asset at `/`, and it
**replaces** llama.cpp's bundled web UI rather than sitting alongside it.

### Option B, rejected: bundle a small static server

Shipping something like a single-binary static file server would have meant
another binary per platform, another licence, another 5 to 15 MB, a second port,
and a genuine CORS configuration problem between the UI origin and the API
origin. All of that to duplicate a feature `llama-server` already has.

### Option C, rejected: write a static server into the launcher

Technically easy, since the launcher already contains a std-only HTTP server for
the storage sidecar. Rejected because it would still create a second origin and
therefore a CORS problem, and because hand-written MIME handling and path
sanitisation for arbitrary asset trees is exactly the kind of code that grows
security bugs. The sidecar avoids that risk by exposing **only fixed routes**,
which a static file server cannot do by definition.

### The `--no-webui` finding

This is non-obvious and it cost real debugging time, so it is documented
prominently:

> Passing `--no-webui` **disables the entire static file handler**. With
> `--no-webui`, both `/` and `/probe.txt` return HTTP 404.

The intuition was that `--path` would override the bundled UI while `--no-webui`
would suppress it, so the two together would be a belt-and-braces way of
guaranteeing our build is what gets served. That intuition is wrong: they are the
same handler. `--path` alone already replaces the bundled UI.

**`--no-webui` must never be passed.** There is a unit test that asserts it never
appears in the constructed argv.

### No SPA deep-route fallback

Also verified: an unknown path such as `/some/deep/route` returns HTTP 404. The
static handler does not fall back to `index.html`.

That is a hard constraint, not a preference, and the UI is designed around it:
**the web app is deliberately single-route with no client-side router.** Chat
selection, settings and history are all state within one page, never URLs. Adding
React Router later would produce 404s on refresh and on bookmarking, so it is not
a small future change.

### Vite configuration consequences

- `base: './'` so assets resolve relatively from any mount path. The release
  folder can sit at any path on any drive, and the mount point is unknown at
  build time.
- **No code splitting**, one JS file and one CSS file. `llama-server` serves
  plain files with no HTTP/2 push, and the drive is slow, so one request beats a
  dozen round trips. It also means there are no dynamic-import paths to resolve.
- No source maps, since they would inflate the drive for no offline benefit.
- Markdown and code-block rendering are hand-written into React elements. This
  drops a heavy markdown and syntax-highlighting dependency, and because nothing
  is ever assigned to `innerHTML`, there is no XSS surface. The cost, accepted
  deliberately, is that there is **no syntax highlighting**.
- `llama-server` static serving does not gzip, so first paint is bounded by drive
  read speed.

For development, `npm run dev` runs Vite on port 5173 and proxies `/v1`, `/props`
and `/slots` to `http://127.0.0.1:8080`, so the dev UI behaves like the packaged
one.

---

## 7. LLM API integration

The UI talks to llama.cpp's OpenAI-compatible HTTP API on the same origin.

### Flags the launcher actually passes

```
--model <path>            models/model.gguf
--host 127.0.0.1          never 0.0.0.0, not configurable
--port <n>                chosen by the launcher
--ctx-size <n>            possibly reduced by the RAM gate
--threads <n>             chosen by the thread heuristic
--parallel <n>
--path <dir>              serve the React build (see section 6)
--cors-origins localhost  instead of the default *
--flash-attn auto
```

And, critically, **never** `--no-webui`.

### Endpoints used

| Endpoint | Behaviour |
|---|---|
| `GET /v1/health` | 200 `{"status":"ok"}` when ready, 503 while still loading. `/health` is probed as a fallback |
| `GET /props` | Engine details including context size |
| `GET /slots` | Slot state, for example `is_processing` |
| `POST /v1/chat/completions` | Chat, streaming or not |
| `GET /v1/models` | Model listing |

The 503-while-loading behaviour is what makes step 14 of the startup sequence
possible: the launcher polls until it sees 200 and only then opens the browser,
so the user never lands on a page that cannot answer. On the development machine
that took 6 seconds. Health polling has both an abort path and a timeout path,
each with its own message, and both are unit-tested.

### Streaming

`POST /v1/chat/completions` with `"stream": true` returns Server-Sent Events.
Verified frame shape:

```
data: {"choices":[{"delta":{"content":"Hel"}}], ...}
data: {"choices":[{"delta":{"content":"lo"}}], ...}
data: [DONE]
```

- Token deltas arrive as `choices[0].delta.content`.
- Qwen3 **thinking** models additionally send
  `choices[0].delta.reasoning_content`. The UI renders that in a separate
  collapsible block, so a reasoning trace never contaminates the answer text.
  The model shipped in v1 is the non-thinking Instruct variant, so this path is
  usually dormant.
- `stream_options: {include_usage: true}` produces a final chunk with an empty
  `choices` array plus `usage` and `timings`. `timings.predicted_per_second` is
  what the UI displays as tokens per second, and what gets stored on a message as
  `tokensPerSecond`.

### Stopping generation

There is **no stop endpoint**. Generation is stopped by aborting the HTTP
request, using the browser's `AbortController`.

Verified after a client abort: `/v1/health` still returns 200, and `/slots` shows
`is_processing: false`, so the slot is freed. In other words the obvious
implementation is also the correct one, and it leaves no wedged state behind.

### Measured performance

Development machine only: Intel-class x86_64, 12 logical cores, 15 GiB RAM, model
on a local SSD, context 4096, 6 threads.

| Metric | Measured |
|---|---|
| Model load time | 6 seconds |
| Generation | 13.2 tokens/second |
| Prompt processing | 50.3 tokens/second |

**These are one-machine measurements and not a guarantee.** Loading from the
pendrive itself will be slower than 6 seconds, because the measured write speed
on the test drive was 3.4 MB/s and reads, while faster, are still far below SSD.

---

## 8. Storage strategy

Two stores, one of which is optional, plus an honest statement of what each one
can and cannot do.

### Primary store: IndexedDB

Chats live in IndexedDB in the browser.

**The limitation must be stated plainly, not buried:** IndexedDB is tied to the
origin *and* to the browser profile on the host computer. So by default chats
stay on that computer and **do not travel with the pendrive**. Plug the drive
into a second machine and the sidebar is empty. That is the correct behaviour of
IndexedDB, not a defect in the UI, and it is the reason the second store exists.

Settings, separately, live in `localStorage`.

### Portable store: the chat-history sidecar

A small HTTP server compiled into the launcher binary. std-only Rust: no
database, no Node.js, no Python, no Docker. It listens on `127.0.0.1:47611` and
persists one JSON document to `data/chats/chats.json` on the pendrive, so history
travels with the drive.

| Endpoint | Purpose |
|---|---|
| `GET /api/health` | Liveness |
| `GET /api/chats` | Read the whole document |
| `PUT /api/chats` | Replace the whole document |

Three routes and one file. That is the entire surface, and keeping it that small
is what makes the security properties below achievable.

If the sidecar cannot start, because the drive is read-only, the port is busy, or
it is disabled in config, the UI silently falls back to IndexedDB only. **It is
an enhancement, never a hard dependency**, and the fallback is on the normal code
path rather than an error path.

### Data model

**Chat:** `id`, `title`, `createdAt`, `updatedAt`, plus a `deleted` tombstone.

The tombstone exists for a specific reason: without it, deleting a chat on
computer A and then syncing from computer B would resurrect it, because B still
has the record. A tombstone makes deletion survive a merge.

**Message:** `id`, `chatId`, `role`, `content`, `createdAt`, plus optional
`reasoning`, `stopped`, `error` and `tokensPerSecond`.

`stopped` and `error` are stored on the message rather than inferred, so a
half-generated answer still looks half-generated after a reload instead of
looking like the model's considered final word.

### Merge strategy

Union by `id`, last-write-wins by `updatedAt`.

This is chosen for being predictable and dependency-free, not for being
sophisticated. It has a known consequence: editing the same chat on two computers
without syncing in between loses the older edit. A CRDT would fix that and would
also add far more machinery than a pendrive chat log justifies.

### Sidecar security

Each item exists because the sidecar is an HTTP server running with the user's
privileges.

| Control | Behaviour |
|---|---|
| Binding | `127.0.0.1` only |
| DNS-rebinding guard | A loopback `Host` header is required, else HTTP 421 |
| Origin check | If an `Origin` header is present it must exactly match the llama-server origin, else HTTP 403 |
| Path handling | Only fixed routes exist, so **no request-supplied path ever reaches the filesystem** |
| Body size | Capped at 32 MB |
| Write durability | Atomic: temp file plus rename |
| Input validation | Invalid JSON is rejected with HTTP 400, so the stored file cannot be corrupted |
| Unknown routes | HTTP 404 |

All of these are unit-tested, including a real round-trip to disk, a foreign
origin being rejected, a non-loopback `Host` being rejected, an oversized body
being rejected, CORS preflight, and the assertion that an atomic write leaves no
temp file behind.

**No chat data is ever sent to any external server.**

---

## 9. Security model

The threat model is narrow and worth being explicit about: PendriveAI runs
untrusted *model output* inside a browser page, on a machine the user controls,
with no network exposure. It does not attempt to defend against a hostile local
user or a compromised host.

### Network exposure

- `llama-server` binds `127.0.0.1`, never `0.0.0.0`. **This is not
  configurable.** The model is not reachable from the local network.
- `--cors-origins localhost` instead of llama.cpp's default `*`.
- The sidecar binds `127.0.0.1` with the `Host` and `Origin` checks in section 8.
- A Content-Security-Policy meta tag restricts `connect-src` to `'self'` plus
  loopback, so the page cannot reach a remote host even if some code tried.
- No cloud APIs. No OpenAI API, no Anthropic API. No telemetry. No update check.
  No internet access needed after the drive is prepared.

### Command injection

Arguments reach `llama-server` as an **argv array** through
`std::process::Command`. No shell is invoked, and no command string is ever
concatenated. A path containing a space, a quote, `&`, `;` or `$(...)` therefore
cannot become code, it just becomes one argument.

This matters more than usual here, because the project root comes from a mount
point chosen by the operating system and by whoever named the drive. There is a
unit test asserting that spaces and shell metacharacters survive as single
arguments.

### Browser-side injection

Markdown and code-block rendering are hand-written into React elements. Nothing
is ever assigned to `innerHTML`. Model output is therefore rendered as text
structure, never as markup, so a model that emits `<script>` produces visible
characters and not an execution.

### URL handling

The launcher refuses to open any URL that is not `http://127.0.0.1:<port>` or
`http://localhost:<port>`. Loopback-only addressing is unit-tested.

### Process containment

- Linux: the child receives `PR_SET_PDEATHSIG`, so `llama-server` cannot outlive
  the launcher even if the launcher is killed.
- Shutdown sends SIGTERM, then escalates to a kill after a grace period.
- Windows: `TerminateProcess`, so **Windows shutdown is not graceful**.

### What is deliberately not protected

Anything running as your user on the same computer can reach a loopback port.
PendriveAI adds **no authentication**, because putting a shared secret into a page
served from the same origin buys very little: whatever can read the port can
usually read the page too.

**Do not run PendriveAI on a shared or multi-user machine you do not trust.**
That is the honest boundary of this design.

---

## 10. Packaging strategy

Packaging turns a repository into a drive that works, and most of its real work
is compensating for filesystem limits.

### Preparing the drive: filesystem choice and formatting

Packaging cannot compensate for the wrong filesystem, so the filesystem is part
of the architecture rather than a deployment detail. This subsection is the full
version of the procedure; the shorter operator-facing version is
[Format the pendrive first](PENDRIVE.md#format-the-pendrive-first-do-this-before-anything-else).

#### Why the filesystem is an architectural decision

Three properties of the target filesystem propagate directly into the design:

| Property | Consequence for PendriveAI |
|---|---|
| Can a native binary be executed from the mount? | Decides whether `./StartAI` works, or whether the `StartAI.sh` staging bootstrap is mandatory on Linux |
| Maximum single-file size | Decides which model quantisations can be carried at all |
| Symlink support | Decides whether the llama.cpp library symlinks must be dereferenced at packaging time |

The first two vary by filesystem. The third does not: **no FAT-family filesystem
supports symlinks**, so the dereferencing step described later in this section is
unconditional.

#### Measured evidence

The test drive arrived as FAT32 mounted with the `showexec` option. On it:

| Test | Result |
|---|---|
| Execute a compiled Linux ELF (`./binary`) | "Permission denied". `chmod +x` had no effect |
| Create a symlink | "Operation not permitted" |
| Create a hard link | "Operation not permitted" |
| Case sensitivity | Case-insensitive |
| Write speed | 3.4 MB/s |

Under `showexec`, only files named `.exe`, `.com` or `.bat` receive an execute
bit. A Linux ELF named `StartAI` can therefore never be executed from such a
mount, no matter what permissions are set on it. FAT32 additionally caps any
single file at 4 GiB.

#### Filesystem comparison

**exFAT is the recommended format.** It allows direct execution on Linux, it has
no practical file-size cap, and it is readable on Windows, macOS and Linux.

| Filesystem | Linux execution | Max file size | Cross-platform | Verdict |
|---|---|---|---|---|
| **exFAT** | Yes | No practical cap | Windows, macOS, Linux | **Recommended** |
| FAT32 | No, under `showexec` | 4 GiB | Windows, macOS, Linux | Works with the `StartAI.sh` fallback |
| NTFS | Possible | Very large | Poor in practice | Rejected: Linux write support exists, but permissions and safe-eject behaviour are worse |
| ext4 | Yes | Very large | Linux only | Rejected: unreadable on stock Windows |

NTFS and ext4 each fail the single requirement that matters most for a pendrive,
which is that the same drive must work on an arbitrary machine the user did not
prepare.

#### Warning

> **Formatting ERASES EVERYTHING on the drive.** Back up first. The correct
> device must be identified before any format command is typed. Getting it wrong
> destroys the wrong disk, and there is no undo.

#### Linux, command line

**Step 1. Identify the device.**

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,MODEL,TRAN,RM
```

Look for `TRAN` of `usb`, `RM` of `1` (removable), and a `SIZE` matching the
pendrive. **Never pick the disk that holds `/` or `/boot`**; check `MOUNTPOINT`
first. The whole device looks like `/dev/sdb`, and the partition on it looks like
`/dev/sdb1`. Every command below uses `/dev/sdX1` as a placeholder rather than a
real device name, deliberately, so that nothing here can be copied and pasted
into a destructive mistake.

**Step 2. Install the exFAT tools.**

```bash
sudo apt install exfatprogs        # Debian, Ubuntu
sudo dnf install exfatprogs        # Fedora
sudo pacman -S exfatprogs          # Arch
```

**Step 3. Unmount the partition.**

```bash
udisksctl unmount -b /dev/sdX1
# or
sudo umount /dev/sdX1
```

**Step 4. Format as exFAT with the label `PENDRIVEAI`.**

```bash
sudo mkfs.exfat -n PENDRIVEAI /dev/sdX1
```

**Step 5. Mount it again.**

Unplug and replug, or mount explicitly:

```bash
udisksctl mount -b /dev/sdX1
```

It appears at something like `/media/<user>/PENDRIVEAI` or
`/run/media/<user>/PENDRIVEAI`. **The launcher does not care what that path is**,
which is the entire point of the root-discovery design in section 3. Spaces in
the path are fine and are covered by a unit test.

**Step 6, only if needed. Create a partition table.**

Only when the drive has no partition table at all, or a broken one:

```bash
sudo parted /dev/sdX -- mklabel msdos mkpart primary 1MiB 100%
```

Note that this operates on the whole device (`/dev/sdX`), not on a partition.
Then format the newly created `/dev/sdX1` with Step 4.

**Step 7. Verify.**

```bash
lsblk -f
```

The partition should report `exfat` with the label `PENDRIVEAI`.

#### Linux, GUI alternative

GNOME Disks (`gnome-disks`): pick the USB device in the left-hand list, confirming
size and model, use the menu to **Format Partition**, choose **Other** and then
**exFAT**, and set the name to `PENDRIVEAI`.

GParted also works, but it may need the `exfatprogs` package installed before
exFAT appears as an option.

#### Windows, File Explorer

1. Open **This PC**, right-click the USB drive, choose **Format**.
2. **File system:** exFAT. **Allocation unit size:** default. **Volume label:**
   `PENDRIVEAI`. Leave **Quick Format** checked.
3. Click **Start** and confirm. This erases the drive, so confirm the drive
   letter in the dialog belongs to the pendrive.

#### Windows, PowerShell alternative

Run as Administrator. Identify the disk first:

```powershell
Get-Disk
Get-Partition -DiskNumber <n>
```

Verify the disk number and the size before continuing. Then format, replacing `E`
with the real drive letter:

```powershell
Format-Volume -DriveLetter E -FileSystem exFAT -NewFileSystemLabel PENDRIVEAI
```

`diskpart` can also do this, but `Format-Volume` is preferred here because it
acts on a volume already identified by letter rather than on a selected disk,
which removes one whole class of mistake.

#### macOS

Disk Utility: select the **USB device**, not just the volume underneath it, click
**Erase**, set **Format** to **ExFAT** and **Scheme** to **Master Boot Record**,
and name it `PENDRIVEAI`.

macOS appears here only as a machine that can prepare a drive. **PendriveAI v1
ships no macOS runtime**, and the memory probe returns unknown on macOS.

#### Staying on FAT32

FAT32 remains supported, with two consequences that follow from the measurements
above.

**Linux must use the staging bootstrap.**

```bash
sh StartAI.sh        # instead of ./StartAI
```

`StartAI.sh` copies the launcher and the llama.cpp runtime into a local temporary
directory where execution is permitted, marks them executable, and sets
`PENDRIVEAI_ROOT` back to the pendrive so the model, the web assets and the config
are still read from the drive. Roughly 45 MB is copied to local disk on first
run, and the 2.50 GB model is never copied. **This bootstrap has not been tested
end to end.**

**Windows is unaffected on FAT32**, because `.exe` executes normally there.

**The 4 GiB cap constrains the model.** Q4_K_M at 2.50 GB fits FAT32
comfortably, which is one of the reasons it was chosen. Q8_0 at 4.28 GB cannot be
stored on FAT32 at all and requires exFAT.


### Scripts

| Script | Job |
|---|---|
| `scripts/fetch-runtime.sh` | Download and trim the llama.cpp Linux release |
| `scripts/fetch-runtime.ps1` | Download and trim the llama.cpp Windows release |
| `scripts/build-linux.sh` | Build `StartAI` and stage the Linux runtime plus web build |
| `scripts/build-windows.ps1` | Assemble the Windows release folder |
| `scripts/package.sh` | Produce the final `release/` tree |

Build caches are redirected off the drive with `CARGO_TARGET_DIR`.

### Trimming

The extracted llama.cpp builds are 41 MB (Linux) and 46 MB (Windows), and most of
that is tools we never launch. Only `llama-server` and the libraries it actually
loads are kept, which brings each platform folder to roughly 40 to 45 MB.

### Symlink flattening, the non-obvious step

The llama.cpp archives contain symlinks such as:

```
libggml-base.so -> libggml-base.so.0.20.2
```

**Neither FAT32 nor exFAT can store a symlink.** This was measured on the real
drive: symlink creation returns "Operation not permitted", and so does hard-link
creation.

So the packaging script replaces each symlink with a **real file named after the
SONAME the binary actually loads**. Copy the tree naively and the runtime will
fail to start from the drive with a confusing missing-library error, because the
loader is looking for a name that is now absent.

### What never goes on the drive, and what never goes in git

`.gitignore` excludes `*.gguf`, `runtime/`, `release/`, `web/dist/`,
`web/node_modules/`, `launcher/target/`, `data/` and `config/config.json`. The
multi-gigabyte model is **never committed**.

`npm install` must **never be run on the drive**. It needs about 30,000 small
files and it needs symlinks, which the drive cannot store, at 3.4 MB/s. All build
caches belong on local disk.

### Case insensitivity

The test drive is case-insensitive. `StartAI` and `startai` are the same name
there, so no two shipped files may differ only in case.

### Release layout

```
PendriveAI/
├── StartAI                  Linux launcher (native ELF)
├── StartAI.sh               Linux bootstrap for FAT32 / noexec mounts (sh StartAI.sh)
├── StartAI.exe              Windows launcher (build on Windows; not built here)
├── StartAI.bat              Windows zero-compile fallback launcher
├── .pendriveai-root         root marker used for path discovery
├── runtime/
│   ├── linux/               llama-server + trimmed .so set
│   └── windows/             llama-server.exe + trimmed .dll set
├── models/
│   ├── model.gguf           the GGUF (not in git; downloaded separately)
│   └── README.md
├── web/                     Vite production build (index.html + assets/)
├── config/
│   └── config.json
├── data/
│   ├── chats/               portable chat history (chats.json)
│   └── logs/                rotating logs
└── README.md
```

`.pendriveai-root` is a zero-content marker whose only job is to make root
discovery deterministic (section 3). Deleting it forces the slower structural
detection path.

---

## 11. The 8 GB storage budget

| Item | Size |
|---|---|
| Model (`Qwen3-4B-Instruct-2507-Q4_K_M.gguf`) | 2.50 GB |
| Linux runtime (trimmed) | about 40 MB |
| Windows runtime (trimmed) | about 45 MB |
| Web production build | under 1 MB |
| Launcher binaries | about 1 MB |
| Config, docs and logs | well under 5 MB |
| **Total** | **about 2.6 GB** |

An 8 GB pendrive gives roughly 7.3 GB usable, so about **4.7 GB stays free** for
chat data and future updates.

Two constraints shaped the model choice as much as quality did:

- **The FAT32 4 GiB per-file limit.** Q4_K_M at 2.50 GB clears it comfortably.
  Q8_0 at 4.28 GB does not, and would require exFAT.
- **Headroom.** Filling a drive to 95 percent leaves nowhere for logs, chat
  history or a second model later.

Log growth is bounded by design rather than by hope: rotation is size-based at
2 MiB per file with 3 generations kept, across three files, so logs cannot
silently consume the free space.
