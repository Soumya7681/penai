# Development setup

Toolchains and the edit-run loop for changing the code.

[← All documentation](README.md) · [Project home](../README.md)

---

> **Just want a working drive?** You do not need this section. Run
> `./scripts/build-all.sh --target /media/you/PENDRIVEAI` and skip to
> [[Starting PendriveAI](USAGE.md#starting-pendriveai)](#starting-pendriveai). This section is for changing the code.


The development machine needs a Rust toolchain and Node.js. **Neither is needed
on the target computer.**

| Tool | Version |
|---|---|
| Rust | stable, 1.70 or newer |
| Node.js | 18 or newer, with npm |

Repository layout:

```
launcher/                 Rust launcher (std only)
web/                      React + TypeScript + Vite UI
models/                   README and download scripts, never the model itself
config/config.example.json
scripts/                  runtime fetch, build and packaging scripts
docs/                     ARCHITECTURE.md, TESTING.md
tests/
```

Steps:

```bash
# 1. Download and trim the llama.cpp runtime for your platform
./scripts/fetch-runtime.sh            # Linux and macOS
# or
powershell -File scripts/fetch-runtime.ps1   # Windows

# 2. Download the model (see [Model setup](MODELS.md))
cd models && ./download-model.sh && cd ..

# 3. Build the web UI
cd web
npm install
npm run build
cd ..

# 4. Build the launcher
cd launcher
cargo build --release
cargo test
```

```bash
# Live UI development against a running llama-server
cd web && npm run dev      # http://127.0.0.1:5173, API calls proxied to :8080
```

**Do not run `npm install` on the pendrive.** It creates roughly 30,000 small
files and needs symlinks, which FAT32 and exFAT cannot store and which a
3.4 MB/s drive will take a very long time to write. Keep `node_modules` and all
build caches on local disk. The build scripts redirect Cargo output off the drive
with `CARGO_TARGET_DIR` for the same reason.

`.gitignore` excludes `*.gguf`, `runtime/`, `release/`, `web/dist/`,
`web/node_modules/`, `launcher/target/`, `data/` and `config/config.json`.
