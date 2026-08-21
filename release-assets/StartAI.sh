#!/bin/sh
#
# StartAI.sh - Linux bootstrap for PendriveAI.
#
# WHY THIS EXISTS
#   A FAT32 filesystem has no execute permission bit. Linux therefore mounts it
#   with `showexec` (only .exe/.com/.bat get the bit) or plainly with `noexec`,
#   and refuses to run the compiled ./StartAI from the drive. exFAT is usually
#   fine, FAT32 usually is not, and you cannot tell from the file listing:
#   `ls -l` can happily show `rwxr-xr-x` on a mount that still denies exec.
#
# WHAT IT DOES
#   1. Actually tries to execute ./StartAI (running it with --version, which is
#      cheap). If the kernel allows it, the real launcher is exec'd immediately
#      and this script gets out of the way.
#   2. If exec is refused, it stages a runnable copy on local disk: the launcher
#      binary plus runtime/linux (about 45 MB, once) are copied into a private
#      directory. Nothing else moves. The launcher is then started with
#      PENDRIVEAI_ROOT pointing at the drive and --runtime-dir pointing at the
#      staged runtime, so executables run from local disk while the model, the
#      UI, your config and your chats are still read from and written to the
#      drive. The model is never copied or linked: it is gigabytes.
#   3. Later launches re-use the staged copy. Files whose size already matches
#      are not copied again, so the second start is fast.
#
# POSIX sh only, because it is meant to be run as `sh StartAI.sh` on a drive
# where nothing is executable. No bashisms, and no sudo anywhere: everything
# happens inside your own user's directories.
#
# Usage:  sh StartAI.sh [any StartAI options, forwarded as-is]
#         sh StartAI.sh --help
#
# Override the staging location with PENDRIVEAI_STAGE=/some/local/dir
#

set -u

ROOT=$(cd "$(dirname "$0")" && pwd) || {
    echo "StartAI.sh: cannot determine my own directory" >&2
    exit 1
}

LAUNCHER="$ROOT/StartAI"
RUNTIME_SRC="$ROOT/runtime/linux"

echo "PendriveAI launcher (Linux bootstrap)"
echo "  drive root: $ROOT"

# ---------------------------------------------------------------- sanity ------
if [ ! -f "$LAUNCHER" ]; then
    echo "" >&2
    echo "ERROR: $LAUNCHER does not exist." >&2
    echo "  This release has no compiled Linux launcher. Either it was packaged" >&2
    echo "  for Windows only, or the copy to this drive was incomplete." >&2
    echo "  Rebuild with scripts/build-linux.sh, or re-copy the release." >&2
    exit 1
fi

if [ ! -d "$RUNTIME_SRC" ] || [ ! -f "$RUNTIME_SRC/llama-server" ]; then
    echo "" >&2
    echo "ERROR: $RUNTIME_SRC/llama-server is missing." >&2
    echo "  The llama.cpp runtime is not on this drive, so there is nothing to" >&2
    echo "  run the model with. Re-package with scripts/fetch-runtime.sh" >&2
    echo "  --platform linux followed by scripts/package.sh." >&2
    exit 1
fi

# --------------------------------------------- 1. try the drive directly ------
# `[ -x ]` is not trustworthy here: a FAT32 mount can report the execute bit and
# still refuse to exec. The only reliable test is to try. Exit status 126 means
# "found but cannot execute", 127 means "not found"; anything else means the
# binary really did run.
"$LAUNCHER" --version >/dev/null 2>&1
probe=$?

if [ "$probe" -ne 126 ] && [ "$probe" -ne 127 ]; then
    echo "  this drive allows direct execution; starting ./StartAI"
    exec "$LAUNCHER" "$@"
fi

echo "  this drive refuses to execute ./StartAI (exit $probe)."
echo "  That is normal on FAT32 (mounted with showexec) and on any noexec mount."
echo "  Falling back to running from local disk."

# --------------------------------------------- 2. pick a staging directory ----
# Preference order: the per-user runtime directory (tmpfs, cleaned on logout),
# then TMPDIR, then /tmp. All are inside this user's own space; no sudo, ever.
if [ -n "${PENDRIVEAI_STAGE:-}" ]; then
    STAGE="$PENDRIVEAI_STAGE"
elif [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] && [ -w "$XDG_RUNTIME_DIR" ]; then
    STAGE="$XDG_RUNTIME_DIR/pendriveai"
else
    STAGE="${TMPDIR:-/tmp}/pendriveai-$(id -u)"
fi

if ! mkdir -p "$STAGE" 2>/dev/null; then
    echo "" >&2
    echo "ERROR: cannot create the staging directory $STAGE" >&2
    echo "  Set PENDRIVEAI_STAGE to a writable local directory and try again:" >&2
    echo "    PENDRIVEAI_STAGE=\"\$HOME/.cache/pendriveai\" sh StartAI.sh" >&2
    exit 1
fi
chmod 700 "$STAGE" 2>/dev/null || true

# The launcher plus the runtime is about 45 MB. XDG_RUNTIME_DIR is a small
# tmpfs on some systems, so check there is room and fall back if not.
avail_kb=$(df -Pk "$STAGE" 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "${avail_kb:-}" ] && [ "$avail_kb" -lt 122880 ]; then
    echo "  only ${avail_kb} KiB free in $STAGE; using \${TMPDIR:-/tmp} instead."
    STAGE="${TMPDIR:-/tmp}/pendriveai-$(id -u)"
    mkdir -p "$STAGE" 2>/dev/null || {
        echo "ERROR: cannot create $STAGE either. Set PENDRIVEAI_STAGE and retry." >&2
        exit 1
    }
    chmod 700 "$STAGE" 2>/dev/null || true
fi

echo ""
echo "Staging a runnable copy on local disk:"
echo "  $STAGE"
echo "  About 45 MB is copied the first time (the launcher and the llama.cpp"
echo "  runtime). The model is NOT copied: it stays on the drive and is read"
echo "  from there, along with the UI, your config and your chats."

# --------------------------------------------- 3. copy launcher + runtime -----
copied=0
skipped=0

copy_one() {
    # copy_one <src-file> <dst-file>; skips when the size already matches.
    cp_src=$1
    cp_dst=$2
    if [ -f "$cp_dst" ]; then
        s_src=$(wc -c < "$cp_src" 2>/dev/null | tr -d ' ')
        s_dst=$(wc -c < "$cp_dst" 2>/dev/null | tr -d ' ')
        if [ -n "$s_src" ] && [ "$s_src" = "$s_dst" ]; then
            skipped=$((skipped + 1))
            return 0
        fi
    fi
    # -L dereferences: FAT32/exFAT cannot hold symlinks, but a release copied
    # from a Linux filesystem might, and the staged copy must be a real file.
    if ! cp -L -f "$cp_src" "$cp_dst" 2>/dev/null; then
        echo "ERROR: failed to copy $cp_src -> $cp_dst" >&2
        return 1
    fi
    copied=$((copied + 1))
    return 0
}

copy_one "$LAUNCHER" "$STAGE/StartAI" || exit 1

if ! mkdir -p "$STAGE/runtime/linux" 2>/dev/null; then
    echo "ERROR: cannot create $STAGE/runtime/linux" >&2
    exit 1
fi

for f in "$RUNTIME_SRC"/*; do
    [ -f "$f" ] || continue
    copy_one "$f" "$STAGE/runtime/linux/$(basename "$f")" || exit 1
done

echo "  copied $copied file(s), reused $skipped already-staged file(s)"

# Execute bits, on a filesystem that can actually store them.
chmod 755 "$STAGE/StartAI" 2>/dev/null || {
    echo "ERROR: cannot make $STAGE/StartAI executable." >&2
    echo "  Is $STAGE itself on a noexec filesystem? Set PENDRIVEAI_STAGE to a" >&2
    echo "  normal local directory, for example:" >&2
    echo "    PENDRIVEAI_STAGE=\"\$HOME/.cache/pendriveai\" sh StartAI.sh" >&2
    exit 1
}
chmod 755 "$STAGE/runtime/linux/llama-server" 2>/dev/null || {
    echo "ERROR: cannot make $STAGE/runtime/linux/llama-server executable." >&2
    echo "  Set PENDRIVEAI_STAGE to a normal local directory and retry." >&2
    exit 1
}

# --------------------------------------------------------- 4. run it ----------
# No symlink mirror is needed, and the model is never copied or linked.
#
# PENDRIVEAI_ROOT keeps every project path on the drive (models, web, config,
# data). --runtime-dir points ONLY the llama.cpp lookup at the staged, executable
# copy. That removes the whole class of "the staging filesystem cannot hold
# symlinks" failures that a mirror approach has to cope with.

# data/ may be absent on a freshly copied release. Create it on the drive so
# chats and logs land there instead of being silently dropped.
if ! mkdir -p "$ROOT/data/chats" "$ROOT/data/logs" 2>/dev/null; then
    echo "  note: $ROOT/data is not writable, so logs and portable chat history"
    echo "        are disabled for this run. The chat UI still works."
fi

PENDRIVEAI_ROOT="$ROOT"
export PENDRIVEAI_ROOT

echo ""
echo "Starting PendriveAI"
echo "  launcher:   $STAGE/StartAI            (staged on local disk, executable)"
echo "  runtime:    $STAGE/runtime/linux      (staged on local disk, executable)"
echo "  drive root: $ROOT"
echo "              model, web UI, config and chat history all stay here"
echo ""

# exec replaces this shell, so Ctrl+C reaches the launcher directly and the
# launcher's exit code becomes this script's exit code.
exec "$STAGE/StartAI" --runtime-dir "$STAGE/runtime/linux" "$@"
