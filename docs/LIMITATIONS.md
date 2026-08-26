# Known limitations

What this version does not do.

[← All documentation](README.md) · [Project home](../README.md)

---

- **Windows launcher is not built and not tested here.** No mingw-w64 and no
  MSVC toolchain on the build machine. `StartAI.bat` is shipped as a
  zero-compile fallback and is also untested.
- **`StartAI.bat` has no single-instance guard, no RAM gate, no log rotation
  and no portable chat history.** See [Building the Windows release](BUILD.md#building-the-windows-release) for the full list.
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
  See [Supported platforms](REQUIREMENTS.md#supported-platforms).
- **ARM platforms were never tested** and no ARM runtime is shipped.
- **Long multi-hour sessions and concurrent multi-user access were never tested.**
