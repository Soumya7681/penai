#!/usr/bin/env bash
#
# fetch-runtime.sh - download and stage the llama.cpp runtime for PenAI.
#
# Downloads the official prebuilt llama.cpp release archive(s) into vendor/,
# then copies ONLY the files PenAI actually needs into runtime/linux/ and
# runtime/windows/. Everything else in the archive (other CLI tools, headers,
# import libraries) is dropped, which is what keeps the drive small.
#
# Two details that matter and are easy to get wrong:
#   1. The Linux tarball ships SYMLINKS (libggml-base.so.0 -> libggml-base.so.0.20.2
#      and friends). Neither FAT32 nor exFAT can store a symlink, so every file
#      is copied with `cp -L`: the destination is a real file carrying the .so.0
#      name that the ELF DT_NEEDED entries actually ask for.
#   2. All 15 libggml-cpu-*.so / .dll variants are kept on purpose. llama.cpp
#      dlopen()s the one matching the CPU it finds at run time, and keeping the
#      whole set is what lets one drive work on any x86-64 machine.
#
# Linux binaries are built with RUNPATH=$ORIGIN, so no LD_LIBRARY_PATH is needed
# as long as the .so files sit next to llama-server. They need glibc 2.34+.
# Windows resolves DLLs from the executable's own directory, so no PATH edit
# is needed there either.
#
# Usage:
#   scripts/fetch-runtime.sh [--platform linux|windows|both] [--tag <tag>] [--force]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

DEFAULT_TAG="b10549"
REPO="ggml-org/llama.cpp"

PLATFORM="both"
TAG="$DEFAULT_TAG"
FORCE=0

# Minimum plausible archive size. Anything smaller is a GitHub HTML error page,
# a rate-limit notice or a truncated transfer, never a real runtime.
MIN_ARCHIVE_BYTES=$((5 * 1024 * 1024))

# ---------------------------------------------------------------- file lists --
# Linux: llama-server plus its shared libraries and the CPU feature variants.
LINUX_FILES=(
  llama-server
  libllama-server-impl.so
  libllama-common.so.0
  libmtmd.so.0
  libllama.so.0
  libggml.so.0
  libggml-base.so.0
  libggml-rpc.so
  libggml-cpu-alderlake.so
  libggml-cpu-cannonlake.so
  libggml-cpu-cascadelake.so
  libggml-cpu-cooperlake.so
  libggml-cpu-haswell.so
  libggml-cpu-icelake.so
  libggml-cpu-ivybridge.so
  libggml-cpu-piledriver.so
  libggml-cpu-sandybridge.so
  libggml-cpu-sapphirerapids.so
  libggml-cpu-skylakex.so
  libggml-cpu-sse42.so
  libggml-cpu-x64.so
  libggml-cpu-zen4.so
  LICENSE
)

WINDOWS_FILES=(
  llama-server.exe
  llama-server-impl.dll
  llama-common.dll
  llama.dll
  mtmd.dll
  ggml.dll
  ggml-base.dll
  ggml-rpc.dll
  libomp.dll
  ggml-cpu-alderlake.dll
  ggml-cpu-cannonlake.dll
  ggml-cpu-cascadelake.dll
  ggml-cpu-cooperlake.dll
  ggml-cpu-haswell.dll
  ggml-cpu-icelake.dll
  ggml-cpu-ivybridge.dll
  ggml-cpu-piledriver.dll
  ggml-cpu-sandybridge.dll
  ggml-cpu-sapphirerapids.dll
  ggml-cpu-skylakex.dll
  ggml-cpu-sse42.dll
  ggml-cpu-x64.dll
  ggml-cpu-zen4.dll
  LICENSE-LLVM-OpenMP
)

# ------------------------------------------------------------------ helpers --
say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage: scripts/fetch-runtime.sh [options]

  --platform linux|windows|both   Which runtime(s) to stage (default: both)
  --tag <tag>                     llama.cpp release tag (default: ${DEFAULT_TAG})
  --force                         Re-download even if the archive is cached
  -h, --help                      Show this help

Downloads are cached in ${ROOT}/vendor/ and staged into
${ROOT}/runtime/<platform>/.
USAGE
}

have() { command -v "$1" >/dev/null 2>&1; }

require_tools() {
  local missing=0
  if ! have curl && ! have wget; then
    warn "neither curl nor wget found. Install one:  sudo apt install curl"
    missing=1
  fi
  if ! have tar; then
    warn "tar not found. Install it:  sudo apt install tar"
    missing=1
  fi
  if [ "$PLATFORM" = "windows" ] || [ "$PLATFORM" = "both" ]; then
    if ! have unzip; then
      warn "unzip not found (needed for the Windows archive). Install it:  sudo apt install unzip"
      missing=1
    fi
  fi
  [ "$missing" -eq 0 ] || die "required tools are missing; see the hints above."
}

file_bytes() {
  # Portable-enough byte size of a file.
  wc -c < "$1" | tr -d ' '
}

human() {
  # bytes -> human string, integer maths only so no bc dependency.
  local b="$1"
  if [ "$b" -ge 1073741824 ]; then
    printf '%d.%02d GiB' $((b / 1073741824)) $(((b % 1073741824) * 100 / 1073741824))
  elif [ "$b" -ge 1048576 ]; then
    printf '%d.%02d MiB' $((b / 1048576)) $(((b % 1048576) * 100 / 1048576))
  else
    printf '%d KiB' $((b / 1024))
  fi
}

download() {
  # download <url> <dest>
  local url="$1" dest="$2" tmp="$2.part"
  if [ -f "$dest" ] && [ "$FORCE" -eq 0 ]; then
    local sz
    sz="$(file_bytes "$dest")"
    if [ "$sz" -ge "$MIN_ARCHIVE_BYTES" ]; then
      say "cached: $(basename "$dest") ($(human "$sz")) - use --force to re-download"
      return 0
    fi
    warn "cached archive $(basename "$dest") is only $(human "$sz"); re-downloading."
    rm -f "$dest"
  fi

  say "downloading $url"
  rm -f "$tmp"
  if have curl; then
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 30 --progress-bar -o "$tmp" "$url" \
      || die "download failed: $url
    Check the network, and check that the release tag '${TAG}' really has this asset:
      https://github.com/${REPO}/releases/tag/${TAG}"
  else
    wget --tries=3 --timeout=30 -O "$tmp" "$url" \
      || die "download failed: $url
    Check the network, and check that the release tag '${TAG}' really has this asset:
      https://github.com/${REPO}/releases/tag/${TAG}"
  fi

  local sz
  sz="$(file_bytes "$tmp")"
  if [ "$sz" -lt "$MIN_ARCHIVE_BYTES" ]; then
    # Show the first line: a GitHub error page says so in plain text.
    say "first bytes of the response:"
    head -c 200 "$tmp" | tr -d '\0' || true
    printf '\n'
    rm -f "$tmp"
    die "downloaded file is only $(human "$sz"), which is far too small for a
    llama.cpp runtime. That is an HTML error page or a truncated transfer, not
    an archive. Verify the asset name for tag '${TAG}' at
      https://github.com/${REPO}/releases/tag/${TAG}"
  fi
  mv "$tmp" "$dest"
  say "saved $(basename "$dest") ($(human "$sz"))"
}

# find_in_tree <tree> <filename> -> prints path or nothing
find_in_tree() {
  find "$1" \( -type f -o -type l \) -name "$2" -print -quit 2>/dev/null || true
}

# stage <platform> <extract-root> - copy the minimal set, dereferencing symlinks
stage() {
  local platform="$1" tree="$2"
  local dest="$ROOT/runtime/$platform"
  local -a files
  if [ "$platform" = "linux" ]; then
    files=("${LINUX_FILES[@]}")
  else
    files=("${WINDOWS_FILES[@]}")
  fi

  mkdir -p "$dest"

  local -a missing=()
  local f src
  for f in "${files[@]}"; do
    src="$(find_in_tree "$tree" "$f")"
    if [ -z "$src" ]; then
      missing+=("$f")
      continue
    fi
    # -L dereferences: the destination is a real file, never a symlink, because
    # FAT32/exFAT cannot store symlinks at all.
    cp -L -f "$src" "$dest/$f" || die "failed to copy $f into $dest"
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    printf 'ERROR: the archive is missing %d required file(s):\n' "${#missing[@]}" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    cat >&2 <<HINT
    Refusing to leave a half-staged runtime in ${dest}.
    Either the release tag '${TAG}' packages different file names, or the
    download was incomplete. Inspect the asset listing at
      https://github.com/${REPO}/releases/tag/${TAG}
    and re-run with --force, or pin a tag that is known to work: --tag ${DEFAULT_TAG}
HINT
    exit 1
  fi

  # Belt and braces: no symlink may survive into the staged runtime.
  local leftover
  leftover="$(find "$dest" -type l -print 2>/dev/null || true)"
  if [ -n "$leftover" ]; then
    printf '%s\n' "$leftover" >&2
    die "symlinks found in $dest after staging. FAT32/exFAT cannot store them.
    This is a bug in this script: every copy must use 'cp -L'."
  fi

  # Executable bits are best-effort: a FAT filesystem cannot store them, and
  # release-assets/StartAI.sh exists precisely to work around that.
  if [ "$platform" = "linux" ]; then
    if ! chmod +x "$dest/llama-server" 2>/dev/null; then
      say "note: could not set the execute bit on llama-server (FAT filesystem?)."
      say "      That is expected on FAT32/exFAT; StartAI.sh stages and chmods at launch."
    fi
  fi
}

write_version_file() {
  # write_version_file <platform> <url>
  local platform="$1" url="$2"
  local dest="$ROOT/runtime/$platform/RUNTIME_VERSION.txt"
  cat > "$dest" <<VER
llama.cpp release tag: ${TAG}
source URL:            ${url}
repository:            https://github.com/${REPO}
staged on:             $(date -u '+%Y-%m-%dT%H:%M:%SZ')
staged by:             scripts/fetch-runtime.sh
VER
  say "wrote $(basename "$dest")"
}

report() {
  local platform="$1"
  local dest="$ROOT/runtime/$platform"
  local count size_h
  count="$(find "$dest" -type f | wc -l | tr -d ' ')"
  size_h="$(du -sh "$dest" 2>/dev/null | cut -f1)"
  say ""
  say "staged runtime: $dest"
  say "  files: ${count}"
  say "  size:  ${size_h}"
}

fetch_linux() {
  local asset="llama-${TAG}-bin-ubuntu-x64.tar.gz"
  local url="https://github.com/${REPO}/releases/download/${TAG}/${asset}"
  local archive="$ROOT/vendor/$asset"

  step "Linux runtime (${TAG})"
  mkdir -p "$ROOT/vendor"
  download "$url" "$archive"

  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/penai-runtime-linux.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  say "extracting to $tmp"
  tar -xzf "$archive" -C "$tmp" || die "tar failed on $archive. Re-run with --force to download it again."

  # The tarball extracts into a single top-level directory (llama-${TAG}/), but
  # locate llama-server rather than trusting that name, so a differently laid
  # out release still works.
  local server
  server="$(find_in_tree "$tmp" "llama-server")"
  [ -n "$server" ] || die "no 'llama-server' anywhere inside $asset. Wrong asset for tag '${TAG}'?"
  say "found llama-server at ${server#"$tmp"/}"

  stage linux "$tmp"
  write_version_file linux "$url"
  report linux
}

fetch_windows() {
  local asset="llama-${TAG}-bin-win-cpu-x64.zip"
  local url="https://github.com/${REPO}/releases/download/${TAG}/${asset}"
  local archive="$ROOT/vendor/$asset"

  step "Windows runtime (${TAG})"
  mkdir -p "$ROOT/vendor"
  download "$url" "$archive"

  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/penai-runtime-windows.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  say "extracting to $tmp"
  # This archive puts its files at the ZIP root, no wrapper directory.
  unzip -q -o "$archive" -d "$tmp" || die "unzip failed on $archive. Re-run with --force."

  local server
  server="$(find_in_tree "$tmp" "llama-server.exe")"
  [ -n "$server" ] || die "no 'llama-server.exe' anywhere inside $asset. Wrong asset for tag '${TAG}'?"

  stage windows "$tmp"
  write_version_file windows "$url"
  report windows
}

# --------------------------------------------------------------------- main --
while [ "$#" -gt 0 ]; do
  case "$1" in
    --platform)
      [ "$#" -ge 2 ] || die "--platform needs a value: linux, windows or both"
      PLATFORM="$2"; shift 2 ;;
    --platform=*) PLATFORM="${1#*=}"; shift ;;
    --tag)
      [ "$#" -ge 2 ] || die "--tag needs a value, for example --tag ${DEFAULT_TAG}"
      TAG="$2"; shift 2 ;;
    --tag=*) TAG="${1#*=}"; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

case "$PLATFORM" in
  linux|windows|both) ;;
  *) die "--platform must be linux, windows or both (got '$PLATFORM')" ;;
esac
[ -n "$TAG" ] || die "--tag must not be empty"

say "PenAI runtime fetcher"
say "  repo root: $ROOT"
say "  platform:  $PLATFORM"
say "  tag:       $TAG"
say "  cache:     $ROOT/vendor"

require_tools

case "$PLATFORM" in
  linux)   fetch_linux ;;
  windows) fetch_windows ;;
  both)    fetch_linux; fetch_windows ;;
esac

step "Done"
say "Next step: build a release with scripts/build-linux.sh, or assemble one from"
say "already-built artifacts with scripts/package.sh --platform ${PLATFORM}."
