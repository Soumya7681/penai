#!/usr/bin/env bash
#
# deploy-to-pendrive.sh - copy a built PendriveAI release onto a drive.
#
# This script is deliberately conservative:
#   * --target is mandatory. It never guesses a mount point, because guessing
#     wrong means writing gigabytes onto the wrong disk.
#   * It never deletes anything on the target. No rm -rf, no rsync --delete.
#     Files that are already there and are not part of the release stay.
#   * It asks for a typed confirmation showing the exact destination path.
#
# Copying both platforms into the same PendriveAI/ folder is intentional: one
# drive then boots the assistant on Linux and on Windows.
#
# Usage:
#   scripts/deploy-to-pendrive.sh --target /path/to/mountpoint
#                                 [--platform linux|windows|both]
#                                 [--model <path-to.gguf>]
#                                 [--release <dir>] [--yes]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

TARGET=""
PLATFORM=""
MODEL=""
RELEASE_DIR="$ROOT/release"
ASSUME_YES=0

FAT32_MAX_FILE=$((4 * 1024 * 1024 * 1024 - 1))

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<USAGE
Usage: scripts/deploy-to-pendrive.sh --target <mountpoint> [options]

  --target <dir>                  REQUIRED. Where the drive is mounted, for
                                  example /media/you/MYDRIVE or /run/media/you/x
  --platform linux|windows|both   Which release(s) to copy (default: whichever
                                  are present under ${RELEASE_DIR})
  --model <path>                  Copy this .gguf to PendriveAI/models/model.gguf
  --release <dir>                 Release directory (default: ${RELEASE_DIR})
  --yes                           Skip the typed confirmation
  -h, --help                      Show this help

Find your mount point with:  lsblk -o NAME,LABEL,FSTYPE,SIZE,MOUNTPOINT
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

# ------------------------------------------------------------- arg parsing ----
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target) [ "$#" -ge 2 ] || die "--target needs a directory"; TARGET="$2"; shift 2 ;;
    --target=*) TARGET="${1#*=}"; shift ;;
    --platform) [ "$#" -ge 2 ] || die "--platform needs a value"; PLATFORM="$2"; shift 2 ;;
    --platform=*) PLATFORM="${1#*=}"; shift ;;
    --model) [ "$#" -ge 2 ] || die "--model needs a path"; MODEL="$2"; shift 2 ;;
    --model=*) MODEL="${1#*=}"; shift ;;
    --release) [ "$#" -ge 2 ] || die "--release needs a directory"; RELEASE_DIR="$2"; shift 2 ;;
    --release=*) RELEASE_DIR="${1#*=}"; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

if [ -z "$TARGET" ]; then
  usage >&2
  die "--target is required. This script never guesses a mount point: writing
    several gigabytes to the wrong path is not something to risk on a guess.
    List your drives with:  lsblk -o NAME,LABEL,FSTYPE,SIZE,MOUNTPOINT"
fi

# ------------------------------------------------------------ target checks ----
step "Checking the target"
[ -e "$TARGET" ] || die "target does not exist: $TARGET
    Is the drive actually mounted? Check with: lsblk -o NAME,LABEL,MOUNTPOINT"
[ -d "$TARGET" ] || die "target is not a directory: $TARGET"
[ -w "$TARGET" ] || die "target is not writable: $TARGET
    Either it is mounted read-only, or it belongs to another user. Check with:
      findmnt -no FSTYPE,OPTIONS --target '$TARGET'"

TARGET_ABS="$(cd "$TARGET" && pwd)"
say "target: $TARGET_ABS"

FSTYPE=""
if have findmnt; then
  FSTYPE="$(findmnt -no FSTYPE --target "$TARGET_ABS" 2>/dev/null || true)"
fi
if [ -z "$FSTYPE" ]; then
  FSTYPE="$(stat -f -c %T "$TARGET_ABS" 2>/dev/null || true)"
fi
[ -n "$FSTYPE" ] || FSTYPE="unknown"
say "filesystem: $FSTYPE"

MOUNT_OPTS=""
if have findmnt; then
  MOUNT_OPTS="$(findmnt -no OPTIONS --target "$TARGET_ABS" 2>/dev/null || true)"
  [ -n "$MOUNT_OPTS" ] && say "mount options: $MOUNT_OPTS"
fi

FS_IS_FAT=0
case "$FSTYPE" in
  vfat|msdos|fat|fat32|fuseblk_vfat)
    FS_IS_FAT=1
    say ""
    say "**********************************************************************"
    say "* This drive is FAT32/msdos. Two consequences you must know about:   *"
    say "*                                                                    *"
    say "* 1. The compiled Linux launcher CANNOT be executed from this drive. *"
    say "*    FAT has no execute permission bit, so Linux mounts it with      *"
    say "*    'showexec' or 'noexec' and refuses to run ./StartAI.            *"
    say "*    Start it with:   sh StartAI.sh                                  *"
    say "*    That script copies the launcher and runtime/linux to local disk *"
    say "*    (about 45 MB, once) and runs it from there, while still reading *"
    say "*    the model, UI, config and chats from this drive.                *"
    say "*    Windows is unaffected: StartAI.exe and StartAI.bat both work.   *"
    say "*                                                                    *"
    say "* 2. No single file above 4 GiB can exist on FAT32 at all. The       *"
    say "*    reference model (about 2.33 GiB) is fine, but a larger          *"
    say "*    quantisation such as Q8_0 or F16 is impossible here.            *"
    say "*    Reformat as exFAT if you need bigger files.                     *"
    say "**********************************************************************"
    ;;
  exfat)
    say "exFAT: direct execution should work, so ./StartAI can be run from the drive."
    say "       (StartAI.sh is still shipped as a fallback for noexec mounts.)"
    ;;
  ext2|ext3|ext4|btrfs|xfs|f2fs)
    say "A native Linux filesystem: permissions and symlinks work normally."
    say "Note that Windows cannot read $FSTYPE without extra drivers, so this"
    say "drive will be Linux-only in practice."
    ;;
  ntfs|ntfs3|fuseblk)
    say "NTFS-like filesystem. Windows is fine. On Linux, execution depends on the"
    say "mount options above; if ./StartAI is refused, use 'sh StartAI.sh'."
    ;;
  *)
    say "Unrecognised filesystem type '$FSTYPE'. If ./StartAI is refused on Linux,"
    say "use 'sh StartAI.sh' instead."
    ;;
esac

case "$MOUNT_OPTS" in
  *noexec*)
    say ""
    warn "this mount has 'noexec': nothing on the drive can be executed directly.
  On Linux always start with 'sh StartAI.sh'." ;;
esac

# ----------------------------------------------------------- what to copy ------
[ -d "$RELEASE_DIR" ] || die "release directory not found: $RELEASE_DIR
    Build one first:  scripts/build-linux.sh   (or scripts/package.sh)"

SRC_LINUX="$RELEASE_DIR/linux/PendriveAI"
SRC_WINDOWS="$RELEASE_DIR/windows/PendriveAI"

if [ -z "$PLATFORM" ]; then
  if [ -d "$SRC_LINUX" ] && [ -d "$SRC_WINDOWS" ]; then
    PLATFORM="both"
  elif [ -d "$SRC_LINUX" ]; then
    PLATFORM="linux"
  elif [ -d "$SRC_WINDOWS" ]; then
    PLATFORM="windows"
  else
    die "no release found under $RELEASE_DIR
    Expected $SRC_LINUX or $SRC_WINDOWS.
    Build one first:  scripts/build-linux.sh"
  fi
  say ""
  say "no --platform given; auto-detected: $PLATFORM"
fi

case "$PLATFORM" in
  linux|windows|both) ;;
  *) die "--platform must be linux, windows or both (got '$PLATFORM')" ;;
esac

SOURCES=()
case "$PLATFORM" in
  linux)   SOURCES=("$SRC_LINUX") ;;
  windows) SOURCES=("$SRC_WINDOWS") ;;
  both)    SOURCES=("$SRC_LINUX" "$SRC_WINDOWS") ;;
esac

for s in "${SOURCES[@]}"; do
  [ -d "$s" ] || die "release folder missing: $s
    Build it first (scripts/build-linux.sh, scripts/build-windows-cross.sh, or
    scripts/build-windows.ps1 on Windows)."
  [ -f "$s/.pendriveai-root" ] || warn "$s has no .pendriveai-root marker; is it really a packaged release?"
done

if [ -n "$MODEL" ]; then
  [ -f "$MODEL" ] || die "--model is not a file: $MODEL"
fi

# ---------------------------------------------------------------- sizes --------
step "Sizes"
PAYLOAD=0
for s in "${SOURCES[@]}"; do
  b="$(path_bytes "$s")"
  PAYLOAD=$((PAYLOAD + b))
  say "  $(printf '%-52s' "$s") $(human "$b")"
done

MODEL_BYTES=0
if [ -n "$MODEL" ]; then
  MODEL_BYTES="$(file_bytes "$MODEL")"
  say "  $(printf '%-52s' "$MODEL") $(human "$MODEL_BYTES")"
  if [ "$FS_IS_FAT" -eq 1 ] && [ "$MODEL_BYTES" -gt "$FAT32_MAX_FILE" ]; then
    die "the model is $(human "$MODEL_BYTES"), above the 4 GiB per-file limit of FAT32.
    It cannot be stored on this drive at all. Use a smaller quantisation
    (models/download-model.sh --quant Q4_K_M) or reformat the drive as exFAT."
  fi
fi

TOTAL=$((PAYLOAD + MODEL_BYTES))
say "  ----"
say "  $(printf '%-52s' 'total to copy') $(human "$TOTAL")"

# Any oversized file at all is fatal on FAT32.
if [ "$FS_IS_FAT" -eq 1 ]; then
  big="$(find "${SOURCES[@]}" -type f -size +4194303k -print -quit 2>/dev/null || true)"
  if [ -n "$big" ]; then
    die "this file is larger than FAT32 allows (4 GiB): $big"
  fi
fi

AVAIL_KB="$(df -Pk "$TARGET_ABS" | awk 'NR==2 {print $4}')"
[ -n "$AVAIL_KB" ] || die "could not determine free space on $TARGET_ABS"
AVAIL=$((AVAIL_KB * 1024))
say "  $(printf '%-52s' 'free on target') $(human "$AVAIL")"

# A little headroom: filesystem metadata and cluster rounding both cost space.
NEED=$((TOTAL + 32 * 1024 * 1024))
if [ "$AVAIL" -lt "$NEED" ]; then
  die "not enough free space on $TARGET_ABS
    need about $(human "$NEED") (payload plus 32 MiB headroom)
    free      $(human "$AVAIL")
    Nothing was copied. Free up space, or deploy a single platform with
    --platform linux, or leave the model out and download it on the target later."
fi

# ---------------------------------------------------------- confirmation -------
DEST="$TARGET_ABS/PendriveAI"
step "About to write"
say "  from:  ${SOURCES[*]}"
[ -n "$MODEL" ] && say "  model: $MODEL"
say "  to:    $DEST"
say ""
say "Existing files with the same names in that folder will be OVERWRITTEN."
say "Nothing else on $TARGET_ABS is touched: this script never deletes anything."

if [ "$ASSUME_YES" -eq 0 ]; then
  printf 'Type exactly "yes" to continue, anything else to abort: '
  read -r reply || reply=""
  if [ "$reply" != "yes" ]; then
    say "Aborted. Nothing was written."
    exit 1
  fi
else
  say "(--yes given, skipping confirmation)"
fi

# ------------------------------------------------------------------ copy -------
mkdir -p "$DEST" || die "cannot create $DEST"

copy_dir() {
  # copy_dir <src-dir> <dest-dir>
  local src="$1" dest="$2"
  if have rsync; then
    # -rlt without -a: the target may be FAT32, where owners and permission
    # bits cannot be stored and rsync would print an error for every file.
    # -L dereferences any symlink, which FAT/exFAT cannot store.
    # No --delete: files already on the drive are never removed.
    rsync -rLt --no-perms --no-owner --no-group --human-readable --info=progress2 \
      "$src"/ "$dest"/ || die "rsync failed while copying $src"
  else
    say "rsync not found; falling back to 'cp -RL' (no progress display, be patient)."
    cp -RL "$src"/. "$dest"/ || die "cp failed while copying $src"
  fi
}

for s in "${SOURCES[@]}"; do
  step "Copying $(basename "$(dirname "$s")") release"
  copy_dir "$s" "$DEST"
done

if [ -n "$MODEL" ]; then
  step "Copying the model"
  say "This is the slow part: $(human "$MODEL_BYTES") over USB."
  say "On a USB 2.0 stick at 10 MB/s that is roughly $((MODEL_BYTES / 10485760 / 60)) minutes."
  say "Do NOT unplug the drive until this finishes and 'sync' has completed."
  mkdir -p "$DEST/models"
  if have rsync; then
    rsync -Lt --no-perms --no-owner --no-group --human-readable --info=progress2 \
      "$MODEL" "$DEST/models/model.gguf" || die "failed to copy the model"
  else
    cp -L "$MODEL" "$DEST/models/model.gguf" || die "failed to copy the model"
  fi
  say "model in place: $DEST/models/model.gguf ($(human "$(file_bytes "$DEST/models/model.gguf")"))"
fi

# Best-effort exec bits. They simply do not exist on FAT.
for f in "$DEST/StartAI" "$DEST"/*.sh "$DEST/runtime/linux/llama-server"; do
  [ -e "$f" ] || continue
  chmod +x "$f" 2>/dev/null || true
done

# ------------------------------------------------------------------ finish -----
step "Flushing writes"
say "running sync (this can take a while on a slow drive; that is normal)"
sync
say "sync done."

step "Done"
say "Deployed to: $DEST"
say "Contents:"
find "$DEST" -mindepth 1 -maxdepth 1 -print | sort | sed "s|^|  |"
say ""
if [ ! -f "$DEST/models/model.gguf" ] && [ -z "$(find "$DEST/models" -maxdepth 1 -name '*.gguf' -print -quit 2>/dev/null)" ]; then
  warn "there is no .gguf model in $DEST/models yet, so it will not start.
  Add one with models/download-model.sh --dest '$DEST/models/model.gguf',
  or re-run this script with --model <path>."
fi
say "Start it on Linux with:    cd '$DEST' && sh StartAI.sh"
say "Start it on Windows with:  StartAI.exe  (or StartAI.bat if the exe is absent)"
say ""
say "EJECT SAFELY before unplugging, or the last writes may be lost:"
say "  use your file manager's Eject/Safely Remove, or run:"
say "    udisksctl unmount -b <device>    (find it with lsblk)"
