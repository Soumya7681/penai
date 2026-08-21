# Testing

This document records exactly what was tested, and exactly what was not. Nothing
here is aspirational. If a capability is not listed under "Automated",
"Manual integration" or "Filesystem behaviour", treat it as untested.

---

## Summary

| Category | Status |
|---|---|
| Rust unit tests | **84 pass** (`cargo test`) |
| Manual integration, Linux x86_64 | Done, with the real model and the real engine |
| Filesystem behaviour | Measured on the real pendrive |
| Windows end to end | **Not tested** |
| macOS | **Not tested** |
| GPU, ARM, long sessions, multi-user | **Not tested** |

To run the automated suite:

```bash
cd launcher
cargo test
```

---

## Automated

84 Rust unit tests pass (`cargo test`), covering:

**Parsing and configuration**

- JSON parsing and rejection of malformed input.
- Config defaults, clamping and warnings.

**Portable paths**

- Portable path resolution against four simulated roots, including a
  Windows-style root.
- Root discovery via marker file and via structure.

**Model and layout validation**

- Model discovery: conventional name, largest `.gguf`, missing, truncated.
- Validation messages for missing runtime, missing model and missing web build.

**Hardware assessment**

- Thread recommendation bounds.
- RAM assessment: ok, tight, unlikely, unknown.
- Footprint growth with context.

**Logging**

- Log rotation and bounded history, plus unwritable-destination degradation and
  multi-threaded logging.
- ISO timestamp and civil-date conversion.

**Networking**

- Loopback-only addressing.
- Port busy detection and fallback.
- HTTP client status and body parsing against a real one-shot server.
- Health 503 mapping.
- Health-wait abort and timeout messages.

**Child process**

- argv construction: loopback enforced, all required flags present, spaces and
  shell metacharacters preserved as single arguments, and `--no-webui` never
  passed.
- Missing-binary error.
- Real child-process exit detection with diagnosis.
- Real child termination.

**Single instance**

- Single-instance acquire, refuse and release, and a corrupt instance file.

**Storage sidecar**

- Health.
- Empty document.
- Real round-trip to disk.
- Invalid JSON rejected.
- Foreign origin rejected.
- Non-loopback `Host` rejected.
- Oversized body rejected.
- Unknown routes 404.
- CORS preflight.
- Atomic write leaves no temp file.

---

## Manual integration, Linux x86_64

- llama.cpp `b10549` started with the real `Qwen3-4B-Instruct-2507-Q4_K_M` model.
- `/v1/health` reached 200 after **6 s**.
- `--path` verified to serve a custom `index.html` and a custom asset at `/`.
- `--no-webui` verified to break static serving (404).
- Real SSE streaming verified with token deltas and a `data: [DONE]` terminator.
- Non-streaming completion returned a correct fenced Python code block.
- Measured **13.2 tok/s** generation and **50.3 tok/s** prompt.
- Client abort verified to leave the server healthy with the slot freed.
- `/props` and `/v1/models` verified to respond.

The performance figures come from one machine only and are not a guarantee. The
development machine was an Intel-class x86_64 with 12 logical cores and 15 GiB of
RAM, with the model on a local SSD, context 4096 and 6 threads.

---

## Filesystem behaviour, measured on the real pendrive

- Direct ELF execution denied under FAT32 `showexec`.
- Symlinks and hard links not permitted.
- Case-insensitive.
- 3.4 MB/s writes.

---

## Not tested

- **Windows end to end.** There is no Windows machine available, and no Windows
  binary was built.
- **`StartAI.bat`.**
- **macOS.**
- **The `StartAI.sh` FAT32 staging bootstrap end to end.**
- **GPU builds.**
- **Any ARM platform.**
- **Long multi-hour sessions.**
- **Concurrent multi-user access.**
