# Running PenAI

Starting the drive on Linux and Windows, and how the browser behaves.

[← All documentation](README.md) · [Project home](../README.md)

---

## Starting PenAI

**Linux, exFAT or any drive that allows execution:**

```bash
cd /media/<you>/PENAI
./StartAI
```

**Linux, FAT32 (or any `noexec` mount):**

```bash
cd /media/<you>/PENAI
sh StartAI.sh
```

`StartAI.sh` copies the launcher and the llama.cpp runtime into a local temporary
directory, marks them executable, and runs the launcher with `PENAI_ROOT`
pointing back at the pendrive. The model and the web assets are still read from
the drive, so nothing large is copied.

**Windows:**

```
StartAI.exe          (if you built it)
StartAI.bat          (zero-compile fallback: double-click it, or run it from cmd)
```

`StartAI.bat` needs nothing installed, but chats started under it stay in that
browser's storage on that computer rather than on the drive, and closing the
console window stops the engine. [Building the Windows release](BUILD.md#building-the-windows-release) lists everything it does not do.

**CLI flags:**

| Flag | Effect |
|---|---|
| `--port <n>` | Force a specific port instead of automatic selection |
| `--ctx <n>` | Force a context size |
| `--threads <n>` | Force a CPU thread count |
| `--no-browser` | Start the engine but do not open a browser |
| `--force` | Start even when the RAM gate says the model will not fit |
| `--quiet` | Reduce console output |
| `-V`, `--version` | Print the launcher version |
| `-h`, `--help` | Print usage |

**What the launcher does, in order:**

1. Resolve its own directory and find the project root.
2. Read the config and create the data directories.
3. Open a rotating log.
4. Enforce single instance.
5. Probe hardware: OS, architecture, logical cores, total and available RAM.
6. Locate and sanity-check the model file.
7. Query the engine version.
8. Assess whether RAM is sufficient, and reduce the context if it is tight.
9. Pick a free loopback port.
10. Spawn `llama-server` as a child process with an argv array.
11. Stream child stdout and stderr into rotating logs.
12. Poll `/v1/health` until the engine is ready.
13. Start the optional chat-history sidecar.
14. Write `web/runtime-config.json`.
15. Open the default browser.
16. Supervise the child, and stop it cleanly on Ctrl+C.

**Thread selection.** With 2 or fewer cores it uses all of them; with 4 or fewer,
cores minus 1; otherwise `max(cores / 2, 4)`. The result is always clamped to the
range 1 to 16. The reason is that llama.cpp CPU inference is
memory-bandwidth-bound, so using every logical core is often *slower* and leaves
the machine unusable for anything else.

**Port selection.** It prefers 8080. If that is busy it scans 8081 to 8180. If
all of those are busy it asks the OS for an ephemeral port. If `llama-server`
still fails to bind, the launcher retries on a different port, up to 3 attempts.

**The RAM gate.** The launcher estimates weights plus KV cache plus about 400 MiB
of buffers.

- Fits with 512 MiB to spare: start normally.
- Tight: warn, then halve the context repeatedly until it fits, with a floor of 512.
- Cannot fit at all: refuse, explain why, and require `--force` to override.
- RAM cannot be read: warn and continue, making no capability claim.

The launcher never promises that the model will run. It tells you what it
measured and what it decided.

**Measured performance, development machine only.** Intel-class x86_64, 12
logical cores, 15 GiB RAM, model on a local SSD, context 4096, 6 threads:

| Metric | Measured |
|---|---|
| Model load time | 6 seconds |
| Generation | 13.2 tokens/second |
| Prompt processing | 50.3 tokens/second |

These are one-machine measurements, not a guarantee. Loading from the pendrive
itself will be slower than 6 seconds: the measured write speed on the test drive
was 3.4 MB/s, and while reads are faster they are still far below SSD.

**Logs** live in `data/logs/`: `launcher.log`, `llama-server.stdout.log` and
`llama-server.stderr.log`. Rotation is size-bounded, 2 MiB per file by default,
3 generations kept. If the drive is read-only, logging degrades to console output
instead of failing.

## Browser URL behaviour

The UI lives at:

```
http://127.0.0.1:<PORT>
```

`<PORT>` is printed by the launcher. It is usually 8080.

Two behaviours are worth knowing, because both come from llama.cpp's static file
handler rather than from our code.

**There is no SPA deep-route fallback.** An unknown path such as
`/some/deep/route` returns HTTP 404. This is why the UI is deliberately
single-route with no client-side router. Bookmark the bare origin, not a subpath.

**`--no-webui` must never be passed.** Verified behaviour: `--path <dir>` makes
`llama-server` serve our React build at `/` and replaces llama.cpp's own bundled
web UI, which is what we want. But adding `--no-webui` disables the entire static
file handler, and then both `/` and `/probe.txt` return HTTP 404. The launcher
never passes it, and there is a unit test asserting that.

Also served on the same origin, from the same process:

| Endpoint | Purpose |
|---|---|
| `GET /v1/health` | 200 `{"status":"ok"}` when ready, 503 while loading. `/health` is probed as a fallback |
| `GET /props` | Engine details, including context size |
| `GET /slots` | Slot state, for example `is_processing` |
| `POST /v1/chat/completions` | Chat, with `"stream": true` for SSE |
| `GET /v1/models` | Model listing |
