# Model setup

This directory holds the GGUF model that PenAI runs. **The model file is not
in this repository and never will be.** You download it once, verify it, and copy
it to the pendrive.

Everything on this page is automated by `models/download-model.sh` (Linux and
macOS) and `models/download-model.ps1` (Windows). The manual steps are documented
so you can do it by hand, or verify what the scripts did.

---

## The model

PenAI v1 ships exactly one model.

| Field | Value |
|---|---|
| Name | **Qwen3-4B-Instruct-2507** |
| Quantisation | **Q4_K_M** (GGUF) |
| Hugging Face repo | `unsloth/Qwen3-4B-Instruct-2507-GGUF` |
| File in the repo | `Qwen3-4B-Instruct-2507-Q4_K_M.gguf` |
| Exact size | **2,497,281,120 bytes** (2.33 GiB / 2.50 GB) |
| SHA-256 | `3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597` |
| Licence | **Apache-2.0** |
| Gated? | No. No login and no access token needed |
| Filename the launcher expects | **`models/model.gguf`** |

The licence was verified on the upstream `Qwen/Qwen3-4B-Instruct-2507` repository.

### Why this model

- **Apache-2.0**, so commercial use is allowed. This ruled out several otherwise
  attractive models with restrictive licences.
- **4B parameters** is the sweet spot for CPU inference: large enough for useful
  chat and programming help, small enough to answer at a usable speed without a
  GPU.
- **Q4_K_M** fits an 8 GB drive with room to spare, and stays under the FAT32
  4 GiB per-file limit.
- It is the **non-thinking "Instruct" variant**, so it answers directly instead
  of emitting long reasoning traces before the answer.

### Architecture facts used for the RAM estimate

The launcher sizes the KV cache from these values rather than guessing:

- 36 layers
- 8 KV heads (GQA)
- head_dim 128

So the f16 KV cache is `2 * 36 * 8 * 128 * 2 = 147,456` bytes per token, which is
144 KiB per token. At a context of 4096 that is about **0.6 GiB** of KV cache on
top of the model weights.

---

## Direct download URL

```
https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf
```

---

## Automated download (recommended)

**Linux and macOS:**

```bash
cd models
./download-model.sh
```

**Windows (PowerShell):**

```powershell
cd models
powershell -File download-model.ps1
```

Each script downloads the file, verifies the SHA-256, and renames it to
`model.gguf`. If you use them, you can skip the rest of this page.

---

## Manual download

### Linux and macOS, with curl

```bash
cd models
curl -L -o Qwen3-4B-Instruct-2507-Q4_K_M.gguf \
  https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf
```

`-L` matters: Hugging Face redirects to a CDN, and without it you will download a
small redirect page instead of a 2.50 GB model.

To resume an interrupted download, add `-C -`:

```bash
curl -L -C - -o Qwen3-4B-Instruct-2507-Q4_K_M.gguf \
  https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf
```

### Linux and macOS, with wget

```bash
cd models
wget -O Qwen3-4B-Instruct-2507-Q4_K_M.gguf \
  https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf
```

To resume, add `-c`:

```bash
wget -c -O Qwen3-4B-Instruct-2507-Q4_K_M.gguf \
  https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf
```

### Windows, with PowerShell `Invoke-WebRequest`

```powershell
cd models
Invoke-WebRequest `
  -Uri "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf" `
  -OutFile "Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
```

### Windows, with `curl.exe`

`curl.exe` ships with current Windows and is usually much faster than
`Invoke-WebRequest` for large files:

```powershell
cd models
curl.exe -L -o Qwen3-4B-Instruct-2507-Q4_K_M.gguf ^
  https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf
```

Use `curl.exe`, not `curl`, in PowerShell. Bare `curl` may resolve to an alias
for `Invoke-WebRequest`, which does not accept these flags.

---

## Verify the checksum

Always verify. A truncated GGUF fails in a confusing way at load time, and the
launcher's own check can only tell you the file "looks truncated", not why.

Expected SHA-256:

```
3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597
```

Expected size: `2,497,281,120` bytes.

### Linux, with `sha256sum -c`

```bash
cd models
echo "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597  Qwen3-4B-Instruct-2507-Q4_K_M.gguf" > model.sha256
sha256sum -c model.sha256
```

Expected output:

```
Qwen3-4B-Instruct-2507-Q4_K_M.gguf: OK
```

Or print the hash and compare it yourself:

```bash
sha256sum Qwen3-4B-Instruct-2507-Q4_K_M.gguf
```

### macOS

```bash
shasum -a 256 Qwen3-4B-Instruct-2507-Q4_K_M.gguf
```

### Windows, with PowerShell `Get-FileHash`

```powershell
Get-FileHash -Algorithm SHA256 .\Qwen3-4B-Instruct-2507-Q4_K_M.gguf
```

Compare the `Hash` column against the value above. The comparison is
case-insensitive: PowerShell prints uppercase hex, and the value above is
lowercase.

To have PowerShell do the comparison for you:

```powershell
$expected = "3605803B982CB64AEAD44F6C1B2AE36E3ACDB41D8E46C8A94C6533BC4C67E597"
$actual = (Get-FileHash -Algorithm SHA256 .\Qwen3-4B-Instruct-2507-Q4_K_M.gguf).Hash
if ($actual -eq $expected) { "OK" } else { "MISMATCH" }
```

### Check the size too

```bash
# Linux
stat -c %s Qwen3-4B-Instruct-2507-Q4_K_M.gguf     # expect 2497281120
```

```powershell
# Windows
(Get-Item .\Qwen3-4B-Instruct-2507-Q4_K_M.gguf).Length   # expect 2497281120
```

If the size is wrong, the download was interrupted. Re-download rather than
trying to repair it.

---

## Rename it to `model.gguf`

The launcher looks for `models/model.gguf` by default.

```bash
# Linux and macOS
mv Qwen3-4B-Instruct-2507-Q4_K_M.gguf model.gguf
```

```powershell
# Windows
Rename-Item Qwen3-4B-Instruct-2507-Q4_K_M.gguf model.gguf
```

Model resolution order used by the launcher:

1. `models/model.gguf`, the conventional name.
2. Any single `.gguf` file in `models/`. If there is more than one, the largest
   wins.
3. An explicit `model.file` entry in the config.

So renaming is a convenience rather than a hard requirement, but it keeps the
behaviour unambiguous, and it is what the docs and the troubleshooting steps
assume.

---

## Which models can I use?

PenAI v1 ships exactly one model, and **the launcher loads exactly one model
at a time**. There is no model picker in the UI, and no way to switch models
without restarting. Swapping means replacing `models/model.gguf`, or setting
`model.file` in `config/config.json`, and restarting the launcher.

### Hard requirements for any replacement

A candidate model has to satisfy all five of these.

| # | Requirement | Why |
|---|---|---|
| a | **GGUF format** | llama.cpp does not load `.safetensors`, `.bin` or PyTorch checkpoints. It must be a `.gguf` file |
| b | **An architecture supported by the packaged llama.cpp build `b10549`** | A model whose architecture is newer than the bundled engine will simply fail to load. The engine on the drive is fixed at `b10549` |
| c | **It must fit in RAM alongside the KV cache** | See the sizing rule below. The launcher checks this and will reduce the context or refuse |
| d | **On FAT32, the single file must stay under 4 GiB** | A FAT32 filesystem limit, not a PenAI one. exFAT removes it |
| e | **For chat use it must be instruct or chat-tuned** | A base or completion model will not follow a conversation. It will just continue your text, which looks like a broken chat UI but is the model behaving correctly |

### What we actually tested

**Only `Qwen3-4B-Instruct-2507-Q4_K_M` has been tested by us.** Measured on the
development machine: 13.2 tok/s generation, 50.3 tok/s prompt processing, and a 6
second load.

Everything else on this page **should work, but was not tested here.** Treat the
tables below as a starting point for your own testing, not as a compatibility
guarantee.

### Same family, different size or quality

All Apache-2.0. These live in `unsloth/Qwen3-4B-Instruct-2507-GGUF`, or in the
matching `unsloth/Qwen3-<size>-GGUF` repository for the smaller models.

| Model | Params | Quant | Approx size | Licence | Notes |
|---|---|---|---|---|---|
| **Qwen3-4B-Instruct-2507** | 4B | **Q4_K_M** | **2.50 GB** | Apache-2.0 | **The shipped default.** Best balance for 8 GB drives, and the only tested configuration |
| Qwen3-4B-Instruct-2507 | 4B | Q3_K_M | 2.08 GB | Apache-2.0 | For machines with about 4 GB RAM; some quality loss |
| Qwen3-4B-Instruct-2507 | 4B | Q2_K | 1.67 GB | Apache-2.0 | Last resort for very low RAM; noticeably worse |
| Qwen3-4B-Instruct-2507 | 4B | Q5_K_M | 2.89 GB | Apache-2.0 | Better quality if you have 8 GB+ RAM and drive space |
| Qwen3-4B-Instruct-2507 | 4B | Q6_K | 3.31 GB | Apache-2.0 | Higher quality, slower on CPU |
| Qwen3-4B-Instruct-2507 | 4B | Q8_0 | 4.28 GB | Apache-2.0 | **EXCEEDS the FAT32 4 GiB single-file limit. exFAT only** |
| Qwen3-1.7B | 1.7B | Q4_K_M | see repo | Apache-2.0 | Much faster on weak CPUs, clearly weaker at reasoning and code |
| Qwen3-0.6B | 0.6B | Q4_0 | 382 MB | Apache-2.0 | Only useful for testing that the plumbing works; too weak for real use |

Two things worth knowing about **Qwen3-0.6B**:

- We did use it during development for **fast integration testing**, because it
  loads in a fraction of the time of the 4B model. It is a good choice when you
  want to confirm that the launcher, the port selection and the streaming path
  all work, without waiting on a 2.50 GB load.
- It is a **thinking** variant, so it emits `reasoning_content` in addition to
  `content`. The UI renders that in a separate collapsible block, so the reasoning
  trace does not contaminate the answer. This is the opposite of the shipped
  Instruct model, which answers directly.

> ### FAT32 4 GiB warning
>
> FAT32 cannot store a single file larger than 4 GiB. **Q8_0 at 4.28 GB will not
> copy onto a FAT32 pendrive**, and the copy will fail partway through rather
> than being refused up front. If you want Q8_0, format the drive as exFAT
> first. See section 12.1 of the top-level [`README.md`](../README.md).

### Other families worth knowing about

None of these were tested here, and each has a licence note that matters more
than usual, because a pendrive tool is easy to hand to someone else.

| Model | Params | Quant | Approx size | Licence | Notes |
|---|---|---|---|---|---|
| Qwen2.5-Coder-3B-Instruct | 3B | GGUF, your choice | see repo | **Check the specific repo.** Some Qwen2.5 sizes are released under a Qwen research licence rather than Apache-2.0, so verify before commercial use | Stronger at code than at general chat |
| Llama-3.2-3B-Instruct | 3B | GGUF, your choice | see repo | Llama 3.2 Community Licence. It carries acceptable-use terms plus naming and attribution requirements, rather than being a plain open-source licence | Capable general model |
| Gemma-3-4B-IT | 4B | GGUF, your choice | see repo | Gemma Terms of Use, which carry usage restrictions | Capable general model |
| Phi-4-mini-instruct | 3.8B | GGUF, your choice | see repo | MIT | Strong at reasoning for its size |
| SmolLM3-3B | 3B | GGUF, your choice | see repo | Apache-2.0 | Small and fast |

> ### Licence warning
>
> We verified the licence only for **Qwen3-4B-Instruct-2507**: Apache-2.0,
> confirmed on the upstream `Qwen/Qwen3-4B-Instruct-2507` repository.
>
> For every other model, **check the licence on the actual repository you
> download from.** Quantised re-uploads sometimes state a different licence from
> the original weights, so the licence shown on a GGUF repo is not automatically
> the licence of the model it was built from.

### How to swap the model

1. **Download the replacement `.gguf`.**
2. **Put it in `models/` on the drive.**
3. **Either rename it to `model.gguf`**, or set
   `"model": { "file": "your-file.gguf" }` in `config/config.json`.
4. **If it is much bigger than the old one, lower `llama.ctxSize`** (or pass
   `--ctx`) so that it still fits in RAM.
5. **Restart the launcher.** The status bar in the UI will show the new model name
   and the engine's reported context size.

If several `.gguf` files are present and `model.file` is empty, the launcher picks
the **largest** one, with ties broken by filename. That makes the choice
deterministic rather than dependent on directory order, so the same drive behaves
the same way on every computer.

Verify the checksum of whatever you download against the value published on its
own repository page. Nothing here can check a file it has never seen.

### RAM sizing rule of thumb

Needed RAM is roughly:

```
model file size
  + about 144 KiB per context token   (for a 4B-class model)
  + about 400 MiB of buffers
```

For a 4B-class model that means the KV cache costs about **0.6 GiB at ctx 4096**
and about **1.2 GiB at ctx 8192**. So the shipped Q4_K_M at ctx 4096 needs
roughly 2.50 GB of weights plus 0.6 GiB of KV cache plus 400 MiB of buffers.

The launcher computes this itself before starting anything. It warns when the fit
is tight and **reduces the context automatically** rather than letting the machine
thrash, and it refuses outright when the model cannot fit at all unless you pass
`--force`. A bigger quantisation therefore does not just cost drive space; it may
silently cost you context.

### Not supported in v1

- **Multimodal and vision models.** The `mtmd` library is bundled with the
  llama.cpp release, but the launcher does not wire up an image path, so there is
  no way to send an image to the model.
- **Embedding-only models.** The UI is a chat client and expects
  `/v1/chat/completions`.
- **GPU-accelerated builds.** The shipped runtime is CPU-only by choice, for
  portability across unknown machines and for size.

---

## Never commit the model

`.gitignore` excludes `*.gguf`, `*.gguf.part`, `*.bin`, `*.safetensors` and
`models/*.gguf`.

Do not work around this. A 2.50 GB blob in git history is effectively permanent,
it makes every clone enormous, and most hosts will reject the push anyway. The
model is a download step, not a source artefact.

---

## Where the model ends up

On the pendrive:

```
PenAI/
└── models/
    ├── model.gguf      2.50 GB
    └── README.md
```

Copying it is the slow part of deployment. The measured write speed on the test
pendrive was 3.4 MB/s, so 2.50 GB can take over 10 minutes. Let it finish, and
run `sync` (Linux) or use "Safely Remove Hardware" (Windows) before unplugging.
