# Requirements

Platforms, hardware, and the storage budget for an 8 GB drive.

[← All documentation](README.md) · [Project home](../README.md)

---

## Supported platforms

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

## Hardware requirements

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
(see [Starting PendriveAI](USAGE.md#starting-pendriveai)).

## 8 GB storage requirements

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
