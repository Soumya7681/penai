# Status

What is verified, what is built but untested, and what is not built at all.

[← All documentation](README.md) · [Project home](../README.md)

---

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

**Cross-built but not run:**

- `StartAI.exe`. mingw-w64 (`x86_64-w64-mingw32-gcc` 13-win32) and the Rust
  `x86_64-pc-windows-gnu` target are installed on the build machine, so
  `build-all.sh` produces the real launcher rather than falling back to
  `StartAI.bat`. Nothing has executed it on Windows yet. See
  [Building the Windows release](BUILD.md#building-the-windows-release).

**Not tested:**

- Windows end to end, and `StartAI.bat`.
- macOS (no runtime is shipped for it in v1).
- The `StartAI.sh` FAT32 staging bootstrap end to end.
- GPU builds, any ARM platform, long multi-hour sessions, concurrent multi-user access.

Full detail is in [Testing](TESTING.md).
