# Troubleshooting

Symptoms, causes and fixes, including findings from the real test drive.

[← All documentation](README.md) · [Project home](../README.md)

---

**The browser did not open.**
The launcher prints the URL. Open it yourself: `http://127.0.0.1:8080` or
whichever port was printed. `--no-browser` suppresses opening by design.

**Port 8080 is busy.**
This is handled automatically: 8081 to 8180 are scanned, then an ephemeral port
is requested. Use `--port <n>` to pin a specific one.

**"model file not found".**
Run the download script in `models/`. The launcher looks for `models/model.gguf`,
then any single `.gguf` in `models/`, then `model.file` in the config.

**"model file looks truncated".**
The download was interrupted. Re-download and verify the SHA-256 against
`3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597`. The correct
size is exactly 2,497,281,120 bytes.

**"Permission denied" when running `./StartAI` on Linux.**
The drive is FAT32 mounted with `showexec`, under which only `.exe`, `.com` and
`.bat` names get an execute bit. `chmod +x` has no effect. Two fixes:

```bash
sh StartAI.sh        # immediate workaround
```

or reformat the drive to exFAT (see [Preparing the pendrive](PENDRIVE.md)). This was measured on the real
test drive, not assumed. See the filesystem notes below.

**glibc too old.**
The prebuilt Linux binaries need glibc 2.34 or newer. Ubuntu 22.04+, Debian 12+
or Fedora 35+. There is no workaround short of a newer distribution or building
llama.cpp yourself.

**"engine failed to start".**
Read `data/logs/llama-server.stderr.log`. That file has the engine's own error
message, which is almost always more specific than the launcher's.

**Out of memory.**
Close other applications, then try `--ctx 2048`, then a smaller quantisation
(Q3_K_M or Q2_K, see `models/README.md`).

**My chats are missing on another computer.**
Expected. IndexedDB is per browser profile per machine. Enable the portable
storage sidecar so history is written to `data/chats/chats.json` on the drive.
See [Privacy](PRIVACY.md).

**Generation is slow.**
Expected on CPU. The development machine measured 13.2 tokens/second. A weaker
CPU will be slower. Reducing context does not make generation faster; it only
reduces memory use.

**"already running".**
The single-instance guard holds a bound loopback socket on port 47610 as its
mutex, rather than a lock file, because the OS releases a socket even after a
crash or an unplug. It writes `data/run/instance.json` with the live URL, so a
second launch just reopens the browser at the session already running.

## Filesystem findings on the actual test drive

The test pendrive arrived as FAT32, mounted with the `showexec` option. These
were measured on it, not inferred:

| Test | Result |
|---|---|
| Execute a compiled Linux ELF (`./binary`) | "Permission denied". `chmod +x` had no effect |
| Create a symlink | "Operation not permitted" |
| Create a hard link | "Operation not permitted" |
| Case sensitivity | Case-insensitive |
| Write speed | 3.4 MB/s |

Four consequences follow.

1. **Linux users cannot run `./StartAI` directly from a FAT32 drive.** The
   shipped fix is `StartAI.sh`, run as `sh StartAI.sh`, which stages the
   launcher and runtime into a local temporary directory, marks them executable,
   and sets `PENAI_ROOT` back to the pendrive. Windows is unaffected,
   because `.exe` runs normally on FAT32.
2. **exFAT is the recommended fix.** It allows direct execution on Linux and
   removes the 4 GiB per-file limit, while staying readable on Windows and macOS.
   Commands are in [Preparing the pendrive](PENDRIVE.md). Reformatting erases the drive, so confirm the
   device with `lsblk` first.
3. **Symlinks must be flattened at packaging time.** Neither FAT32 nor exFAT
   stores symlinks, so the packaging script replaces the llama.cpp symlinks
   (`libggml-base.so -> libggml-base.so.0.20.2` and friends) with real files
   named after the SONAME the binary actually loads.
4. **Never run `npm install` on the drive.** It needs about 30,000 small files
   and symlinks. Build caches belong on local disk.
