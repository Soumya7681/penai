#!/usr/bin/env bash
#
# build-windows-cross.sh - cross-compile StartAI.exe for Windows from Linux.
#
# PREREQUISITES (this script never installs anything itself):
#
#   sudo apt install mingw-w64
#   rustup target add x86_64-pc-windows-gnu
#
# The first gives you the x86_64-w64-mingw32-gcc linker, the second gives cargo
# the Windows GNU standard library. Both are required; the script checks for
# them and prints these exact commands if either is missing.
#
# IMPORTANT: a cross-compiled binary produced here has NOT been run on real
# Windows. It links against the MinGW-w64 runtime rather than MSVC, so it is a
# best-effort artifact. Test it on an actual Windows machine before shipping a
# drive, or build natively with scripts\build-windows.ps1 on Windows. The
# release also contains StartAI.bat, which needs no compiler at all.
#
# Usage:
#   scripts/build-windows-cross.sh [--skip-web] [--model <path>] [--version <str>]
#                                  [--out <dir>] [--force]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

TARGET_TRIPLE="x86_64-pc-windows-gnu"
MINGW_CC="x86_64-w64-mingw32-gcc"
SKIP_WEB=0
PKG_ARGS=()

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<USAGE
Usage: scripts/build-windows-cross.sh [options]

  --skip-web        Do not rebuild web/dist (reuse whatever is there)
  --model <path>    Passed through to package.sh (copied in as model.gguf)
  --version <str>   Passed through to package.sh
  --out <dir>       Passed through to package.sh (default: ${ROOT}/release)
  --force           Passed through to package.sh (overwrite the release dir)
  -h, --help        Show this help
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-web) SKIP_WEB=1; shift ;;
    --model) [ "$#" -ge 2 ] || die "--model needs a path"; PKG_ARGS+=(--model "$2"); shift 2 ;;
    --version) [ "$#" -ge 2 ] || die "--version needs a value"; PKG_ARGS+=(--version "$2"); shift 2 ;;
    --out) [ "$#" -ge 2 ] || die "--out needs a directory"; PKG_ARGS+=(--out "$2"); shift 2 ;;
    --force) PKG_ARGS+=(--force); shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

say "PendriveAI Windows cross-build (from Linux)"
say "  repo root: $ROOT"
say "  target:    $TARGET_TRIPLE"

# ------------------------------------------------------- prerequisite check ---
step "Checking cross-compilation prerequisites"
MISSING=0

if have cargo; then
  say "cargo: $(command -v cargo)"
else
  warn "cargo not found. Install the Rust toolchain:
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
  MISSING=1
fi

if have "$MINGW_CC"; then
  say "$MINGW_CC: $(command -v "$MINGW_CC")"
else
  warn "$MINGW_CC not found (the Windows linker)."
  say  "    Install it with exactly this command:"
  say  "      sudo apt install mingw-w64"
  say  "    (Fedora: sudo dnf install mingw64-gcc, Arch: sudo pacman -S mingw-w64-gcc)"
  MISSING=1
fi

TARGET_INSTALLED=0
if have rustup; then
  if rustup target list --installed 2>/dev/null | grep -qx "$TARGET_TRIPLE"; then
    TARGET_INSTALLED=1
  fi
elif have rustc; then
  # No rustup (distro-packaged Rust): look for the target's std in the sysroot.
  if [ -d "$(rustc --print sysroot)/lib/rustlib/$TARGET_TRIPLE" ]; then
    TARGET_INSTALLED=1
  fi
fi

if [ "$TARGET_INSTALLED" -eq 1 ]; then
  say "rust target $TARGET_TRIPLE: installed"
else
  warn "the Rust target $TARGET_TRIPLE is not installed."
  say  "    Install it with exactly this command:"
  say  "      rustup target add $TARGET_TRIPLE"
  say  "    If your Rust came from the distribution instead of rustup, install"
  say  "    rustup (https://rustup.rs) or the distro's rust-std for that target."
  MISSING=1
fi

if [ "$MISSING" -ne 0 ]; then
  say ""
  die "cross-compilation prerequisites are missing. Nothing was installed and
    nothing was built. Run the two commands above, then re-run this script:
      sudo apt install mingw-w64
      rustup target add $TARGET_TRIPLE
    Alternatively build natively on Windows with scripts\\build-windows.ps1, or
    ship the release with StartAI.bat only (no compiler needed)."
fi

# --------------------------------------------------------- build directories ---
SCRATCH_ROOT="${PENDRIVEAI_SCRATCH_DIR:-${TMPDIR:-/tmp}/pendriveai-build}"
if [ -n "${PENDRIVEAI_CARGO_TARGET_DIR:-}" ]; then
  TARGET_DIR="$PENDRIVEAI_CARGO_TARGET_DIR"
elif [ -n "${CARGO_TARGET_DIR:-}" ]; then
  TARGET_DIR="$CARGO_TARGET_DIR"
else
  TARGET_DIR="$SCRATCH_ROOT/cargo"
fi
mkdir -p "$TARGET_DIR" || die "cannot create the build directory: $TARGET_DIR"
export CARGO_TARGET_DIR="$TARGET_DIR"
say ""
say "cargo target dir: $CARGO_TARGET_DIR"
say "  (kept off the repo filesystem: a FAT32/exFAT USB drive cannot host a"
say "   Rust build cache. Override with PENDRIVEAI_CARGO_TARGET_DIR.)"

# ---------------------------------------------------------------- build -------
MANIFEST="$ROOT/launcher/Cargo.toml"
[ -f "$MANIFEST" ] || die "launcher manifest not found: $MANIFEST"

step "Cross-compiling the launcher"
say "Note: 'cargo test' is NOT run here. Windows test binaries cannot execute on"
say "      Linux. Run scripts/build-linux.sh to exercise the test suite natively."
cargo build --release --target "$TARGET_TRIPLE" --manifest-path "$MANIFEST" \
  || die "cross build failed.
    The usual causes are a missing mingw-w64 (linker errors mentioning
    ld: cannot find -l...) or a stale target install. Try:
      rustup target add $TARGET_TRIPLE
      sudo apt install mingw-w64"

EXE="$CARGO_TARGET_DIR/$TARGET_TRIPLE/release/StartAI.exe"
[ -f "$EXE" ] || die "the build reported success but $EXE does not exist.
    The [[bin]] name in launcher/Cargo.toml must stay 'StartAI'."
say "built: $EXE ($(du -h "$EXE" | cut -f1))"
if have file; then
  say "file:  $(file -b "$EXE")"
fi

# ------------------------------------------------------------ web + runtime ---
# The web build is platform independent: the same web/dist is served by
# llama-server on Linux and Windows alike. This mirrors the FAT32 handling in
# build-linux.sh: --no-bin-links when the repo filesystem has no symlinks, and
# a scratch build when node_modules cannot be created there at all.
build_web() {
  local -a flags=()
  local probe="$ROOT/web/.pendriveai-symlink-test.$$"
  rm -f "$probe" 2>/dev/null || true
  if ln -s . "$probe" 2>/dev/null; then
    rm -f "$probe" 2>/dev/null || true
    say "symlink test in $ROOT/web: OK, running npm normally."
  else
    rm -f "$probe" 2>/dev/null || true
    say "symlink test in $ROOT/web: FAILED (FAT32/exFAT), adding --no-bin-links."
    flags+=(--no-bin-links)
  fi

  local nm_probe="$ROOT/web/node_modules/.pendriveai-write-test.$$"
  if mkdir -p "$(dirname "$nm_probe")" 2>/dev/null && : > "$nm_probe" 2>/dev/null; then
    rm -f "$nm_probe" 2>/dev/null || true
    if [ -f "$ROOT/web/package-lock.json" ]; then
      ( cd "$ROOT/web" && npm ci ${flags[@]+"${flags[@]}"} ) && ( cd "$ROOT/web" && npm run build ) && return 0
    else
      warn "no package-lock.json in $ROOT/web; using 'npm install' (versions are not pinned)."
      ( cd "$ROOT/web" && npm install ${flags[@]+"${flags[@]}"} ) && ( cd "$ROOT/web" && npm run build ) && return 0
    fi
    warn "the in-place npm build failed on the repo filesystem; retrying in scratch."
  else
    say "node_modules cannot be created under $ROOT/web; building in scratch instead."
  fi

  # Scratch fallback: build outside the repo, copy dist/ back.
  local scratch="$SCRATCH_ROOT/web"
  say "building the UI in $scratch"
  rm -rf "$scratch"; mkdir -p "$scratch"
  if have rsync; then
    rsync -rLt --exclude node_modules --exclude dist "$ROOT/web"/ "$scratch"/ || return 1
  else
    ( cd "$ROOT/web" && tar -cf - --exclude=node_modules --exclude=dist . ) | ( cd "$scratch" && tar -xf - ) || return 1
  fi
  if [ -f "$scratch/package-lock.json" ]; then
    ( cd "$scratch" && npm ci ) || return 1
  else
    ( cd "$scratch" && npm install ) || return 1
  fi
  ( cd "$scratch" && npm run build ) || return 1
  [ -d "$scratch/dist" ] || return 1
  rm -rf "$ROOT/web/dist"; mkdir -p "$ROOT/web/dist"
  if have rsync; then
    rsync -rLt "$scratch/dist"/ "$ROOT/web/dist"/ || return 1
  else
    cp -RL "$scratch/dist"/. "$ROOT/web/dist"/ || return 1
  fi
  say "copied $scratch/dist -> $ROOT/web/dist"
}

if [ "$SKIP_WEB" -eq 1 ]; then
  step "Web UI"
  warn "skipping the web build (--skip-web)"
  [ -f "$ROOT/web/dist/index.html" ] || die "--skip-web was given but $ROOT/web/dist/index.html
    does not exist, so there is nothing to package."
  say "reusing existing $ROOT/web/dist"
else
  step "Building the web UI"
  if ! have npm; then
    die "npm not found and --skip-web was not given.
    Install Node.js 18+ (sudo apt install nodejs npm, or use nvm), or build the
    UI once elsewhere and re-run with --skip-web."
  fi
  build_web || die "web build failed. Build it manually in $ROOT/web with
    'npm ci && npm run build' (add --no-bin-links on a FAT32/exFAT drive)."
  [ -f "$ROOT/web/dist/index.html" ] || die "web build finished but $ROOT/web/dist/index.html is missing."
  say "web build ready: $ROOT/web/dist ($(du -sh "$ROOT/web/dist" | cut -f1))"
fi

step "Checking the Windows llama.cpp runtime"
if [ -f "$ROOT/runtime/windows/llama-server.exe" ]; then
  say "found $ROOT/runtime/windows/llama-server.exe"
  [ -f "$ROOT/runtime/windows/RUNTIME_VERSION.txt" ] && sed 's/^/  /' "$ROOT/runtime/windows/RUNTIME_VERSION.txt"
else
  die "runtime/windows/llama-server.exe is missing.
    Fix: run  scripts/fetch-runtime.sh --platform windows
    (it downloads the llama.cpp b10549 Windows CPU build and stages the
    minimal DLL set, and it works fine from Linux)."
fi

# --------------------------------------------------------------- package ------
step "Packaging the Windows release"
"$SCRIPT_DIR/package.sh" --platform windows ${PKG_ARGS[@]+"${PKG_ARGS[@]}"}

step "Windows cross-build complete"
say "Release: ${ROOT}/release/windows/PendriveAI (unless --out changed it)"
say ""
say "READ THIS: StartAI.exe was CROSS-COMPILED on Linux with MinGW-w64 and has"
say "NOT been tested on real Windows hardware. Before handing the drive to"
say "anyone, run StartAI.exe once on an actual Windows machine. If it misbehaves,"
say "StartAI.bat in the same folder is a no-compiler fallback that does the same"
say "job with cmd.exe and PowerShell."
