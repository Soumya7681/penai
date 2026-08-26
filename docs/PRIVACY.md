# Privacy and security

What leaves the machine (nothing), and what the threat model is.

[← All documentation](README.md) · [Project home](../README.md)

---

## Privacy

- The model runs on your CPU. Prompts and responses never leave the machine.
- No cloud APIs. No OpenAI API, no Anthropic API, no hosted inference of any kind.
- No telemetry, no analytics, no crash reporting, no update check.
- No internet access is needed after the drive has been prepared.
- No chat data is ever sent to any external server.

**Where your chats are stored, stated plainly.**

The primary store is **IndexedDB in the browser**. IndexedDB is tied to the
origin *and* to the browser profile on the host computer. So by default your
chats stay on that computer and **do not travel with the pendrive**. Plug the
drive into a different machine and the sidebar will be empty.

Because of that limitation, the launcher also runs a small optional **portable
chat-history sidecar**. It is an HTTP server built into the launcher binary
itself: std-only Rust, no database, no Node.js, no Python, no Docker. It listens
on `127.0.0.1:47611` and persists one JSON document to `data/chats/chats.json` on
the pendrive, so history does travel with the drive.

| Endpoint | Purpose |
|---|---|
| `GET /api/health` | Liveness |
| `GET /api/chats` | Read the whole document |
| `PUT /api/chats` | Replace the whole document |

If the sidecar cannot start, because the drive is read-only, the port is busy, or
it is disabled in the config, the UI silently falls back to IndexedDB only. It is
an enhancement, never a hard dependency.

Data model. A chat has `id`, `title`, `createdAt`, `updatedAt`, plus a `deleted`
tombstone so that a delete performed on one computer survives a sync from
another. A message has `id`, `chatId`, `role`, `content`, `createdAt`, plus
optional `reasoning`, `stopped`, `error` and `tokensPerSecond`. Merging across
computers is a union by `id` with last-write-wins by `updatedAt`.

Sidecar hardening:

- Binds `127.0.0.1` only.
- Requires a loopback `Host` header as a DNS-rebinding guard, and returns 421 otherwise.
- If an `Origin` header is present it must exactly match the llama-server origin, else 403.
- Only fixed routes exist, so no request-supplied path ever reaches the filesystem.
- Request bodies are capped at 32 MB.
- Writes are atomic: temp file plus rename.
- Invalid JSON is rejected with 400, so the stored file cannot be corrupted.

## Security

**Loopback only.** `llama-server` is bound to `127.0.0.1`, never `0.0.0.0`. This
is not configurable. The model is not reachable from your local network.

**CORS.** The launcher passes `--cors-origins localhost` instead of llama.cpp's
default `*`.

**No shell, ever.** Arguments are passed to `llama-server` as an argv array via
`std::process::Command`. No shell is invoked and no command string is ever
concatenated, so a path containing a space, a quote, `&`, `;` or `$(...)` cannot
become code. There are unit tests that assert shell metacharacters survive as a
single argument.

**No `innerHTML`.** Markdown and code-block rendering in the UI are hand-written
into React elements. Nothing is ever assigned to `innerHTML`, so there is no XSS
surface, and no heavy markdown or syntax-highlighting dependency is pulled in.

**Content-Security-Policy.** A meta tag restricts `connect-src` to `'self'` plus
loopback, so the page cannot reach any remote host even if something tried.

**URL allowlist.** The launcher refuses to open any URL that is not
`http://127.0.0.1:<port>` or `http://localhost:<port>`.

**Child process containment.** On Linux the child gets `PR_SET_PDEATHSIG`, so
`llama-server` cannot outlive the launcher. Shutdown sends SIGTERM and escalates
to a kill after a grace period. On Windows shutdown uses `TerminateProcess`, so
**Windows shutdown is not graceful**.

**What PenAI does not protect against, stated honestly.** Anything running
as your user on the same computer can reach a loopback port. PenAI adds no
authentication, because putting a shared secret in a page served from the same
origin buys very little. Do not run it on a shared or multi-user machine you do
not trust.
