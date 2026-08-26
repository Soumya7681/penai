# Building a release

One command for the whole drive, and the individual steps behind it.

[← All documentation](README.md) · [Project home](../README.md)

---

## Building the release

### The one command

```bash
./scripts/build-all.sh --target /media/you/PENDRIVEAI
```

That is the whole build. It fetches the llama.cpp runtimes, builds the web UI,
builds the launcher for Linux and (if mingw-w64 is installed) for Windows,
downloads and checksums the model, assembles `release/`, and copies the result
onto the drive.

It is resumable. Every step skips itself when its output already exists, so an
interrupted run costs nothing to repeat - which matters, because the model
download alone is 2.5 GB. It never uses `sudo` and never formats anything; if a
prerequisite needs root it stops and prints the exact command to run.

Useful variations:

```bash
./scripts/build-all.sh                             # build only, copy nothing
./scripts/build-all.sh --model ~/my-model.gguf     # use a model you already have
./scripts/build-all.sh --platform linux            # skip the Windows half
./scripts/build-all.sh --skip-model                # package without weights
./scripts/build-all.sh --clean                     # rebuild everything
```

The model is cached in `~/.cache/pendriveai/model.gguf`, outside the repo, so
`--clean` and reformatting the drive never cost another 2.5 GB download.

### The individual steps

`build-all.sh` calls these in order. Run them by hand if you want to stop
between stages.

```bash
./scripts/fetch-runtime.sh     # llama-b10549-bin-ubuntu-x64.tar.gz, trimmed
cd web && npm install && npm run build && cd ..
./scripts/build-linux.sh       # builds StartAI and stages runtime + web
./scripts/package.sh           # assembles the final release/ folder
```

`cargo test` should report 85 passing tests before you package anything.

The packaging script does one non-obvious job. The llama.cpp archives contain
symlinks such as `libggml-base.so -> libggml-base.so.0.20.2`, and neither FAT32
nor exFAT can store a symlink. The script replaces each symlink with a real file
named after the SONAME the binary actually loads. Skip that step and the runtime
will fail to start from the drive.

## Building the Windows release

**Read this first: `StartAI.exe` was not built for this release.** The build
machine has no mingw-w64 and no MSVC toolchain, and installing one was declined.
The Windows path is therefore **untested on real Windows hardware**.

There are three ways forward.

**Option A, build natively on Windows (recommended).**

```powershell
cd launcher
cargo build --release        # MSVC toolchain
```

The binary lands at `launcher/target/release/StartAI.exe`. Copy it to the release
root.

**Option B, cross-compile from Linux.**

```bash
sudo apt install mingw-w64
rustup target add x86_64-pc-windows-gnu
cd launcher
cargo build --release --target x86_64-pc-windows-gnu
```

**Option C, ship no compiler at all.** A zero-compile fallback launcher,
`StartAI.bat`, is included on the drive so Windows is usable without any
toolchain. It uses only `cmd.exe` and PowerShell, both built into Windows.

It reproduces the parts of the launcher that the drive cannot work without:
it reads `config/config.json`, resolves the model the same way (explicit config
entry, then `model.gguf`, then the largest `.gguf`), rejects a truncated or
non-GGUF file, picks threads with the same rule, scans for a free loopback port,
writes `web/runtime-config.json`, starts `llama-server` with the same argv,
waits for `/v1/health` and opens the browser.

It is still a fallback, not a replacement. Four things are missing:

| Missing | Consequence |
|---|---|
| The RAM gate | It measures RAM and warns, but never reduces the context or refuses to start |
| The single-instance guard | Running it twice starts two servers on two ports |
| Rotating log files | `llama-server` writes to the console window instead of `data/logs/` |
| The chat-history sidecar | Chats stay in that browser's storage on that computer and do not travel with the drive |

`StartAI.bat` is untested on real Windows hardware.

The Windows runtime itself needs no compiler. `scripts/fetch-runtime.ps1`
downloads and trims `llama-b10549-bin-win-cpu-x64.zip`, and
`scripts/build-windows.ps1` assembles the release folder.
