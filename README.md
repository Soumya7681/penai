# PendriveAI

A portable, fully offline local-LLM system that runs from an 8 GB USB pendrive.

Plug in the drive, run one launcher, and a local AI chat UI opens in your default
browser. No installation, no internet, no admin rights, no Node.js, no Python,
no Docker, no cloud API.

> **Preparing a drive for the first time?** Start with
> [section 12.1, Format the pendrive first](#121-format-the-pendrive-first-do-this-before-anything-else),
> then follow
> [section 12.2, From zero to chatting](#122-from-zero-to-chatting-the-full-checklist).
> Formatting the drive as exFAT is what makes the launcher runnable on Linux at all.

---

## Status

Read this before you judge anything below as "done".

**Verified working (built, run and measured on Linux x86_64):**

- llama.cpp release `b10549` starting with the real Qwen3-4B-Instruct-2507-Q4_K_M model.
- `/v1/health` reaching HTTP 200 after 6 seconds on the development machine.
- `llama-server --path <dir>` serving the React production build at `/`.
- Real Server-Sent Events streaming with token deltas and a `data: [DONE]` terminator.
- Client-side abort (stop generation) leaving the server healthy and the slot freed.
- Measured 13.2 tokens/second generation and 50.3 tokens/second prompt processing.
- The Rust launcher: 85 unit tests pass with `cargo test`.
- Real pendrive filesystem behaviour under FAT32 with the `showexec` mount option.

**Not built here:**

- `StartAI.exe`. The build machine has no mingw-w64 and no MSVC toolchain, and
  installing one was declined. See section 10.

**Not tested:**

- Windows end to end, and `StartAI.bat`.
- macOS (no runtime is shipped for it in v1).
- The `StartAI.sh` FAT32 staging bootstrap end to end.
- GPU builds, any ARM platform, long multi-hour sessions, concurrent multi-user access.

Full detail is in [`docs/TESTING.md`](docs/TESTING.md).

---

## 1. What PendriveAI is

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

## 2. How it works

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

## 3. Features

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
acceleration, authentication, more than one model. See section 18.

## 4. Architecture

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
| Chat storage | IndexedDB, plus an optional portable JSON sidecar | See section 15 |

The launcher's own modules are `main.rs`, `paths.rs`, `config.rs`, `sysinfo.rs`,
`net.rs`, `child.rs`, `logging.rs`, `json.rs`, `lock.rs`, `store.rs`,
`browser.rs` and `signals.rs`.

The deeper design rationale, including why llama.cpp's `--path` was chosen over
shipping a separate static server, is in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## 5. Supported platforms

| Platform | Status |
|---|---|
| Linux x86_64 | Supported and tested. Requires **glibc 2.34 or newer** |
| Windows x86_64 | Supported by design, **untested on real Windows hardware**; `StartAI.exe` is not built here |
| macOS | Not supported in v1. No runtime is shipped and the memory probe returns unknown |
| ARM (any OS) | Not supported. No ARM runtime is shipped and none was tested |
| iOS / iPadOS | Cannot work. See below |

**glibc requirement.** The prebuilt Linux binaries were checked with `objdump`
and require glibc 2.34 or newer. That covers Ubuntu 22.04 and later, Debian 12
and later, and Fedora 35 and later. Older distributions will not run them.
The Linux binaries carry `RUNPATH=$ORIGIN`, so no `LD_LIBRARY_PATH` is needed.

**iOS and iPadOS cannot run PendriveAI.** This is not a missing feature, it is a
platform rule. iOS does not let a user execute an arbitrary native binary from
external storage: apps must be installed through the App Store or a provisioning
profile, they are sandboxed, and they cannot spawn child processes. The Files app
can read a USB drive but it cannot execute anything on it. There is therefore no
way to run `llama-server` from a pendrive on iOS. The realistic alternatives,
neither of which is promised here, are a native iOS app that embeds llama.cpp
with its own model copied into the app sandbox, or running PendriveAI on a
computer and reaching it from the iPad over the LAN. The second would require
binding beyond loopback, which v1 deliberately does not support.

## 6. Hardware requirements

**Target computer (the machine you plug the drive into):**

| Item | Requirement |
|---|---|
| CPU | Any modern x86_64. The runtime auto-selects among 15 bundled CPU-feature variants, from SSE4.2 up to AVX-512 / Zen 4 |
| RAM | 8 GB recommended. 4 GB workable at reduced context. Below 4 GB is likely to fail |
| Disk | None. Nothing is installed |
| Network | None |
| Privileges | No admin rights |

**Not needed on the target computer:** Node.js, Python, Docker, Ollama, an
internet connection, admin rights, or any installation step.

**Why 15 CPU variants matter.** One drive has to work on an old office desktop
and on a current laptop. The prebuilt llama.cpp release ships multiple builds
selected at runtime by CPU feature detection, which is exactly the property that
makes a single portable drive viable.

**RAM arithmetic.** The model has 36 layers, 8 KV heads (GQA) and head_dim 128,
so the f16 KV cache costs `2 * 36 * 8 * 128 * 2 = 147,456` bytes per token,
which is 144 KiB per token. At a context of 4096 that is roughly 0.6 GiB of KV
cache on top of the 2.50 GB of weights, plus about 400 MiB of buffers. The
launcher does this estimate before starting anything and reacts to the result
(see section 13).

## 7. 8 GB storage requirements

| Item | Size |
|---|---|
| Model (`Qwen3-4B-Instruct-2507-Q4_K_M.gguf`) | 2.50 GB |
| Linux runtime (trimmed) | about 40 MB |
| Windows runtime (trimmed) | about 45 MB |
| Web production build | under 1 MB |
| Launcher binaries | about 1 MB |
| Config, docs and logs | well under 5 MB |
| **Total** | **about 2.6 GB** |

An 8 GB pendrive gives roughly 7.3 GB usable, which leaves about 4.7 GB free for
chat data and future updates.

For reference: the downloaded llama.cpp archives are 16.7 MB (Linux
`llama-b10549-bin-ubuntu-x64.tar.gz`) and 18.6 MB (Windows
`llama-b10549-bin-win-cpu-x64.zip`). Extracted they are 41 MB and 46 MB. After
trimming to only the files `llama-server` actually needs, each platform folder is
roughly 40 to 45 MB.

## 8. Model setup

PendriveAI v1 ships exactly one model.

| Field | Value |
|---|---|
| Name | Qwen3-4B-Instruct-2507 |
| Quantisation | Q4_K_M (GGUF) |
| Hugging Face repo | `unsloth/Qwen3-4B-Instruct-2507-GGUF` |
| File | `Qwen3-4B-Instruct-2507-Q4_K_M.gguf` |
| Size | 2,497,281,120 bytes (2.33 GiB / 2.50 GB) |
| SHA-256 | `3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597` |
| Licence | Apache-2.0, not gated, no login required |

Direct URL:

```
https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf
```

Quick download:

```bash
cd models
./download-model.sh          # Linux and macOS
# or
powershell -File download-model.ps1   # Windows
```

The launcher expects the file at `models/model.gguf` by default. It will also
accept any single `.gguf` file in `models/` (the largest wins), or an explicit
`model.file` entry in the config.

**Why this model.** Apache-2.0 allows commercial use. 4B parameters is the sweet
spot for CPU chat plus programming help. Q4_K_M fits an 8 GB drive with room to
spare and stays under the FAT32 4 GiB per-file limit. It is the non-thinking
"Instruct" variant, so it answers directly instead of emitting long reasoning
traces.

Alternative quantisations, other usable models, manual download instructions
and per-platform checksum verification are documented in
[`models/README.md`](models/README.md).

The model is **never committed to git**. `.gitignore` excludes `*.gguf`.

**Before you copy the model onto a pendrive, format the drive.** The choice of
filesystem decides whether the model will even fit: FAT32 caps a single file at
4 GiB, so Q4_K_M at 2.50 GB is fine but Q8_0 at 4.28 GB cannot be stored at all.
exFAT removes that limit and also lets the launcher execute directly on Linux.
Step-by-step instructions for Linux, Windows and macOS are in
[section 12.1, Format the pendrive first](#121-format-the-pendrive-first-do-this-before-anything-else).

### Which models can I use?

v1 ships exactly one model, and **the launcher loads exactly one model at a
time**. There is no model picker in the UI. Swapping models means replacing
`models/model.gguf` (or setting `model.file` in `config/config.json`) and
restarting the launcher.

**Hard requirements for any replacement:**

1. **GGUF format.** llama.cpp does not load `.safetensors`, `.bin` or PyTorch
   checkpoints. It must be a `.gguf` file.
2. **An architecture supported by the packaged llama.cpp build `b10549`.** A
   model whose architecture is newer than the bundled engine will fail to load.
3. **It must fit in RAM alongside the KV cache.** See the sizing rule below.
4. **On FAT32, the single file must stay under 4 GiB.** exFAT removes this limit.
5. **For chat use it must be instruct or chat-tuned.** A base or completion model
   will not follow a conversation; it will just continue your text.

**What we actually tested.** Only **Qwen3-4B-Instruct-2507-Q4_K_M** has been
tested by us: measured 13.2 tok/s generation, 50.3 tok/s prompt processing, and a
6 second load, on the development machine described in section 13. Everything
else listed below **should work, but was not tested here**.

#### Same family, different size or quality

All Apache-2.0. These live in `unsloth/Qwen3-4B-Instruct-2507-GGUF`, or in the
matching `unsloth/Qwen3-<size>-GGUF` repo for the smaller models.

| Model | Params | Quant | Approx size | Licence | Notes |
|---|---|---|---|---|---|
| **Qwen3-4B-Instruct-2507** | 4B | **Q4_K_M** | **2.50 GB** | Apache-2.0 | **The shipped default.** Best balance for 8 GB drives |
| Qwen3-4B-Instruct-2507 | 4B | Q3_K_M | 2.08 GB | Apache-2.0 | For machines with about 4 GB RAM; some quality loss |
| Qwen3-4B-Instruct-2507 | 4B | Q2_K | 1.67 GB | Apache-2.0 | Last resort for very low RAM; noticeably worse |
| Qwen3-4B-Instruct-2507 | 4B | Q5_K_M | 2.89 GB | Apache-2.0 | Better quality if you have 8 GB+ RAM and drive space |
| Qwen3-4B-Instruct-2507 | 4B | Q6_K | 3.31 GB | Apache-2.0 | Higher quality, slower on CPU |
| Qwen3-4B-Instruct-2507 | 4B | Q8_0 | 4.28 GB | Apache-2.0 | **EXCEEDS the FAT32 4 GiB single-file limit. exFAT only** |
| Qwen3-1.7B | 1.7B | Q4_K_M | see repo | Apache-2.0 | Much faster on weak CPUs, clearly weaker at reasoning and code |
| Qwen3-0.6B | 0.6B | Q4_0 | 382 MB | Apache-2.0 | Only useful for testing that the plumbing works; too weak for real use |

Two notes on Qwen3-0.6B. We did use it during development for fast integration
testing, because it loads in a fraction of the time. It is also a **thinking**
variant, so it emits `reasoning_content`, which the UI renders in a separate
collapsible block rather than mixing it into the answer.

#### Other families worth knowing about

| Model | Params | Quant | Approx size | Licence | Notes |
|---|---|---|---|---|---|
| Qwen2.5-Coder-3B-Instruct | 3B | GGUF, your choice | see repo | **Check the specific repo.** Some Qwen2.5 sizes are released under a Qwen research licence rather than Apache-2.0, so verify before commercial use | Stronger at code than at general chat |
| Llama-3.2-3B-Instruct | 3B | GGUF, your choice | see repo | Llama 3.2 Community Licence. Acceptable-use terms plus naming and attribution requirements, not a plain open-source licence | Capable general model |
| Gemma-3-4B-IT | 4B | GGUF, your choice | see repo | Gemma Terms of Use, which carry usage restrictions | Capable general model |
| Phi-4-mini-instruct | 3.8B | GGUF, your choice | see repo | MIT | Strong at reasoning for its size |
| SmolLM3-3B | 3B | GGUF, your choice | see repo | Apache-2.0 | Small and fast |

> **Licence warning.** We verified the licence only for
> **Qwen3-4B-Instruct-2507** (Apache-2.0, confirmed on the upstream
> `Qwen/Qwen3-4B-Instruct-2507` repository). For anything else, **check the
> licence on the actual repository you download from.** Quantised re-uploads
> sometimes state a different licence from the original weights.

#### How to swap the model

1. Download the replacement `.gguf`.
2. Put it in `models/` on the drive.
3. Either rename it to `model.gguf`, or set
   `"model": { "file": "your-file.gguf" }` in `config/config.json`.
4. If it is much bigger than the old one, lower `llama.ctxSize` (or pass `--ctx`)
   so that it still fits in RAM.
5. Restart the launcher. The status bar in the UI will show the new model name
   and the engine's reported context size.

If several `.gguf` files are present and `model.file` is empty, the launcher picks
the **largest** one, with ties broken by filename, so the choice is
deterministic rather than dependent on directory order.

#### RAM sizing rule of thumb

Needed RAM is roughly:

```
model file size
  + about 144 KiB per context token   (for a 4B-class model)
  + about 400 MiB of buffers
```

So for a 4B-class model, the KV cache costs about **0.6 GiB at ctx 4096** and
about **1.2 GiB at ctx 8192**.

The launcher computes this itself, warns when it is tight, and reduces the
context automatically rather than letting the machine thrash. See section 13.

#### Not supported in v1

- **Multimodal and vision models.** The `mtmd` library is bundled with the
  llama.cpp release, but the launcher does not wire up an image path, so there is
  no way to send an image.
- **Embedding-only models.** The UI is a chat client and expects
  `/v1/chat/completions`.
- **GPU-accelerated builds.** The shipped runtime is CPU-only by choice, for
  portability across unknown machines and for size.

## 9. Development setup

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

# 2. Download the model (see section 8)
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

## 10. Building the Windows release

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

## 11. Building the Linux release

This is the tested path.

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

## 12. Copying to the pendrive

Two things happen here, in this order: **format the drive**, then copy the release
onto it. Do not skip the formatting step, because it is what decides whether a
Linux user can run the launcher at all.

- [12.1 Format the pendrive first](#121-format-the-pendrive-first-do-this-before-anything-else)
- [12.2 From zero to chatting: the full checklist](#122-from-zero-to-chatting-the-full-checklist)
- [12.3 Copying the release folder](#123-copying-the-release-folder)

### 12.1 Format the pendrive first (do this before anything else)

> ### WARNING
>
> **Formatting ERASES EVERYTHING on the drive.** Back up anything you care about
> first. You must identify the correct device before you type a format command.
> Getting the device wrong destroys the wrong disk, and there is no undo.

#### Why format at all

**exFAT is the recommended format.**

Measured on the real test drive: it arrived as FAT32 mounted with the `showexec`
option, and under that mount a compiled Linux binary **could not be executed**.
`./binary` returned "Permission denied", and `chmod +x` had no effect. FAT32 also
caps any single file at 4 GiB.

exFAT fixes both problems. It allows direct execution on Linux, it has no
practical file-size cap, and it is readable on Windows, macOS and Linux.

Neither FAT32 nor exFAT supports symlinks. That limitation does not go away with
exFAT, and it is why the packaging step dereferences the llama.cpp library
symlinks into real files (see section 11).

The other two obvious candidates were rejected:

| Filesystem | Verdict |
|---|---|
| **exFAT** | Recommended. Execution allowed on Linux, no practical file-size cap, readable on Windows, macOS and Linux |
| **FAT32** | Works, with caveats. No Linux execution under `showexec`, and a hard 4 GiB per-file limit |
| **NTFS** | Poor choice for cross-platform use. Linux write support is possible, but permissions and safe-eject behaviour are worse |
| **ext4** | Linux only. Unreadable on stock Windows |

#### Linux, command line

**Step 1. Identify the device.**

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,MODEL,TRAN,RM
```

What to look for in that output:

- `TRAN` is `usb`.
- `RM` is `1`, meaning removable.
- `SIZE` matches your pendrive.

**Never pick the disk that holds `/` or `/boot`.** Check the `MOUNTPOINT` column
before you do anything else. The whole device looks like `/dev/sdb` and the
partition on it looks like `/dev/sdb1`. Every command below uses `/dev/sdX1` as a
placeholder: substitute your real partition, and do not copy the placeholder
literally.

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

**Step 4. Format it as exFAT with the label `PENDRIVEAI`.**

```bash
sudo mkfs.exfat -n PENDRIVEAI /dev/sdX1
```

**Step 5. Mount it again.**

Unplug and replug the drive, or mount it explicitly:

```bash
udisksctl mount -b /dev/sdX1
```

It will appear at something like `/media/<user>/PENDRIVEAI` or
`/run/media/<user>/PENDRIVEAI`. **The launcher does not care what that path is.**
It discovers its own root at runtime, so any mount point works, spaces included.

**Step 6, only if needed. Create a partition table.**

Do this only if the drive has no partition table at all, or a broken one:

```bash
sudo parted /dev/sdX -- mklabel msdos mkpart primary 1MiB 100%
```

Then format the newly created `/dev/sdX1` with Step 4. Note that this command
takes the whole device (`/dev/sdX`), not a partition.

**Step 7. Verify.**

```bash
lsblk -f
```

The partition should now show `exfat` as its filesystem and `PENDRIVEAI` as its
label.

#### Linux, GUI alternative

GNOME Disks:

```bash
gnome-disks
```

1. Pick the USB device in the left-hand list. Confirm the size and the model so
   you are certain it is the pendrive.
2. Use the menu to choose **Format Partition**.
3. For the type, choose **Other**, then **exFAT**.
4. Set the name to `PENDRIVEAI`.

GParted also works, but it may need the `exfatprogs` package installed first
before exFAT appears as an option.

#### Windows, File Explorer (simplest)

1. Open **This PC**, right-click the USB drive, and choose **Format**.
2. Set **File system** to **exFAT**. Leave **Allocation unit size** at default.
   Set **Volume label** to `PENDRIVEAI`. Leave **Quick Format** checked.
3. Click **Start** and confirm. **This erases the drive.** Make sure the drive
   letter in the dialog title is the pendrive and not another disk.

#### Windows, PowerShell alternative

Run PowerShell **as Administrator**.

First identify the right disk:

```powershell
Get-Disk
Get-Partition -DiskNumber <n>
```

**Verify the disk number and the size before continuing.** A wrong disk number
here formats the wrong drive.

Then format, replacing `E` with the real drive letter:

```powershell
Format-Volume -DriveLetter E -FileSystem exFAT -NewFileSystemLabel PENDRIVEAI
```

`diskpart` also exists and can do this, but `Format-Volume` is safer for this
task because it operates on a volume you have already identified by letter rather
than on a selected disk.

#### macOS

1. Open **Disk Utility**.
2. Select the **USB device**, not just the volume underneath it.
3. Click **Erase**.
4. Set **Format** to **ExFAT** and **Scheme** to **Master Boot Record**.
5. Name it `PENDRIVEAI`.

macOS is mentioned here only for preparing the drive. **PendriveAI v1 does not
ship a macOS runtime**, so the drive you format on a Mac is for use on Linux or
Windows.

#### If you cannot or will not reformat

Keeping FAT32 is a supported fallback. Two consequences.

**1. On Linux you must start it differently.**

```bash
sh StartAI.sh        # instead of ./StartAI
```

`StartAI.sh` stages the launcher and the llama.cpp runtime into a local temporary
directory, where execution is allowed, while still reading the model, the web
assets and the config from the pendrive. Roughly 45 MB is copied to local disk on
first run. The 2.50 GB model is never copied.

**Windows is unaffected on FAT32**, because `.exe` runs normally there.

**2. The 4 GiB per-file limit constrains which model you can carry.** The shipped
Q4_K_M at 2.50 GB fits FAT32 comfortably. The Q8_0 quantisation at 4.28 GB
**cannot be stored on FAT32 at all** and needs exFAT. See
[`models/README.md`](models/README.md).

### 12.2 From zero to chatting: the full checklist

The complete path, in order, from an unformatted pendrive to a working chat.

1. **Format the drive as exFAT with the label `PENDRIVEAI`** (section 12.1).
2. **On a build machine:** clone the repository, and install Rust and Node.js
   (see section 9 for versions).
3. **Download the llama.cpp runtimes** (release `b10549`):
   ```bash
   bash scripts/fetch-runtime.sh --platform both
   ```
4. **Download the model** (2.50 GB Qwen3-4B-Instruct-2507-Q4_K_M GGUF) and verify
   its SHA-256:
   ```bash
   bash models/download-model.sh
   ```
5. **Build the launcher and the web UI**, and assemble the release tree at
   `release/linux/PendriveAI/`:
   ```bash
   bash scripts/build-linux.sh
   ```
6. **For Windows**, either run `scripts\build-windows.ps1` on a Windows machine,
   or cross-compile from Linux with mingw-w64 installed:
   ```bash
   bash scripts/build-windows-cross.sh
   ```
   To repeat the warning from the Status note: **`StartAI.exe` was not built or
   tested here.**
7. **Copy everything onto the drive:**
   ```bash
   bash scripts/deploy-to-pendrive.sh \
     --target /media/<user>/PENDRIVEAI \
     --platform both \
     --model models/model.gguf
   ```
   The model copy is the slow part. The measured write speed on the test drive was
   3.4 MB/s, so a 2.5 GB model can take **over 10 minutes**. Let it finish.
8. **Eject safely:** `udisksctl unmount -b /dev/sdX1` on Linux, or "Safely Remove
   Hardware" on Windows.
9. **Plug the drive into the target computer.**
10. **Run the launcher.** Linux: `./StartAI` on exFAT, or `sh StartAI.sh` on
    FAT32. Windows: double-click `StartAI.exe`, or `StartAI.bat` if the exe was
    not built.
11. **Wait** for `PendriveAI is ready at http://127.0.0.1:8080`. The browser opens
    by itself.
12. **Chat.** Press Ctrl+C in the launcher window to stop.

### 12.3 Copying the release folder

If you would rather copy by hand than use `deploy-to-pendrive.sh`, the release
folder is self-contained:

```bash
cp -r release/PendriveAI /media/<you>/PENDRIVEAI/
sync
```

At 3.4 MB/s measured write speed, the 2.6 GB payload takes a while. **Wait for
`sync` to finish before unplugging.**

Release folder structure:

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

## 13. Starting PendriveAI

**Linux, exFAT or any drive that allows execution:**

```bash
cd /media/<you>/PENDRIVEAI
./StartAI
```

**Linux, FAT32 (or any `noexec` mount):**

```bash
cd /media/<you>/PENDRIVEAI
sh StartAI.sh
```

`StartAI.sh` copies the launcher and the llama.cpp runtime into a local temporary
directory, marks them executable, and runs the launcher with `PENDRIVEAI_ROOT`
pointing back at the pendrive. The model and the web assets are still read from
the drive, so nothing large is copied.

**Windows:**

```
StartAI.exe          (if you built it)
StartAI.bat          (zero-compile fallback: double-click it, or run it from cmd)
```

`StartAI.bat` needs nothing installed, but chats started under it stay in that
browser's storage on that computer rather than on the drive, and closing the
console window stops the engine. Section 10 lists everything it does not do.

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

## 14. Browser URL behaviour

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

## 15. Privacy

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

## 16. Security

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

**What PendriveAI does not protect against, stated honestly.** Anything running
as your user on the same computer can reach a loopback port. PendriveAI adds no
authentication, because putting a shared secret in a page served from the same
origin buys very little. Do not run it on a shared or multi-user machine you do
not trust.

## 17. Troubleshooting

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

or reformat the drive to exFAT (see section 12). This was measured on the real
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
See section 15.

**Generation is slow.**
Expected on CPU. The development machine measured 13.2 tokens/second. A weaker
CPU will be slower. Reducing context does not make generation faster; it only
reduces memory use.

**"already running".**
The single-instance guard holds a bound loopback socket on port 47610 as its
mutex, rather than a lock file, because the OS releases a socket even after a
crash or an unplug. It writes `data/run/instance.json` with the live URL, so a
second launch just reopens the browser at the session already running.

### Filesystem findings on the actual test drive

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
   and sets `PENDRIVEAI_ROOT` back to the pendrive. Windows is unaffected,
   because `.exe` runs normally on FAT32.
2. **exFAT is the recommended fix.** It allows direct execution on Linux and
   removes the 4 GiB per-file limit, while staying readable on Windows and macOS.
   Commands are in section 12. Reformatting erases the drive, so confirm the
   device with `lsblk` first.
3. **Symlinks must be flattened at packaging time.** Neither FAT32 nor exFAT
   stores symlinks, so the packaging script replaces the llama.cpp symlinks
   (`libggml-base.so -> libggml-base.so.0.20.2` and friends) with real files
   named after the SONAME the binary actually loads.
4. **Never run `npm install` on the drive.** It needs about 30,000 small files
   and symlinks. Build caches belong on local disk.

## 18. Known limitations

- **Windows launcher is not built and not tested here.** No mingw-w64 and no
  MSVC toolchain on the build machine. `StartAI.bat` is shipped as a
  zero-compile fallback and is also untested.
- **`StartAI.bat` has no single-instance guard, no RAM gate, no log rotation
  and no portable chat history.** See section 10 for the full list.
- **macOS is not supported in v1.** No runtime is shipped for it, and the memory
  probe returns unknown.
- **No GPU acceleration.** A CPU-only build was chosen deliberately, for
  portability across unknown machines and for size.
- **One model only.** There is no model picker in v1.
- **No SPA deep links.** llama.cpp's static handler returns 404 for unknown
  paths, so the UI is single-route on purpose.
- **No syntax highlighting.** Omitted deliberately to keep the bundle small.
- **No authentication on the loopback ports.** Any process running as your user
  on the same machine can reach them.
- **Windows shutdown is not graceful.** It uses `TerminateProcess`.
- **No gzip on static assets.** llama.cpp's static serving does not compress, so
  first paint is limited by drive read speed.
- **iOS and iPadOS are unsupported**, and cannot be supported from a pendrive.
  See section 5.
- **ARM platforms were never tested** and no ARM runtime is shipped.
- **Long multi-hour sessions and concurrent multi-user access were never tested.**

---

## Licence

MIT. See [`LICENSE`](LICENSE).

The bundled model, Qwen3-4B-Instruct-2507, is Apache-2.0 and is not included in
this repository. llama.cpp is distributed under its own licence by
`ggml-org/llama.cpp`.
