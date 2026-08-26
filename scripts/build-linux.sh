#!/usr/bin/env bash
#
# build-linux.sh - full Linux release build for PenAI.
#
# Steps: check tools -> build the Rust launcher -> run its tests -> build the
# React UI -> check the llama.cpp runtime is staged -> call scripts/package.sh.
#
# Why the build caches live outside the repo:
#   this repository is designed to sit ON the USB drive, and that drive is
#   usually FAT32 or exFAT. A Rust target/ directory and a node_modules/ tree
#   both need hundreds of thousands of small files, hard links and symlinks,
#   which FAT cannot do at all (symlinks) or does painfully slowly (small
#   files). So CARGO_TARGET_DIR defaults to a local scratch directory, and the
#   web build falls back to building in scratch and copying dist/ back.
#
# Usage:
#   scripts/build-linux.sh [--skip-tests] [--skip-web] [--skip-runtime-check]
#                          [--model <path>] [--version <str>] [--out <dir>] [--force]
#
# Environment:
#   PENAI_CARGO_TARGET_DIR   override the cargo build directory
#   PENAI_SCRATCH_DIR        override the scratch root used for both
#                                 the cargo target dir and the web fallback
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

SKIP_TESTS=0
SKIP_WEB=0
SKIP_RUNTIME_CHECK=0
PKG_ARGS=()

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<USAGE
Usage: scripts/build-linux.sh [options]

  --skip-tests            Do not run 'cargo test --release'
  --skip-web              Do not rebuild web/dist (reuse whatever is there)
  --skip-runtime-check    Do not require runtime/linux/llama-server
  --model <path>          Passed through to package.sh (copied in as model.gguf)
  --version <str>         Passed through to package.sh
  --out <dir>             Passed through to package.sh (default: ROOT/release)
  --force                 Passed through to package.sh (overwrite the release dir)
  -h, --help              Show this help
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-tests) SKIP_TESTS=1; shift ;;
    --skip-web) SKIP_WEB=1; shift ;;
    --skip-runtime-check) SKIP_RUNTIME_CHECK=1; shift ;;
    --model) [ "$#" -ge 2 ] || die "--model needs a path"; PKG_ARGS+=(--model "$2"); shift 2 ;;
    --version) [ "$#" -ge 2 ] || die "--version needs a value"; PKG_ARGS+=(--version "$2"); shift 2 ;;
    --out) [ "$#" -ge 2 ] || die "--out needs a directory"; PKG_ARGS+=(--out "$2"); shift 2 ;;
    --force) PKG_ARGS+=(--force); shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

# ------------------------------------------------------------ tool checks -----
step "Checking tools"
MISSING=0
if have cargo; then
  say "cargo: $(command -v cargo) ($(cargo --version 2>/dev/null || echo 'version unknown'))"
else
  warn "cargo not found. Install the Rust toolchain:
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  then restart the shell (or source \$HOME/.cargo/env)."
  MISSING=1
fi
if [ "$SKIP_WEB" -eq 0 ]; then
  if have npm; then
    say "npm:   $(command -v npm) (v$(npm --version 2>/dev/null || echo '?'))"
  else
    warn "npm not found. Install Node.js 18+ (sudo apt install nodejs npm, or use nvm),
  or re-run with --skip-web if web/dist is already built."
    MISSING=1
  fi
fi
[ "$MISSING" -eq 0 ] || die "required tools are missing; see the hints above."

# --------------------------------------------------- scratch / target dirs ----
SCRATCH_ROOT="${PENAI_SCRATCH_DIR:-${TMPDIR:-/tmp}/penai-build}"
if [ -n "${PENAI_CARGO_TARGET_DIR:-}" ]; then
  TARGET_DIR="$PENAI_CARGO_TARGET_DIR"
elif [ -n "${CARGO_TARGET_DIR:-}" ]; then
  TARGET_DIR="$CARGO_TARGET_DIR"
else
  TARGET_DIR="$SCRATCH_ROOT/cargo"
fi

mkdir -p "$TARGET_DIR" || die "cannot create the build directory: $TARGET_DIR
    Set PENAI_CARGO_TARGET_DIR to a writable location on local disk."
export CARGO_TARGET_DIR="$TARGET_DIR"

step "Build directories"
say "cargo target dir: $CARGO_TARGET_DIR"
say "  Reason: the repo may live on a FAT32/exFAT USB drive, which cannot host a"
say "  Rust build cache (no symlinks, no hard links, very slow on small files)."
say "  Override with PENAI_CARGO_TARGET_DIR=/some/path."
say "scratch root:     $SCRATCH_ROOT"

# ------------------------------------------------------- build the launcher ---
MANIFEST="$ROOT/launcher/Cargo.toml"
[ -f "$MANIFEST" ] || die "launcher manifest not found: $MANIFEST"

if [ "$SKIP_TESTS" -eq 0 ]; then
  step "Running launcher tests (cargo test --release)"
  if ! cargo test --release --manifest-path "$MANIFEST"; then
    die "launcher tests FAILED. The build is aborted on purpose: a launcher that
    fails its own path, config, port and process tests must not be shipped on a
    drive that people carry around. Fix the tests, or re-run with --skip-tests
    if you know exactly why you are bypassing them."
  fi
else
  say ""
  warn "skipping cargo tests (--skip-tests)"
fi

step "Building the launcher (cargo build --release)"
cargo build --release --manifest-path "$MANIFEST" \
  || die "cargo build failed. Scroll up for the compiler error."

BIN="$CARGO_TARGET_DIR/release/StartAI"
[ -f "$BIN" ] || die "the build reported success but $BIN does not exist.
    The [[bin]] name in launcher/Cargo.toml must stay 'StartAI'."
say "built: $BIN ($(du -h "$BIN" | cut -f1))"

# ------------------------------------------------------------ build the UI ----
supports_symlinks() {
  # supports_symlinks <dir>
  local probe="$1/.penai-symlink-test.$$"
  rm -f "$probe" 2>/dev/null || true
  if ln -s . "$probe" 2>/dev/null; then
    rm -f "$probe" 2>/dev/null || true
    return 0
  fi
  rm -f "$probe" 2>/dev/null || true
  return 1
}

can_write_node_modules() {
  local probe="$ROOT/web/node_modules/.penai-write-test.$$"
  mkdir -p "$(dirname "$probe")" 2>/dev/null || return 1
  if : > "$probe" 2>/dev/null; then
    rm -f "$probe" 2>/dev/null || true
    return 0
  fi
  return 1
}

npm_install_in() {
  # npm_install_in <dir> <extra-npm-flag...>
  local dir="$1"; shift
  local -a flags=("$@")
  if [ -f "$dir/package-lock.json" ]; then
    say "npm ci ${flags[*]-}"
    ( cd "$dir" && npm ci ${flags[@]+"${flags[@]}"} ) || return 1
  else
    warn "no package-lock.json in $dir; falling back to 'npm install' (versions are not pinned)."
    say "npm install ${flags[*]-}"
    ( cd "$dir" && npm install ${flags[@]+"${flags[@]}"} ) || return 1
  fi
}

build_web_in_place() {
  local -a flags=()
  if supports_symlinks "$ROOT/web"; then
    say "symlink test in $ROOT/web: OK, running npm normally."
  else
    say "symlink test in $ROOT/web: FAILED (FAT32/exFAT), adding --no-bin-links."
    flags+=(--no-bin-links)
  fi
  npm_install_in "$ROOT/web" ${flags[@]+"${flags[@]}"} || return 1
  ( cd "$ROOT/web" && npm run build ) || return 1
  return 0
}

build_web_in_scratch() {
  local scratch="$SCRATCH_ROOT/web"
  say "building the UI in $scratch instead of on the repo filesystem."
  rm -rf "$scratch"
  mkdir -p "$scratch"
  if have rsync; then
    rsync -rLt --exclude node_modules --exclude dist "$ROOT/web"/ "$scratch"/ \
      || die "failed to copy web/ to $scratch"
  else
    ( cd "$ROOT/web" && tar -cf - --exclude=node_modules --exclude=dist . ) | ( cd "$scratch" && tar -xf - ) \
      || die "failed to copy web/ to $scratch"
  fi

  npm_install_in "$scratch" || die "npm install failed in $scratch"
  ( cd "$scratch" && npm run build ) || die "npm run build failed in $scratch"

  [ -d "$scratch/dist" ] || die "$scratch/dist was not produced by 'npm run build'."
  # web/dist is build output (gitignored), so replacing it wholesale is safe.
  rm -rf "$ROOT/web/dist"
  mkdir -p "$ROOT/web/dist"
  if have rsync; then
    rsync -rLt "$scratch/dist"/ "$ROOT/web/dist"/ || die "failed to copy dist/ back to the repo"
  else
    cp -RL "$scratch/dist"/. "$ROOT/web/dist"/ || die "failed to copy dist/ back to the repo"
  fi
  say "copied $scratch/dist -> $ROOT/web/dist"
}

if [ "$SKIP_WEB" -eq 1 ]; then
  step "Web UI"
  warn "skipping the web build (--skip-web)"
  if [ ! -f "$ROOT/web/dist/index.html" ]; then
    die "--skip-web was given but $ROOT/web/dist/index.html does not exist, so
    there is nothing to package. Drop --skip-web."
  fi
  say "reusing existing $ROOT/web/dist"
else
  step "Building the web UI"
  if can_write_node_modules; then
    if ! build_web_in_place; then
      warn "the in-place npm build failed on the repo filesystem; retrying in scratch."
      build_web_in_scratch
    fi
  else
    say "node_modules cannot be created under $ROOT/web (read-only or FAT limitation)."
    build_web_in_scratch
  fi
  [ -f "$ROOT/web/dist/index.html" ] || die "web build finished but $ROOT/web/dist/index.html is missing."
  say "web build ready: $ROOT/web/dist ($(du -sh "$ROOT/web/dist" | cut -f1))"
fi

# ------------------------------------------------------- runtime presence -----
step "Checking the llama.cpp runtime"
if [ "$SKIP_RUNTIME_CHECK" -eq 1 ]; then
  warn "skipping the runtime check (--skip-runtime-check); package.sh will still refuse
  to assemble a release without runtime/linux/llama-server."
elif [ -f "$ROOT/runtime/linux/llama-server" ]; then
  say "found $ROOT/runtime/linux/llama-server"
  if [ -f "$ROOT/runtime/linux/RUNTIME_VERSION.txt" ]; then
    sed 's/^/  /' "$ROOT/runtime/linux/RUNTIME_VERSION.txt"
  fi
else
  die "runtime/linux/llama-server is missing.
    Fix: run  scripts/fetch-runtime.sh --platform linux
    (it downloads llama.cpp b10549 and stages the minimal file set)."
fi

# ------------------------------------------------------------- package --------
step "Packaging"
"$SCRIPT_DIR/package.sh" --platform linux ${PKG_ARGS[@]+"${PKG_ARGS[@]}"}

step "Linux build complete"
say "Release: ${ROOT}/release/linux/PenAI (unless --out changed it)"
say "Deploy:  scripts/deploy-to-pendrive.sh --target /path/to/mountpoint --platform linux"
