#!/usr/bin/env bash
#
# package.sh - assemble a PenAI release folder from artifacts that are
#              already built.
#
# This script never compiles anything. It expects:
#   * a launcher binary   (scripts/build-linux.sh, build-windows.ps1 or
#                          build-windows-cross.sh produced it)
#   * web/dist/           (npm run build produced it)
#   * runtime/<platform>/ (scripts/fetch-runtime.sh or .ps1 staged it)
#
# and it lays those out as the exact tree that the launcher expects to find on
# the drive:
#
#   release/<platform>/PenAI/
#     StartAI            (linux)      StartAI.exe   (windows, if built)
#     StartAI.sh         (linux)      StartAI.bat   (windows)
#     .penai-root   version + build timestamp, used to locate the root
#     runtime/<platform>/
#     models/README.md   (+ model.gguf only when --model is given)
#     web/               contents of web/dist
#     config/config.json copied from config/config.example.json
#     data/chats/.gitkeep, data/logs/.gitkeep
#     README.md
#
# Usage:
#   scripts/package.sh [--platform linux|windows|both] [--out <dir>]
#                      [--model <path-to.gguf>] [--version <str>] [--force]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

PLATFORM="both"
OUT="$ROOT/release"
MODEL=""
VERSION=""
FORCE=0

# Verified facts about the reference model, used for the size report and for
# the checksum comparison.
MODEL_BYTES=2497281120
MODEL_SHA256="3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597"
MODEL_FILENAME="Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
MODEL_URL="https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/${MODEL_FILENAME}"

# PenAI is not tied to one drive size: any stick with room for the model works.
# The size below is only the yardstick this script measures a release against, so
# that a build which no longer fits a common drive says so out loud. Change it
# with --drive-size when you are targeting something else.
#
# A "GB" on a USB package is 10^9 bytes, and formatting costs a little, so a
# nominal 8 GB stick lands near 7.84 GB (about 7.3 GiB) of usable space.
DRIVE_GB=8
USABLE_PER_GB=979789414
DRIVE_USABLE_BYTES=$((DRIVE_GB * USABLE_PER_GB))

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<USAGE
Usage: scripts/package.sh [options]

  --platform linux|windows|both   Which release(s) to assemble (default: both)
  --out <dir>                     Output directory (default: ${ROOT}/release)
  --model <path>                  Copy this .gguf in as models/model.gguf
  --version <str>                 Version string for .penai-root
                                  (default: the version in launcher/Cargo.toml)
  --drive-size <GB>               Drive size to measure the release against.
                                  Reporting only, it changes no output.
                                  (default: ${DRIVE_GB})
  --force                         Overwrite a non-empty output directory
  -h, --help                      Show this help
USAGE
}

human() {
  local b="$1"
  if [ "$b" -ge 1073741824 ]; then
    printf '%d.%02d GiB' $((b / 1073741824)) $(((b % 1073741824) * 100 / 1073741824))
  elif [ "$b" -ge 1048576 ]; then
    printf '%d.%02d MiB' $((b / 1048576)) $(((b % 1048576) * 100 / 1048576))
  elif [ "$b" -ge 1024 ]; then
    printf '%d KiB' $((b / 1024))
  else
    printf '%d B' "$b"
  fi
}

# Bytes used by a file or directory. `du -sb` is GNU; fall back to KiB * 1024.
path_bytes() {
  local p="$1" out
  if out="$(du -sb "$p" 2>/dev/null)"; then
    printf '%s' "${out%%[[:space:]]*}"
  else
    out="$(du -sk "$p" | cut -f1)"
    printf '%s' $((out * 1024))
  fi
}

file_bytes() { wc -c < "$1" | tr -d ' '; }

# --------------------------------------------------------------- arg parsing --
while [ "$#" -gt 0 ]; do
  case "$1" in
    --platform) [ "$#" -ge 2 ] || die "--platform needs a value"; PLATFORM="$2"; shift 2 ;;
    --platform=*) PLATFORM="${1#*=}"; shift ;;
    --out) [ "$#" -ge 2 ] || die "--out needs a directory"; OUT="$2"; shift 2 ;;
    --out=*) OUT="${1#*=}"; shift ;;
    --model) [ "$#" -ge 2 ] || die "--model needs a path to a .gguf file"; MODEL="$2"; shift 2 ;;
    --model=*) MODEL="${1#*=}"; shift ;;
    --version) [ "$#" -ge 2 ] || die "--version needs a value"; VERSION="$2"; shift 2 ;;
    --version=*) VERSION="${1#*=}"; shift ;;
    --drive-size)
      [ "$#" -ge 2 ] || die "--drive-size needs a value in GB"
      DRIVE_GB="$2"; shift 2
      case "$DRIVE_GB" in ''|*[!0-9]*) die "--drive-size must be a whole number of GB" ;; esac
      [ "$DRIVE_GB" -ge 1 ] || die "--drive-size must be at least 1"
      DRIVE_USABLE_BYTES=$((DRIVE_GB * USABLE_PER_GB))
      ;;
    --drive-size=*)
      DRIVE_GB="${1#*=}"; shift
      case "$DRIVE_GB" in ''|*[!0-9]*) die "--drive-size must be a whole number of GB" ;; esac
      [ "$DRIVE_GB" -ge 1 ] || die "--drive-size must be at least 1"
      DRIVE_USABLE_BYTES=$((DRIVE_GB * USABLE_PER_GB))
      ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

case "$PLATFORM" in
  linux|windows|both) ;;
  *) die "--platform must be linux, windows or both (got '$PLATFORM')" ;;
esac

if [ -z "$VERSION" ]; then
  if [ -f "$ROOT/launcher/Cargo.toml" ]; then
    VERSION="$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/launcher/Cargo.toml" | head -n 1)"
  fi
  [ -n "$VERSION" ] || VERSION="0.0.0-unknown"
fi

if [ -n "$MODEL" ]; then
  [ -f "$MODEL" ] || die "--model points at something that is not a file: $MODEL"
fi

BUILD_STAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

say "PenAI packager"
say "  repo root: $ROOT"
say "  platform:  $PLATFORM"
say "  out:       $OUT"
say "  version:   $VERSION"
say "  model:     ${MODEL:-<none: must be added separately>}"

# ------------------------------------------------------------------ helpers --

# Locate a built launcher binary. The build scripts put the target directory
# outside the repo by default (a FAT32/exFAT USB stick cannot host a Rust build
# cache), so several locations are checked.
find_launcher() {
  # find_launcher <relative-path-under-target>  e.g. release/StartAI
  local rel="$1" c
  local -a candidates=()
  if [ -n "${CARGO_TARGET_DIR:-}" ]; then
    candidates+=("$CARGO_TARGET_DIR/$rel")
  fi
  if [ -n "${PENAI_CARGO_TARGET_DIR:-}" ]; then
    candidates+=("$PENAI_CARGO_TARGET_DIR/$rel")
  fi
  candidates+=(
    "${TMPDIR:-/tmp}/penai-build/cargo/$rel"
    "$ROOT/launcher/target/$rel"
    "$ROOT/target/$rel"
  )
  for c in "${candidates[@]}"; do
    if [ -f "$c" ]; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

prepare_dest() {
  # prepare_dest <dest>
  local dest="$1"
  if [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null || true)" ]; then
    if [ "$FORCE" -eq 0 ]; then
      die "output directory is not empty: $dest
    Refusing to mix a new release into an old one. Re-run with --force to
    overwrite it, or pick another location with --out <dir>."
    fi
    warn "overwriting non-empty $dest (--force)"
    # Only the release folder we own is removed, and only with --force.
    rm -rf "$dest"
  fi
  mkdir -p "$dest"
}

copy_tree() {
  # copy_tree <src-dir> <dest-dir> - contents of src into dest, dereferencing
  # symlinks because FAT32/exFAT cannot store them.
  local src="$1" dest="$2"
  mkdir -p "$dest"
  if have rsync; then
    rsync -rLt --no-perms --no-owner --no-group "$src"/ "$dest"/ >/dev/null
  else
    cp -RL "$src"/. "$dest"/
  fi
}

write_marker() {
  # write_marker <dest> <platform>
  local dest="$1" platform="$2"
  cat > "$dest/.penai-root" <<MARKER
${VERSION}
built: ${BUILD_STAMP}
platform: ${platform}
packaged-by: scripts/package.sh
MARKER
}

copy_models_readme() {
  local dest="$1"
  mkdir -p "$dest/models"
  if [ -f "$ROOT/models/README.md" ]; then
    cp -f "$ROOT/models/README.md" "$dest/models/README.md"
  else
    warn "models/README.md is missing from the repo; writing a minimal one into the release."
    cat > "$dest/models/README.md" <<MODELREADME
# PenAI model directory

Put a GGUF model file here. The launcher uses \`model.gguf\` if it exists,
otherwise the largest \`.gguf\` file in this directory.

Reference model used by PenAI:

- repository: unsloth/Qwen3-4B-Instruct-2507-GGUF
- file: ${MODEL_FILENAME}
- size: ${MODEL_BYTES} bytes
- SHA-256: ${MODEL_SHA256}
- licence: Apache-2.0 (not gated, no authentication needed)
- URL: ${MODEL_URL}

Download it with \`models/download-model.sh\` (Linux/macOS) or
\`models/download-model.ps1\` (Windows) from the source repository, then copy
the result here as \`model.gguf\`.
MODELREADME
  fi
}

copy_docs() {
  # copy_docs <dest>
  local dest="$1"
  if [ -f "$ROOT/README.md" ]; then
    cp -f "$ROOT/README.md" "$dest/README.md"
  else
    warn "README.md is missing from the repo root; writing a minimal one into the release."
    cat > "$dest/README.md" <<RELREADME
# PenAI ${VERSION}

A fully offline AI assistant that runs from this drive. Nothing is sent to the
internet: the model, the llama.cpp server and the web UI all live in this
folder and talk to each other over 127.0.0.1 only.

## Start it

- Linux: run \`./StartAI\`. If the drive refuses to execute it (FAT32 mounted
  with \`showexec\`, or any \`noexec\` mount), run \`sh StartAI.sh\` instead.
- Windows: run \`StartAI.exe\` if present, otherwise \`StartAI.bat\`.

The launcher starts llama.cpp, waits until it is healthy and opens your browser.

## Folders

- \`runtime/\` llama.cpp binaries and libraries
- \`models/\`  the .gguf model file
- \`web/\`     the browser UI
- \`config/\`  config.json, documented inside the file
- \`data/\`    logs and saved chats

Built ${BUILD_STAMP} by scripts/package.sh.
RELREADME
  fi

  if [ -f "$ROOT/LICENSE" ]; then
    cp -f "$ROOT/LICENSE" "$dest/LICENSE"
  else
    warn "no LICENSE file in the repo root; the release will not contain one."
  fi
}

copy_web() {
  local dest="$1"
  local dist="$ROOT/web/dist"
  if [ ! -d "$dist" ] || [ -z "$(ls -A "$dist" 2>/dev/null || true)" ]; then
    die "web build not found or empty: $dist
    Fix: build the UI first (scripts/build-linux.sh does it for you, or run
    'npm ci && npm run build' inside $ROOT/web)."
  fi
  [ -f "$dist/index.html" ] || warn "$dist has no index.html; the UI will not load."
  copy_tree "$dist" "$dest/web"
}

copy_config() {
  local dest="$1"
  local example="$ROOT/config/config.example.json"
  [ -f "$example" ] || die "missing $example - it is the source of config/config.json."
  mkdir -p "$dest/config"
  cp -f "$example" "$dest/config/config.json"
}

copy_runtime() {
  # copy_runtime <dest> <platform>
  local dest="$1" platform="$2"
  local src="$ROOT/runtime/$platform"
  local probe="llama-server"
  [ "$platform" = "windows" ] && probe="llama-server.exe"

  if [ ! -f "$src/$probe" ]; then
    die "runtime is missing: $src/$probe
    Fix: run  scripts/fetch-runtime.sh --platform ${platform}
    (on Windows: scripts\\fetch-runtime.ps1)"
  fi
  copy_tree "$src" "$dest/runtime/$platform"

  # Nothing in a release may be a symlink: FAT32 and exFAT cannot store them.
  local leftover
  leftover="$(find "$dest/runtime/$platform" -type l -print 2>/dev/null || true)"
  if [ -n "$leftover" ]; then
    printf '%s\n' "$leftover" >&2
    die "symlinks ended up in the packaged runtime. They cannot survive a copy to
    FAT32/exFAT. Re-stage the runtime with scripts/fetch-runtime.sh --force."
  fi
}

make_data_dirs() {
  local dest="$1"
  mkdir -p "$dest/data/chats" "$dest/data/logs"
  : > "$dest/data/chats/.gitkeep"
  : > "$dest/data/logs/.gitkeep"
}

copy_model() {
  # copy_model <dest>
  local dest="$1"
  [ -n "$MODEL" ] || return 0

  local base size
  base="$(basename "$MODEL")"
  size="$(file_bytes "$MODEL")"
  say "copying model ($(human "$size")): $MODEL"
  say "  on a slow USB drive this single copy can take several minutes."
  cp -f "$MODEL" "$dest/models/model.gguf"

  # Verify only when the file is recognisably the reference model. Any other
  # GGUF has a different, unknown checksum, so verifying it would be nonsense.
  local expected="" verify=0
  if [ "$base" = "model.gguf" ] || [ "$base" = "$MODEL_FILENAME" ]; then
    verify=1
  fi
  if [ "$verify" -eq 1 ] && [ -f "$ROOT/models/model.sha256" ]; then
    expected="$(awk 'NR==1{print $1}' "$ROOT/models/model.sha256")"
  fi

  if [ "$verify" -eq 1 ] && [ -n "$expected" ] && have sha256sum; then
    say "verifying SHA-256 (this reads the whole ${MODEL_BYTES} byte file)..."
    local actual
    actual="$(sha256sum "$dest/models/model.gguf" | awk '{print $1}')"
    if [ "$actual" = "$expected" ]; then
      say "model checksum OK: $actual"
    else
      warn "model checksum MISMATCH
  expected: $expected
  actual:   $actual
  The release was still assembled, but this file is not the reference
  ${MODEL_FILENAME}. If it is a different quantisation that is fine;
  if it should be the reference model, re-download it with
  models/download-model.sh."
    fi
    if [ "$size" -ne "$MODEL_BYTES" ]; then
      warn "model size is $size bytes, expected $MODEL_BYTES for the reference model."
    fi
  else
    say "not verifying the checksum: only ${MODEL_FILENAME} (or model.gguf) has a known one."
  fi
  say "model in release: $(human "$(file_bytes "$dest/models/model.gguf")")"
}

fix_permissions() {
  # fix_permissions <dest>
  local dest="$1" f ok=1
  for f in "$dest/StartAI" "$dest"/*.sh; do
    [ -e "$f" ] || continue
    chmod +x "$f" 2>/dev/null || ok=0
  done
  if [ -f "$dest/runtime/linux/llama-server" ]; then
    chmod +x "$dest/runtime/linux/llama-server" 2>/dev/null || ok=0
  fi
  if [ "$ok" -eq 0 ]; then
    say "note: could not set execute bits (the output directory is on a FAT filesystem)."
    say "      That is expected. On Linux launch with 'sh StartAI.sh', which stages"
    say "      the launcher to local disk and chmods it there."
  fi
}

size_report() {
  # size_report <dest> <platform> <model-included:0|1>
  local dest="$1" platform="$2" with_model="$3"
  step "Size breakdown - release/$platform/PenAI"
  local entry name b total=0
  # Top-level entries, largest first.
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    b="$(path_bytes "$entry")"
    total=$((total + b))
    name="$(basename "$entry")"
    printf '  %-24s %s\n' "$name" "$(human "$b")"
  done < <(find "$dest" -mindepth 1 -maxdepth 1 -print | sort)

  printf '  %-24s %s\n' "TOTAL" "$(human "$total")"
  say ""
  local free=$((DRIVE_USABLE_BYTES - total))
  say "A ${DRIVE_GB} GB drive has about $(human "$DRIVE_USABLE_BYTES") usable."
  if [ "$free" -ge 0 ]; then
    say "This release leaves $(human "$free") free on it."
  else
    warn "this release is $(human $((-free))) LARGER than a ${DRIVE_GB} GB drive can hold."
  fi

  if [ "$with_model" -eq 0 ]; then
    local after=$((free - MODEL_BYTES))
    say ""
    say "NO MODEL IS INCLUDED in this release. It will not run until you add one."
    say "  Add ${MODEL_BYTES} bytes ($(human "$MODEL_BYTES")) as models/model.gguf:"
    say "    models/download-model.sh          (Linux/macOS)"
    say "    models/download-model.ps1         (Windows)"
    say "    or re-run this script with --model <path-to.gguf>"
    if [ "$after" -ge 0 ]; then
      say "  With the model added, $(human "$after") would remain free on a ${DRIVE_GB} GB drive."
    else
      warn "with the model added this would exceed a ${DRIVE_GB} GB drive by $(human $((-after)))."
    fi
  fi
}

# ------------------------------------------------------------------- linux ----
package_linux() {
  step "Assembling Linux release"
  local dest="$OUT/linux/PenAI"
  prepare_dest "$dest"

  local bin
  if ! bin="$(find_launcher release/StartAI)"; then
    die "no Linux launcher binary found.
    Looked in \$CARGO_TARGET_DIR, \${TMPDIR:-/tmp}/penai-build/cargo and
    ${ROOT}/launcher/target (subpath release/StartAI).
    Fix: run  scripts/build-linux.sh   (it builds and then calls this script)."
  fi
  say "launcher binary: $bin ($(human "$(file_bytes "$bin")"))"
  cp -f "$bin" "$dest/StartAI"

  if [ -f "$ROOT/release-assets/StartAI.sh" ]; then
    cp -f "$ROOT/release-assets/StartAI.sh" "$dest/StartAI.sh"
  else
    die "missing $ROOT/release-assets/StartAI.sh - it is the FAT32/noexec bootstrap
    and a Linux release is not usable on a FAT32 drive without it."
  fi

  copy_runtime "$dest" linux
  copy_web "$dest"
  copy_config "$dest"
  copy_models_readme "$dest"
  copy_docs "$dest"
  make_data_dirs "$dest"
  write_marker "$dest" linux
  copy_model "$dest"
  fix_permissions "$dest"

  local with_model=0
  [ -f "$dest/models/model.gguf" ] && with_model=1
  size_report "$dest" linux "$with_model"
  say ""
  say "Linux release ready: $dest"
}

# ----------------------------------------------------------------- windows ----
package_windows() {
  step "Assembling Windows release"
  local dest="$OUT/windows/PenAI"
  prepare_dest "$dest"

  local bin=""
  if bin="$(find_launcher x86_64-pc-windows-gnu/release/StartAI.exe)"; then
    :
  elif bin="$(find_launcher x86_64-pc-windows-msvc/release/StartAI.exe)"; then
    :
  elif bin="$(find_launcher release/StartAI.exe)"; then
    :
  else
    bin=""
  fi

  if [ -n "$bin" ]; then
    say "launcher binary: $bin ($(human "$(file_bytes "$bin")"))"
    cp -f "$bin" "$dest/StartAI.exe"
  else
    warn "no StartAI.exe found; packaging WITHOUT it.
  The release will still work through StartAI.bat, which is the pure cmd.exe +
  PowerShell fallback, but StartAI.exe is preferred (single-instance handling,
  log rotation, RAM-aware context reduction, clean child shutdown).
  Build it with scripts\\build-windows.ps1 on Windows, or
  scripts/build-windows-cross.sh from Linux."
  fi

  if [ -f "$ROOT/release-assets/StartAI.bat" ]; then
    cp -f "$ROOT/release-assets/StartAI.bat" "$dest/StartAI.bat"
  else
    die "missing $ROOT/release-assets/StartAI.bat"
  fi

  copy_runtime "$dest" windows
  copy_web "$dest"
  copy_config "$dest"
  copy_models_readme "$dest"
  copy_docs "$dest"
  make_data_dirs "$dest"
  write_marker "$dest" windows
  copy_model "$dest"

  local with_model=0
  [ -f "$dest/models/model.gguf" ] && with_model=1
  size_report "$dest" windows "$with_model"
  say ""
  say "Windows release ready: $dest"
}

case "$PLATFORM" in
  linux)   package_linux ;;
  windows) package_windows ;;
  both)    package_linux; package_windows ;;
esac

step "Done"
say "Deploy it with:"
say "  scripts/deploy-to-pendrive.sh --target /path/to/mountpoint --platform ${PLATFORM}"
