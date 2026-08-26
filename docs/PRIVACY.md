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

## Web access, when you turn it on

Everything above describes the drive as it ships: nothing leaves the machine.
There is one switch that changes that, and this section is what it does.

Set `"network": { "enabled": true }` in `config/config.json` and restart. A globe
button appears next to the composer, and you can fetch one page at a time by
typing its address. The launcher makes the request with `curl` and hands the
page's text back as an attachment you review before sending anything to the
model.

What stays true with it on:

- **The model cannot browse.** There is no tool-calling loop and no crawler. A
  fetch happens only when a person types an address and presses Fetch.
- **The page still cannot reach the internet.** Its Content-Security-Policy is
  unchanged, so the browser talks only to `127.0.0.1`. The launcher makes the
  outbound request, not the page.
- **Addresses on this machine or this network are refused**, before the request
  and again after any redirect: `127.x`, `10.x`, `172.16-31.x`, `192.168.x`,
  `169.254.x` (which includes the cloud metadata address), `100.64.0.0/10`, IPv6
  loopback and unique-local, and names ending `.local`, `.internal`, `.localhost`
  or `.home.arpa`. A drive plugged into an office network cannot be turned into a
  port scanner.
- **Only http and https**, on the request and on redirects. No `file://`, and no
  credentials embedded in the address.
- **Bounded**: a timeout you set (5-120 seconds) and a size cap you set (16 KB to
  32 MB), defaulting to 20 seconds and 2 MB.
- **Visible**: the readout strip's `LINK` cell changes from `offline` to
  `web access on` and turns amber. The state is never hidden from you.

Search, if you configure a provider, adds one more outbound path: the query goes
to the provider you named, and nothing else. Results are a list of links; opening
one is a separate fetch, held to every rule above. The provider's own address is
the one exception to the private-address rule, because a self-hosted SearXNG on
your LAN is the normal case and that address comes from your config file rather
than from a page.

What you are accepting with it on:

- **The site learns you visited.** Your IP address, and a `PenAI/1.0` user agent.
  There is no proxy and no anonymity layer.
- **A fetched page is untrusted text written by someone else**, and the model
  reads it. A page can contain instructions aimed at the model. The fetched block
  is labelled with its source in the prompt, but treat any reply that draws on a
  fetched page the way you would treat the page itself.
- **A search query is a disclosure.** What you search for goes to the provider,
  who may log it against your IP address. A SearXNG instance you run yourself is
  the only option here where that log is yours.
- **An API key in `config.json` is plain text on a removable drive.** Anyone
  holding the pendrive can read it. Use a key you can revoke.
- **The offline guarantee becomes conditional.** With the switch on, PenAI is a
  program that makes outbound requests when asked. If you need the absolute
  version of the promise, leave it off, which is how the drive ships.

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
