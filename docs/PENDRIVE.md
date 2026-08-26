# Preparing the pendrive

Formatting the drive and copying a release onto it.

[← All documentation](README.md) · [Project home](../README.md)

---

Two things happen here, in this order: **format the drive**, then copy the release
onto it. Do not skip the formatting step, because it is what decides whether a
Linux user can run the launcher at all.

- [Format the pendrive first](#format-the-pendrive-first-do-this-before-anything-else)
- [From zero to chatting: the full checklist](#from-zero-to-chatting-the-full-checklist)
- [Copying the release folder](#copying-the-release-folder)

## Format the pendrive first (do this before anything else)

> ### WARNING
>
> **Formatting ERASES EVERYTHING on the drive.** Back up anything you care about
> first. You must identify the correct device before you type a format command.
> Getting the device wrong destroys the wrong disk, and there is no undo.

## Why format at all

**exFAT is the recommended format.**

Measured on the real test drive: it arrived as FAT32 mounted with the `showexec`
option, and under that mount a compiled Linux binary **could not be executed**.
`./binary` returned "Permission denied", and `chmod +x` had no effect. FAT32 also
caps any single file at 4 GiB.

exFAT fixes both problems. It allows direct execution on Linux, it has no
practical file-size cap, and it is readable on Windows, macOS and Linux.

Neither FAT32 nor exFAT supports symlinks. That limitation does not go away with
exFAT, and it is why the packaging step dereferences the llama.cpp library
symlinks into real files (see [Building the release](BUILD.md#building-the-release)).

The other two obvious candidates were rejected:

| Filesystem | Verdict |
|---|---|
| **exFAT** | Recommended. Execution allowed on Linux, no practical file-size cap, readable on Windows, macOS and Linux |
| **FAT32** | Works, with caveats. No Linux execution under `showexec`, and a hard 4 GiB per-file limit |
| **NTFS** | Poor choice for cross-platform use. Linux write support is possible, but permissions and safe-eject behaviour are worse |
| **ext4** | Linux only. Unreadable on stock Windows |

## Linux, command line

**Step 1. Identify the device.**

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,MODEL,TRAN,RM
```

What to look for in that output:

- `TRAN` is `usb`.
- `RM` is `1`, meaning removable.
- `SIZE` matches your pendrive.

**Never pick the disk that holds `/` or `/boot`.** Check the `MOUNTPOINT` column
before you do anything else. The whole device looks like `/dev/sdb` and the
partition on it looks like `/dev/sdb1`. Every command below uses `/dev/sdX1` as a
placeholder: substitute your real partition, and do not copy the placeholder
literally.

**Step 2. Install the exFAT tools.**

```bash
sudo apt install exfatprogs        # Debian, Ubuntu
sudo dnf install exfatprogs        # Fedora
sudo pacman -S exfatprogs          # Arch
```

**Step 3. Unmount the partition.**

```bash
udisksctl unmount -b /dev/sdX1
# or
sudo umount /dev/sdX1
```

**Step 4. Format it as exFAT with the label `PENAI`.**

```bash
sudo mkfs.exfat -n PENAI /dev/sdX1
```

**Step 5. Mount it again.**

Unplug and replug the drive, or mount it explicitly:

```bash
udisksctl mount -b /dev/sdX1
```

It will appear at something like `/media/<user>/PENAI` or
`/run/media/<user>/PENAI`. **The launcher does not care what that path is.**
It discovers its own root at runtime, so any mount point works, spaces included.

**Step 6, only if needed. Create a partition table.**

Do this only if the drive has no partition table at all, or a broken one:

```bash
sudo parted /dev/sdX -- mklabel msdos mkpart primary 1MiB 100%
```

Then format the newly created `/dev/sdX1` with Step 4. Note that this command
takes the whole device (`/dev/sdX`), not a partition.

**Step 7. Verify.**

```bash
lsblk -f
```

The partition should now show `exfat` as its filesystem and `PENAI` as its
label.

## Linux, GUI alternative

GNOME Disks:

```bash
gnome-disks
```

1. Pick the USB device in the left-hand list. Confirm the size and the model so
   you are certain it is the pendrive.
2. Use the menu to choose **Format Partition**.
3. For the type, choose **Other**, then **exFAT**.
4. Set the name to `PENAI`.

GParted also works, but it may need the `exfatprogs` package installed first
before exFAT appears as an option.

## Windows, File Explorer (simplest)

1. Open **This PC**, right-click the USB drive, and choose **Format**.
2. Set **File system** to **exFAT**. Leave **Allocation unit size** at default.
   Set **Volume label** to `PENAI`. Leave **Quick Format** checked.
3. Click **Start** and confirm. **This erases the drive.** Make sure the drive
   letter in the dialog title is the pendrive and not another disk.

## Windows, PowerShell alternative

Run PowerShell **as Administrator**.

First identify the right disk:

```powershell
Get-Disk
Get-Partition -DiskNumber <n>
```

**Verify the disk number and the size before continuing.** A wrong disk number
here formats the wrong drive.

Then format, replacing `E` with the real drive letter:

```powershell
Format-Volume -DriveLetter E -FileSystem exFAT -NewFileSystemLabel PENAI
```

`diskpart` also exists and can do this, but `Format-Volume` is safer for this
task because it operates on a volume you have already identified by letter rather
than on a selected disk.

## macOS

1. Open **Disk Utility**.
2. Select the **USB device**, not just the volume underneath it.
3. Click **Erase**.
4. Set **Format** to **ExFAT** and **Scheme** to **Master Boot Record**.
5. Name it `PENAI`.

macOS is mentioned here only for preparing the drive. **PenAI v1 does not
ship a macOS runtime**, so the drive you format on a Mac is for use on Linux or
Windows.

## If you cannot or will not reformat

Keeping FAT32 is a supported fallback. Two consequences.

**1. On Linux you must start it differently.**

```bash
sh StartAI.sh        # instead of ./StartAI
```

`StartAI.sh` stages the launcher and the llama.cpp runtime into a local temporary
directory, where execution is allowed, while still reading the model, the web
assets and the config from the pendrive. Roughly 45 MB is copied to local disk on
first run. The 2.50 GB model is never copied.

**Windows is unaffected on FAT32**, because `.exe` runs normally there.

**2. The 4 GiB per-file limit constrains which model you can carry.** The shipped
Q4_K_M at 2.50 GB fits FAT32 comfortably. The Q8_0 quantisation at 4.28 GB
**cannot be stored on FAT32 at all** and needs exFAT. See
[`models/README.md`](../models/README.md).

## From zero to chatting: the full checklist

The complete path, in order, from an unformatted pendrive to a working chat.

1. **Format the drive as exFAT with the label `PENAI`** ([Format the pendrive first](#format-the-pendrive-first-do-this-before-anything-else)).
2. **On a build machine:** clone the repository, and install Rust and Node.js
   (see [Development setup](DEVELOPMENT.md) for versions).
3. **Download the llama.cpp runtimes** (release `b10549`):
   ```bash
   bash scripts/fetch-runtime.sh --platform both
   ```
4. **Download the model** (2.50 GB Qwen3-4B-Instruct-2507-Q4_K_M GGUF) and verify
   its SHA-256:
   ```bash
   bash models/download-model.sh
   ```
5. **Build the launcher and the web UI**, and assemble the release tree at
   `release/linux/PenAI/`:
   ```bash
   bash scripts/build-linux.sh
   ```
6. **For Windows**, either run `scripts\build-windows.ps1` on a Windows machine,
   or cross-compile from Linux with mingw-w64 installed:
   ```bash
   bash scripts/build-windows-cross.sh
   ```
   To repeat the warning from the Status note: **`StartAI.exe` was not built or
   tested here.**
7. **Copy everything onto the drive:**
   ```bash
   bash scripts/deploy-to-pendrive.sh \
     --target /media/<user>/PENAI \
     --platform both \
     --model models/model.gguf
   ```
   The model copy is the slow part. The measured write speed on the test drive was
   3.4 MB/s, so a 2.5 GB model can take **over 10 minutes**. Let it finish.
8. **Eject safely:** `udisksctl unmount -b /dev/sdX1` on Linux, or "Safely Remove
   Hardware" on Windows.
9. **Plug the drive into the target computer.**
10. **Run the launcher.** Linux: `./StartAI` on exFAT, or `sh StartAI.sh` on
    FAT32. Windows: double-click `StartAI.exe`, or `StartAI.bat` if the exe was
    not built.
11. **Wait** for `PenAI is ready at http://127.0.0.1:8080`. The browser opens
    by itself.
12. **Chat.** Press Ctrl+C in the launcher window to stop.

## Copying the release folder

If you would rather copy by hand than use `deploy-to-pendrive.sh`, the release
folder is self-contained:

```bash
cp -r release/PenAI /media/<you>/PENAI/
sync
```

At 3.4 MB/s measured write speed, the 2.6 GB payload takes a while. **Wait for
`sync` to finish before unplugging.**

Release folder structure:

```
PenAI/
├── StartAI                  Linux launcher (native ELF)
├── StartAI.sh               Linux bootstrap for FAT32 / noexec mounts (sh StartAI.sh)
├── StartAI.exe              Windows launcher (build on Windows; not built here)
├── StartAI.bat              Windows zero-compile fallback launcher
├── .penai-root         root marker used for path discovery
├── runtime/
│   ├── linux/               llama-server + trimmed .so set
│   └── windows/             llama-server.exe + trimmed .dll set
├── models/
│   ├── model.gguf           the GGUF (not in git; downloaded separately)
│   └── README.md
├── web/                     Vite production build (index.html + assets/)
├── config/
│   └── config.json
├── data/
│   ├── chats/               portable chat history (chats.json)
│   └── logs/                rotating logs
└── README.md
```
