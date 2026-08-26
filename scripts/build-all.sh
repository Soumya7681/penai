#!/usr/bin/env bash
#
# build-all.sh - one command that turns a clean checkout into a finished,
#                ready-to-run PendriveAI drive.
#
# This is the script to run. Everything else under scripts/ is a step that this
# one calls in the right order:
#
#   fetch-runtime.sh -> npm run build -> cargo build (linux)
#                    -> cargo build (windows, if mingw-w64 is present)
#                    -> download-model.sh -> package.sh -> deploy-to-pendrive.sh
#
# It is resumable. Every step checks whether its output already exists and skips
# itself if so, which matters because the model download alone is 2.5 GB. Run it
# again after an interruption and it picks up where it stopped.
#
# It never uses sudo, and it never formats anything. If a prerequisite needs
# root, it stops and prints the exact command for you to run.
#
# Usage:
#   scripts/build-all.sh --target /media/you/PENDRIVEAI
#   scripts/build-all.sh --target /media/you/PENDRIVEAI --model ~/model.gguf
#   scripts/build-all.sh                       # build only, do not copy anywhere
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

TARGET=""
MODEL=""
PLATFORM="both"
MODEL_CACHE="${PENDRIVEAI_MODEL_CACHE:-$HOME/.cache/pendriveai}"
SKIP_MODEL=0
SKIP_TESTS=0
CLEAN=0
ASSUME_YES=0

# The reference model. Kept in step with scripts/package.sh and models/README.md.
MODEL_BYTES=2497281120
MODEL_SHA256="3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597"

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
skip() { printf '    (skipped: %s)\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<USAGE
Usage: scripts/build-all.sh [options]

  --target <dir>     Mount point of the pendrive. Given this, the finished
                     release is copied onto the drive as the last step.
                     Omit it to build into release/ and copy nothing.
  --model <path>     Use this .gguf instead of downloading one.
  --platform linux|windows|both     Default: both.
  --skip-model       Package without a model. The drive will not run until one
                     is added to models/ later.
  --skip-tests       Do not run cargo test.
  --clean            Rebuild everything, ignoring what is already built.
  --yes              Do not ask before writing to the drive.
  -h, --help         Show this help

Find your mount point with:  lsblk -o NAME,LABEL,FSTYPE,SIZE,MOUNTPOINT
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)   [ "$#" -ge 2 ] || die "--target needs a directory"; TARGET="$2"; shift 2 ;;
    --target=*) TARGET="${1#*=}"; shift ;;
    --model)    [ "$#" -ge 2 ] || die "--model needs a path"; MODEL="$2"; shift 2 ;;
    --model=*)  MODEL="${1#*=}"; shift ;;
    --platform) [ "$#" -ge 2 ] || die "--platform needs a value"; PLATFORM="$2"; shift 2 ;;
    --platform=*) PLATFORM="${1#*=}"; shift ;;
    --skip-model) SKIP_MODEL=1; shift ;;
    --skip-tests) SKIP_TESTS=1; shift ;;
    --clean)    CLEAN=1; shift ;;
    --yes|-y)   ASSUME_YES=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

case "$PLATFORM" in
  linux|windows|both) ;;
  *) die "--platform must be linux, windows or both (got '$PLATFORM')" ;;
esac

want_linux()   { [ "$PLATFORM" = "linux" ]   || [ "$PLATFORM" = "both" ]; }
want_windows() { [ "$PLATFORM" = "windows" ] || [ "$PLATFORM" = "both" ]; }

# The build caches must never live on the drive: a Rust target/ tree and
# node_modules/ need hundreds of thousands of small files, hard links and
# symlinks, none of which FAT32 or exFAT handle well or at all.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-${TMPDIR:-/tmp}/pendriveai-build/cargo}"

say "PendriveAI one-shot build"
say "  repo:        $ROOT"
say "  platform:    $PLATFORM"
say "  build cache: $CARGO_TARGET_DIR"
say "  target:      ${TARGET:-<none: build only>}"

# --------------------------------------------------------------- 0. tools ----
step "Checking tools"

missing_apt=()
have cargo || die "cargo not found. Install Rust from https://rustup.rs and re-run."
have npm   || missing_apt+=("nodejs npm")
have curl  || have wget || missing_apt+=("curl")
have tar   || missing_apt+=("tar")
have unzip || missing_apt+=("unzip")

if [ "${#missing_apt[@]}" -gt 0 ]; then
  die "missing tools. Install them and re-run:
    sudo apt install ${missing_apt[*]}"
fi
say "    cargo, npm and the archive tools are present"

# The Windows launcher is optional. Without a cross-compiler the release still
# works through StartAI.bat, so this is a warning and not a failure.
BUILD_WINDOWS_EXE=0
if want_windows; then
  if have x86_64-w64-mingw32-gcc && rustup target list --installed 2>/dev/null | grep -q x86_64-pc-windows-gnu; then
    BUILD_WINDOWS_EXE=1
    say "    mingw-w64 and the Rust windows-gnu target are present: StartAI.exe will be built"
  else
    warn "no Windows cross-compiler, so StartAI.exe will NOT be built.
  The Windows half of the drive will still work by double-clicking StartAI.bat,
  which needs no compiler but has no RAM gate, single-instance guard, log
  rotation or portable chat history.
  To get the real launcher instead:
    sudo apt install mingw-w64
    rustup target add x86_64-pc-windows-gnu"
  fi
fi

# ------------------------------------------------------------- 1. runtime ----
step "llama.cpp runtime"

runtime_ok() {
  # runtime_ok <platform>
  local p="$1" probe="llama-server"
  [ "$p" = "windows" ] && probe="llama-server.exe"
  [ -f "$ROOT/runtime/$p/$probe" ]
}

fetch_linux=0
fetch_windows=0
want_linux   && ! runtime_ok linux   && fetch_linux=1
want_windows && ! runtime_ok windows && fetch_windows=1

need_fetch=""
if [ "$fetch_linux" -eq 1 ] && [ "$fetch_windows" -eq 1 ]; then
  need_fetch="both"
elif [ "$fetch_linux" -eq 1 ]; then
  need_fetch="linux"
elif [ "$fetch_windows" -eq 1 ]; then
  need_fetch="windows"
fi
[ "$CLEAN" -eq 1 ] && need_fetch="$PLATFORM"

if [ -n "$need_fetch" ]; then
  say "    fetching: $need_fetch  (about 45 MB per platform, cached in vendor/)"
  fetch_args=(--platform "$need_fetch")
  [ "$CLEAN" -eq 1 ] && fetch_args+=(--force)
  "$SCRIPT_DIR/fetch-runtime.sh" "${fetch_args[@]}"
else
  skip "runtime already staged under runtime/"
fi

want_linux   && ! runtime_ok linux   && die "runtime/linux/llama-server is still missing after fetch-runtime.sh."
want_windows && ! runtime_ok windows && die "runtime/windows/llama-server.exe is still missing after fetch-runtime.sh."

# ----------------------------------------------------------------- 2. web ----
step "Web UI"

# The web UI is the one part of the build that changes often, so this step does
# not just ask "does dist exist" -- it asks whether any source is newer than the
# bundle. Editing a component and re-running build-all.sh therefore rebuilds the
# UI and nothing else: the runtime stays staged, the model stays cached and
# cargo keeps its target directory.
web_stale() {
  local out="$ROOT/web/dist/index.html"
  [ -f "$out" ] || return 0
  local newer
  newer="$(find "$ROOT/web/src" "$ROOT/web/index.html" "$ROOT/web/package.json" \
    "$ROOT/web/vite.config.ts" "$ROOT/web/tsconfig.json" \
    -newer "$out" -print -quit 2>/dev/null)"
  [ -n "$newer" ]
}

if [ "$CLEAN" -eq 1 ]; then
  web_reason="--clean"
elif [ ! -f "$ROOT/web/dist/index.html" ]; then
  web_reason="no bundle yet"
elif web_stale; then
  web_reason="sources changed since the last build"
else
  web_reason=""
fi

if [ -n "$web_reason" ]; then
  say "    building web/dist with npm ($web_reason)"
  (
    cd "$ROOT/web"
    if [ -d node_modules ]; then npm run build; else npm install && npm run build; fi
  )
else
  skip "web/dist is up to date with web/src"
fi

[ -f "$ROOT/web/dist/index.html" ] || die "web/dist/index.html is missing after the build."

# ------------------------------------------------------------ 3. launcher ----
step "Rust launcher"

if [ "$SKIP_TESTS" -eq 0 ]; then
  say "    cargo test"
  ( cd "$ROOT/launcher" && cargo test --quiet )
else
  skip "tests disabled with --skip-tests"
fi

if want_linux; then
  if [ "$CLEAN" -eq 1 ] || [ ! -f "$CARGO_TARGET_DIR/release/StartAI" ]; then
    say "    cargo build --release  (Linux)"
    ( cd "$ROOT/launcher" && cargo build --release )
  else
    skip "StartAI already built"
  fi
fi

if [ "$BUILD_WINDOWS_EXE" -eq 1 ]; then
  win_out="$CARGO_TARGET_DIR/x86_64-pc-windows-gnu/release/StartAI.exe"
  if [ "$CLEAN" -eq 1 ] || [ ! -f "$win_out" ]; then
    say "    cargo build --release --target x86_64-pc-windows-gnu"
    ( cd "$ROOT/launcher" && cargo build --release --target x86_64-pc-windows-gnu )
  else
    skip "StartAI.exe already built"
  fi
fi

# --------------------------------------------------------------- 4. model ----
step "Model"

if [ "$SKIP_MODEL" -eq 1 ]; then
  skip "--skip-model given; the drive will not run until a .gguf is added to models/"
  MODEL=""
elif [ -n "$MODEL" ]; then
  [ -f "$MODEL" ] || die "--model points at something that is not a file: $MODEL"
  say "    using $MODEL ($(du -h "$MODEL" | cut -f1))"
else
  # Cached outside the repo so a --clean or a reformat never costs 2.5 GB again.
  mkdir -p "$MODEL_CACHE"
  MODEL="$MODEL_CACHE/model.gguf"
  if [ -f "$MODEL" ] && [ "$(wc -c < "$MODEL")" -eq "$MODEL_BYTES" ]; then
    skip "model already cached at $MODEL"
  else
    say "    downloading the reference model to $MODEL"
    say "    2.5 GB, resumable, Apache-2.0, no account needed"
    "$ROOT/models/download-model.sh" --dest "$MODEL"
  fi
fi

# Verify before spending minutes copying it to a slow drive. A truncated model
# is the single most common reason a finished drive does not start, and it is
# exactly what a half-finished download leaves behind.
if [ -n "$MODEL" ]; then
  actual_bytes="$(wc -c < "$MODEL")"
  if [ "$actual_bytes" -ne "$MODEL_BYTES" ]; then
    warn "model is $actual_bytes bytes, not the reference $MODEL_BYTES.
  That is fine for a different quantisation, but if you meant to use the
  reference model it is truncated. Delete it and re-run to download again."
  elif have sha256sum; then
    say "    verifying SHA-256 (reads the whole 2.5 GB, takes a minute)"
    actual_sha="$(sha256sum "$MODEL" | awk '{print $1}')"
    [ "$actual_sha" = "$MODEL_SHA256" ] \
      && say "    checksum OK" \
      || die "model checksum MISMATCH
  expected: $MODEL_SHA256
  actual:   $actual_sha
  The file is corrupt. Delete $MODEL and re-run to download it again."
  fi
fi

# ------------------------------------------------------------- 5. package ----
step "Assembling the release"

pkg_args=(--platform "$PLATFORM" --force)
[ -n "$MODEL" ] && pkg_args+=(--model "$MODEL")
"$SCRIPT_DIR/package.sh" "${pkg_args[@]}"

# -------------------------------------------------------------- 6. deploy ----
if [ -z "$TARGET" ]; then
  step "Done (build only)"
  say "The release is in $ROOT/release/. Copy it to a drive with:"
  say "  scripts/deploy-to-pendrive.sh --target /path/to/mountpoint"
  exit 0
fi

step "Copying to the drive"

[ -d "$TARGET" ] || die "--target is not a directory: $TARGET
    Find the mount point with:  lsblk -o NAME,LABEL,FSTYPE,SIZE,MOUNTPOINT"
[ -w "$TARGET" ] || die "--target is not writable: $TARGET
    If the drive went read-only, the filesystem has errors. Check with:
      findmnt -no OPTIONS $TARGET
    A drive mounted 'ro' after an I/O error needs reformatting, not remounting."

# exFAT is what makes ./StartAI runnable on Linux. FAT32 is mounted with
# showexec, which grants the execute bit only to .exe/.com/.bat, so a Linux
# user is forced through the sh StartAI.sh staging path instead.
fstype="$(findmnt -no FSTYPE "$TARGET" 2>/dev/null || true)"
case "$fstype" in
  exfat) say "    target is exFAT: ./StartAI will run directly on Linux" ;;
  vfat|msdos)
    warn "the target is FAT32, not exFAT.
  Everything will work, but Linux will refuse to execute ./StartAI directly and
  users must run 'sh StartAI.sh' from a terminal instead. Reformatting as exFAT
  removes that step. Windows is unaffected." ;;
  "") warn "could not determine the target filesystem." ;;
  *)  say "    target filesystem: $fstype" ;;
esac

deploy_args=(--target "$TARGET" --platform "$PLATFORM")
[ "$ASSUME_YES" -eq 1 ] && deploy_args+=(--yes)
"$SCRIPT_DIR/deploy-to-pendrive.sh" "${deploy_args[@]}"

step "Finished"
say "The drive is ready. To start it:"
say ""
if want_linux; then
  if [ "$fstype" = "exfat" ]; then
    say "  Linux:    cd $TARGET/PendriveAI && ./StartAI"
  else
    say "  Linux:    cd $TARGET/PendriveAI && sh StartAI.sh"
  fi
fi
if want_windows; then
  if [ "$BUILD_WINDOWS_EXE" -eq 1 ]; then
    say "  Windows:  double-click StartAI.exe"
  else
    say "  Windows:  double-click StartAI.bat"
  fi
fi
say ""
say "Run 'sync' and wait for it to return before unplugging."
