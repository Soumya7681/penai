#!/usr/bin/env bash
#
# download-model.sh - fetch the PendriveAI model (Linux/macOS).
#
# Downloads a GGUF quantisation of Qwen3-4B-Instruct-2507 from Hugging Face and
# saves it next to this script as model.gguf, which is the name the launcher
# looks for first. The download resumes if it is interrupted, and the result is
# verified against a known SHA-256 and byte size.
#
# The model is Apache-2.0 licensed, is NOT gated, and needs no account, token
# or authentication of any kind.
#
# Usage:
#   models/download-model.sh [--dest <path>] [--quant Q4_K_M]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO_ID="unsloth/Qwen3-4B-Instruct-2507-GGUF"
BASE_URL="https://huggingface.co/${REPO_ID}/resolve/main"

# Only Q4_K_M has a verified checksum and size. The others are offered for
# convenience and are checked for plausibility only.
QUANT="Q4_K_M"
VERIFIED_QUANT="Q4_K_M"
VERIFIED_SHA256="3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597"
VERIFIED_BYTES=2497281120

DEST="$SCRIPT_DIR/model.gguf"

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<USAGE
Usage: models/download-model.sh [options]

  --dest <path>     Where to write the file (default: ${SCRIPT_DIR}/model.gguf)
  --quant <name>    Which quantisation to download (default: ${QUANT})
                    Available: Q2_K, Q3_K_M, Q4_K_M, Q5_K_M, Q6_K
                    Only Q4_K_M has a verified SHA-256 in this repository.
  -h, --help        Show this help

Source: ${BASE_URL}/Qwen3-4B-Instruct-2507-${QUANT}.gguf
Licence: Apache-2.0 (not gated, no authentication needed)
USAGE
}

human() {
  local b="$1"
  if [ "$b" -ge 1073741824 ]; then
    printf '%d.%02d GiB' $((b / 1073741824)) $(((b % 1073741824) * 100 / 1073741824))
  elif [ "$b" -ge 1048576 ]; then
    printf '%d.%02d MiB' $((b / 1048576)) $(((b % 1048576) * 100 / 1048576))
  else
    printf '%d KiB' $((b / 1024))
  fi
}

file_bytes() { wc -c < "$1" | tr -d ' '; }

sha256_of() {
  # sha256_of <file> - prints the hex digest, or nothing if no tool is available
  local f="$1"
  if have sha256sum; then
    sha256sum "$f" | awk '{print $1}'
  elif have shasum; then
    shasum -a 256 "$f" | awk '{print $1}'
  elif have openssl; then
    openssl dgst -sha256 "$f" | awk '{print $NF}'
  else
    return 1
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dest) [ "$#" -ge 2 ] || die "--dest needs a path"; DEST="$2"; shift 2 ;;
    --dest=*) DEST="${1#*=}"; shift ;;
    --quant) [ "$#" -ge 2 ] || die "--quant needs a value"; QUANT="$2"; shift 2 ;;
    --quant=*) QUANT="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

case "$QUANT" in
  Q2_K|Q3_K_M|Q4_K_M|Q5_K_M|Q6_K) ;;
  *) die "unknown --quant '$QUANT'. Choose one of: Q2_K, Q3_K_M, Q4_K_M, Q5_K_M, Q6_K" ;;
esac

FILE_NAME="Qwen3-4B-Instruct-2507-${QUANT}.gguf"
URL="${BASE_URL}/${FILE_NAME}"

EXPECT_SHA=""
EXPECT_BYTES=0
if [ "$QUANT" = "$VERIFIED_QUANT" ]; then
  EXPECT_SHA="$VERIFIED_SHA256"
  EXPECT_BYTES="$VERIFIED_BYTES"
fi

# ------------------------------------------------------------------ banner ----
say "PendriveAI model download"
say "  repository: ${REPO_ID}"
say "  file:       ${FILE_NAME}"
say "  URL:        ${URL}"
say "  licence:    Apache-2.0 (not gated, no account or token needed)"
say "  destination: ${DEST}"
if [ "$QUANT" = "$VERIFIED_QUANT" ]; then
  say "  size:       ${VERIFIED_BYTES} bytes ($(human "$VERIFIED_BYTES"))"
  say "  SHA-256:    ${VERIFIED_SHA256}"
  say ""
  say "You need about 2.5 GB of free space at the destination, plus a little more"
  say "if you later copy the file to a drive."
else
  say ""
  warn "quantisation ${QUANT} has NO verified checksum in this repository.
  Only ${VERIFIED_QUANT} does. The download will be checked for plausibility
  (a GGUF magic number and a sane size) but not against a known digest.
  ${QUANT} files in this repository range from roughly 1.5 GB to 3.5 GB, so plan
  for about 4 GB of free space to be safe."
fi

DEST_DIR="$(dirname "$DEST")"
mkdir -p "$DEST_DIR" || die "cannot create the destination directory: $DEST_DIR"
[ -w "$DEST_DIR" ] || die "destination directory is not writable: $DEST_DIR"

# ------------------------------------------------------ already downloaded? ----
if [ -f "$DEST" ]; then
  step "A file is already at the destination"
  existing="$(file_bytes "$DEST")"
  say "size: ${existing} bytes ($(human "$existing"))"
  if [ -n "$EXPECT_SHA" ]; then
    say "verifying SHA-256 (reads the whole file, takes a few seconds)..."
    if actual="$(sha256_of "$DEST")"; then
      if [ "$actual" = "$EXPECT_SHA" ]; then
        say "checksum matches: $actual"
        say ""
        say "Nothing to do: ${DEST} is already the correct ${FILE_NAME}."
        exit 0
      fi
      warn "checksum does NOT match:
  expected $EXPECT_SHA
  actual   $actual
  Treating the file as an incomplete or different download and resuming."
    else
      warn "no sha256sum, shasum or openssl available; cannot verify the existing file."
      if [ "$existing" -eq "$EXPECT_BYTES" ]; then
        say "The size matches exactly (${EXPECT_BYTES} bytes), so it is very likely correct."
        say "Nothing to do."
        exit 0
      fi
    fi
  else
    say "no verified checksum for ${QUANT}; will resume the download if it is incomplete."
  fi
fi

# ------------------------------------------------------------- free space ------
avail_kb="$(df -Pk "$DEST_DIR" | awk 'NR==2 {print $4}')"
if [ -n "$avail_kb" ]; then
  avail=$((avail_kb * 1024))
  say ""
  say "free space at ${DEST_DIR}: $(human "$avail")"
  need=${EXPECT_BYTES:-0}
  [ "$need" -eq 0 ] && need=$((4 * 1024 * 1024 * 1024))
  if [ "$avail" -lt "$need" ]; then
    # Not fatal: a resumed download needs only the remaining bytes.
    warn "that is less than the $(human "$need") this download may need.
  If the destination is a FAT32 drive, remember that no single file above
  4 GiB can exist there at all."
  fi
fi

# ------------------------------------------------------------- download --------
step "Downloading"
say "Resume is enabled: if this is interrupted, run the same command again and it"
say "continues where it stopped. Ctrl+C is safe."
say ""

if have curl; then
  # -C - resumes from wherever the local file ends.
  curl -fL -C - --retry 5 --retry-delay 5 --connect-timeout 30 --progress-bar \
    -o "$DEST" "$URL" \
    || die "download failed (curl). Run the same command again to resume.
    If it keeps failing, check the network and that the URL is reachable:
      $URL"
elif have wget; then
  wget -c --tries=5 --timeout=30 -O "$DEST" "$URL" \
    || die "download failed (wget). Run the same command again to resume.
    If it keeps failing, check the network and that the URL is reachable:
      $URL"
else
  die "neither curl nor wget is installed.
    Install one:  sudo apt install curl    (or: sudo dnf install curl)
    Or download the file manually and save it as ${DEST}:
      $URL"
fi

# ------------------------------------------------------------- verification ----
step "Verifying"
size="$(file_bytes "$DEST")"
say "size: ${size} bytes ($(human "$size"))"

# Every GGUF file starts with the ASCII magic "GGUF".
magic="$(head -c 4 "$DEST" 2>/dev/null || true)"
if [ "$magic" != "GGUF" ]; then
  die "this is not a GGUF file: it does not start with the 'GGUF' magic bytes.
    It is almost certainly an HTML error page. Delete it and retry:
      rm -f '$DEST'
      $0 --quant $QUANT --dest '$DEST'"
fi
say "GGUF magic: OK"

fail=0

if [ "$EXPECT_BYTES" -gt 0 ]; then
  if [ "$size" -eq "$EXPECT_BYTES" ]; then
    say "size matches the expected ${EXPECT_BYTES} bytes"
  else
    warn "size mismatch: expected ${EXPECT_BYTES} bytes, got ${size}"
    fail=1
  fi
fi

if [ -n "$EXPECT_SHA" ]; then
  say "computing SHA-256..."
  if actual="$(sha256_of "$DEST")"; then
    if [ "$actual" = "$EXPECT_SHA" ]; then
      say "SHA-256 matches: $actual"
    else
      warn "SHA-256 MISMATCH
  expected $EXPECT_SHA
  actual   $actual"
      fail=1
    fi
  else
    warn "no sha256sum, shasum or openssl available; the checksum was not verified.
  Install one (sudo apt install coreutils) and re-run to check, or compare
  against models/model.sha256 by hand."
  fi
else
  say "no verified checksum exists for ${QUANT}; skipping the digest check."
fi

if [ "$fail" -ne 0 ]; then
  say ""
  say "The file has been KEPT at ${DEST} so you can inspect it, but it does not"
  say "match the expected ${FILE_NAME}. Do not ship it. To start over:"
  say "  rm -f '$DEST'"
  say "  $0 --quant $QUANT --dest '$DEST'"
  say ""
  say "A mismatch after a completed download usually means the transfer was"
  say "corrupted, or a proxy modified it, or the upstream file was replaced."
  exit 1
fi

step "Done"
say "Model ready: $DEST"
say "  $(human "$size")"
say ""
say "The launcher picks up models/model.gguf automatically. If you saved it"
say "elsewhere, either move it into the models/ folder of the release, or set"
say "  \"model\": { \"file\": \"<name>.gguf\" }   in config/config.json"
