# Model setup

Choosing, downloading and verifying the GGUF model the drive carries.

[← All documentation](README.md) · [Project home](../README.md)

---

PenAI v1 ships exactly one model.

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
[`models/README.md`](../models/README.md).

The model is **never committed to git**. `.gitignore` excludes `*.gguf`.

**Before you copy the model onto a pendrive, format the drive.** The choice of
filesystem decides whether the model will even fit: FAT32 caps a single file at
4 GiB, so Q4_K_M at 2.50 GB is fine but Q8_0 at 4.28 GB cannot be stored at all.
exFAT removes that limit and also lets the launcher execute directly on Linux.
Step-by-step instructions for Linux, Windows and macOS are in
[[Format the pendrive first](PENDRIVE.md#format-the-pendrive-first-do-this-before-anything-else), Format the pendrive first](#format-the-pendrive-first-do-this-before-anything-else).

## Which models can I use?

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
6 second load, on the development machine described in [Starting PenAI](USAGE.md#starting-penai). Everything
else listed below **should work, but was not tested here**.

## Same family, different size or quality

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

## Other families worth knowing about

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

## How to swap the model

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

## RAM sizing rule of thumb

Needed RAM is roughly:

```
model file size
  + about 144 KiB per context token   (for a 4B-class model)
  + about 400 MiB of buffers
```

So for a 4B-class model, the KV cache costs about **0.6 GiB at ctx 4096** and
about **1.2 GiB at ctx 8192**.

The launcher computes this itself, warns when it is tight, and reduces the
context automatically rather than letting the machine thrash. See [Starting PenAI](USAGE.md#starting-penai).

## Not supported in v1

- **Multimodal and vision models.** The `mtmd` library is bundled with the
  llama.cpp release, but the launcher does not wire up an image path, so there is
  no way to send an image.
- **Embedding-only models.** The UI is a chat client and expects
  `/v1/chat/completions`.
- **GPU-accelerated builds.** The shipped runtime is CPU-only by choice, for
  portability across unknown machines and for size.
