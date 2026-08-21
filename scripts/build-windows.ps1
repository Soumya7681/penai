<#
.SYNOPSIS
    Full Windows release build for PendriveAI, run ON Windows.

.DESCRIPTION
    Steps: check tools -> run the launcher tests -> build StartAI.exe with the
    MSVC toolchain -> build the React UI -> check the llama.cpp Windows runtime
    is staged -> assemble release\windows\PendriveAI with exactly the same
    layout that scripts/package.sh produces on Linux.

    The cargo target directory defaults to a scratch directory outside the
    repository, because this repository is designed to live on a USB drive and a
    FAT32/exFAT filesystem is a poor host for a Rust build cache (hundreds of
    thousands of small files, no hard links). Override it with the environment
    variable PENDRIVEAI_CARGO_TARGET_DIR.

    Prerequisites:
      * Rust with the MSVC toolchain (https://rustup.rs) plus the
        "Desktop development with C++" workload from the Visual Studio Build
        Tools, which provides link.exe.
      * Node.js 18 or newer (for npm), unless -SkipWeb is used.
      * The staged runtime: scripts\fetch-runtime.ps1

.PARAMETER SkipTests
    Do not run 'cargo test --release'.

.PARAMETER SkipWeb
    Do not rebuild web\dist; reuse whatever is already there.

.PARAMETER Model
    Path to a .gguf file to copy into the release as models\model.gguf.

.PARAMETER Version
    Version string for .pendriveai-root. Defaults to the version in
    launcher\Cargo.toml.

.PARAMETER Out
    Output directory. Default: <repo>\release

.PARAMETER Force
    Overwrite a non-empty release\windows\PendriveAI directory.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1
    powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1 -Model D:\model.gguf -Force
#>

[CmdletBinding()]
param(
    [switch] $SkipTests,
    [switch] $SkipWeb,
    [string] $Model = '',
    [string] $Version = '',
    [string] $Out = '',
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root      = Split-Path -Parent $ScriptDir

# Verified facts about the reference model, used for the size report and the
# optional checksum comparison.
$ModelBytes    = 2497281120
$ModelSha256   = '3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597'
$ModelFileName = 'Qwen3-4B-Instruct-2507-Q4_K_M.gguf'
$ModelUrl      = "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/$ModelFileName"
# An "8 GB" USB stick gives about 7.3 GiB of usable space.
$DriveUsableBytes = 7838315315

function Say  ([string] $m) { Write-Host $m }
function Step ([string] $m) { Write-Host ''; Write-Host "==> $m" }
function Warn ([string] $m) { Write-Warning $m }
function Die  ([string] $m) { Write-Host ''; Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

function Format-Bytes ([long] $b) {
    if ($b -ge 1GB) { return ('{0:N2} GiB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N2} MiB' -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ('{0:N0} KiB' -f ($b / 1KB)) }
    return "$b B"
}

function Get-TreeBytes ([string] $path) {
    if (-not (Test-Path -LiteralPath $path)) { return [long] 0 }
    if (Test-Path -LiteralPath $path -PathType Leaf) { return [long] (Get-Item -LiteralPath $path).Length }
    $sum = (Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return [long] 0 }
    return [long] $sum
}

function Invoke-Checked ([string] $exe, [string[]] $arguments, [string] $what, [string] $hint) {
    Say "> $exe $($arguments -join ' ')"
    & $exe @arguments
    if ($LASTEXITCODE -ne 0) {
        Die "$what failed (exit code $LASTEXITCODE).`n$hint"
    }
}

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Die "PowerShell 5 or newer is required (this is $($PSVersionTable.PSVersion))."
}

Say 'PendriveAI Windows build'
Say "  repo root: $Root"

# ------------------------------------------------------------- tool checks -----
Step 'Checking tools'
$cargo = Get-Command cargo -ErrorAction SilentlyContinue
if (-not $cargo) {
    Die @"
cargo was not found on PATH.
Install Rust with the MSVC toolchain from https://rustup.rs and also install the
Visual Studio Build Tools with the "Desktop development with C++" workload,
which provides the linker (link.exe). Then open a new terminal and retry.
"@
}
Say "cargo: $($cargo.Source)"
& $cargo.Source --version | ForEach-Object { Say "  $_" }

if (-not $SkipWeb) {
    $npm = Get-Command npm -ErrorAction SilentlyContinue
    if (-not $npm) {
        Die @"
npm was not found on PATH.
Install Node.js 18 or newer from https://nodejs.org (the LTS installer includes
npm), open a new terminal and retry. If web\dist is already built you can pass
-SkipWeb instead.
"@
    }
    Say "npm:   $($npm.Source)"
}

# ---------------------------------------------------------- build directory ----
$scratchRoot = if ($env:PENDRIVEAI_SCRATCH_DIR) { $env:PENDRIVEAI_SCRATCH_DIR } else { Join-Path $env:TEMP 'pendriveai-build' }
$targetDir = if ($env:PENDRIVEAI_CARGO_TARGET_DIR) {
    $env:PENDRIVEAI_CARGO_TARGET_DIR
} elseif ($env:CARGO_TARGET_DIR) {
    $env:CARGO_TARGET_DIR
} else {
    Join-Path $scratchRoot 'cargo'
}
New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
$env:CARGO_TARGET_DIR = $targetDir

Step 'Build directories'
Say "cargo target dir: $targetDir"
Say '  Reason: the repo may live on a FAT32/exFAT USB drive, which is a bad host'
Say '  for a Rust build cache. Override with PENDRIVEAI_CARGO_TARGET_DIR.'
Say "scratch root:     $scratchRoot"

$manifest = Join-Path $Root 'launcher\Cargo.toml'
if (-not (Test-Path -LiteralPath $manifest)) { Die "launcher manifest not found: $manifest" }

# ------------------------------------------------------------ test + build -----
if (-not $SkipTests) {
    Step 'Running launcher tests (cargo test --release)'
    Say '> cargo test --release'
    & $cargo.Source test --release --manifest-path $manifest
    if ($LASTEXITCODE -ne 0) {
        Die @"
Launcher tests FAILED. The build is aborted on purpose: a launcher that fails
its own path, config, port and process tests must not be shipped on a drive that
people carry around. Fix the tests, or pass -SkipTests if you know exactly why
you are bypassing them.
"@
    }
} else {
    Warn 'skipping cargo tests (-SkipTests)'
}

Step 'Building the launcher (cargo build --release)'
Invoke-Checked $cargo.Source @('build', '--release', '--manifest-path', $manifest) 'cargo build' @"
Scroll up for the compiler error. A missing link.exe means the Visual Studio
Build Tools "Desktop development with C++" workload is not installed.
"@

$exePath = Join-Path $targetDir 'release\StartAI.exe'
if (-not (Test-Path -LiteralPath $exePath)) {
    Die @"
The build reported success but $exePath does not exist.
The [[bin]] name in launcher\Cargo.toml must stay 'StartAI'.
"@
}
Say "built: $exePath ($(Format-Bytes (Get-Item -LiteralPath $exePath).Length))"

# ------------------------------------------------------------- web build -------
$webDir  = Join-Path $Root 'web'
$distDir = Join-Path $webDir 'dist'

if ($SkipWeb) {
    Step 'Web UI'
    Warn 'skipping the web build (-SkipWeb)'
    if (-not (Test-Path -LiteralPath (Join-Path $distDir 'index.html'))) {
        Die "-SkipWeb was given but $distDir\index.html does not exist, so there is nothing to package."
    }
    Say "reusing existing $distDir"
} else {
    Step 'Building the web UI'
    $npmCmd = (Get-Command npm).Source
    Push-Location $webDir
    try {
        if (Test-Path -LiteralPath (Join-Path $webDir 'package-lock.json')) {
            Say '> npm ci'
            & $npmCmd ci
        } else {
            Warn "no package-lock.json in $webDir; using 'npm install' (versions are not pinned)."
            Say '> npm install'
            & $npmCmd install
        }
        if ($LASTEXITCODE -ne 0) {
            Die @"
npm dependency installation failed (exit code $LASTEXITCODE).
If the repository is on a FAT32/exFAT drive, node_modules can be problematic
there: copy the web folder to a local disk, run 'npm ci; npm run build' there,
copy dist back into $distDir, and re-run this script with -SkipWeb.
"@
        }
        Say '> npm run build'
        & $npmCmd run build
        if ($LASTEXITCODE -ne 0) { Die "npm run build failed (exit code $LASTEXITCODE). Scroll up for the TypeScript or Vite error." }
    } finally {
        Pop-Location
    }
    if (-not (Test-Path -LiteralPath (Join-Path $distDir 'index.html'))) {
        Die "the web build finished but $distDir\index.html is missing."
    }
    Say "web build ready: $distDir ($(Format-Bytes (Get-TreeBytes $distDir)))"
}

# ---------------------------------------------------------- runtime check ------
Step 'Checking the llama.cpp runtime'
$runtimeSrc = Join-Path $Root 'runtime\windows'
$serverExe  = Join-Path $runtimeSrc 'llama-server.exe'
if (-not (Test-Path -LiteralPath $serverExe)) {
    Die @"
$serverExe is missing.
Fix: run  powershell -ExecutionPolicy Bypass -File scripts\fetch-runtime.ps1
It downloads the llama.cpp b10549 Windows CPU build and stages the minimal DLL
set into runtime\windows.
"@
}
Say "found $serverExe"
$versionFile = Join-Path $runtimeSrc 'RUNTIME_VERSION.txt'
if (Test-Path -LiteralPath $versionFile) {
    Get-Content -LiteralPath $versionFile | ForEach-Object { Say "  $_" }
}

# ------------------------------------------------------------- assemble --------
if ([string]::IsNullOrWhiteSpace($Out)) { $Out = Join-Path $Root 'release' }
if ([string]::IsNullOrWhiteSpace($Version)) {
    $line = Select-String -LiteralPath $manifest -Pattern '^version\s*=\s*"([^"]+)"' | Select-Object -First 1
    if ($line) { $Version = $line.Matches[0].Groups[1].Value } else { $Version = '0.0.0-unknown' }
}
$dest = Join-Path $Out 'windows\PendriveAI'
$stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

Step "Assembling $dest"
Say "version: $Version"

if (Test-Path -LiteralPath $dest) {
    $existing = Get-ChildItem -LiteralPath $dest -Force -ErrorAction SilentlyContinue
    if ($existing -and $existing.Count -gt 0) {
        if (-not $Force) {
            Die @"
Output directory is not empty: $dest
Refusing to mix a new release into an old one. Re-run with -Force to overwrite
it, or choose another location with -Out <dir>.
"@
        }
        Warn "overwriting non-empty $dest (-Force)"
        Remove-Item -LiteralPath $dest -Recurse -Force
    }
}
New-Item -ItemType Directory -Force -Path $dest | Out-Null

# StartAI.exe and the no-compiler fallback launcher.
Copy-Item -LiteralPath $exePath -Destination (Join-Path $dest 'StartAI.exe') -Force
$batSrc = Join-Path $Root 'release-assets\StartAI.bat'
if (-not (Test-Path -LiteralPath $batSrc)) { Die "missing $batSrc" }
Copy-Item -LiteralPath $batSrc -Destination (Join-Path $dest 'StartAI.bat') -Force

# runtime\windows
$runtimeDest = Join-Path $dest 'runtime\windows'
New-Item -ItemType Directory -Force -Path $runtimeDest | Out-Null
Copy-Item -Path (Join-Path $runtimeSrc '*') -Destination $runtimeDest -Recurse -Force

# web (contents of web\dist)
$webDest = Join-Path $dest 'web'
New-Item -ItemType Directory -Force -Path $webDest | Out-Null
Copy-Item -Path (Join-Path $distDir '*') -Destination $webDest -Recurse -Force

# config\config.json from config\config.example.json
$configSrc = Join-Path $Root 'config\config.example.json'
if (-not (Test-Path -LiteralPath $configSrc)) { Die "missing $configSrc - it is the source of config\config.json." }
New-Item -ItemType Directory -Force -Path (Join-Path $dest 'config') | Out-Null
Copy-Item -LiteralPath $configSrc -Destination (Join-Path $dest 'config\config.json') -Force

# models\README.md
$modelsDest = Join-Path $dest 'models'
New-Item -ItemType Directory -Force -Path $modelsDest | Out-Null
$modelsReadmeSrc = Join-Path $Root 'models\README.md'
if (Test-Path -LiteralPath $modelsReadmeSrc) {
    Copy-Item -LiteralPath $modelsReadmeSrc -Destination (Join-Path $modelsDest 'README.md') -Force
} else {
    Warn 'models\README.md is missing from the repo; writing a minimal one into the release.'
    $mr = @"
# PendriveAI model directory

Put a GGUF model file here. The launcher uses ``model.gguf`` if it exists,
otherwise the largest ``.gguf`` file in this directory.

Reference model used by PendriveAI:

- repository: unsloth/Qwen3-4B-Instruct-2507-GGUF
- file: $ModelFileName
- size: $ModelBytes bytes
- SHA-256: $ModelSha256
- licence: Apache-2.0 (not gated, no authentication needed)
- URL: $ModelUrl

Download it with models\download-model.ps1 (Windows) or models/download-model.sh
(Linux/macOS) from the source repository, then copy the result here as
model.gguf.
"@
    Set-Content -LiteralPath (Join-Path $modelsDest 'README.md') -Value $mr -Encoding UTF8
}

# README.md and LICENSE
$readmeSrc = Join-Path $Root 'README.md'
if (Test-Path -LiteralPath $readmeSrc) {
    Copy-Item -LiteralPath $readmeSrc -Destination (Join-Path $dest 'README.md') -Force
} else {
    Warn 'README.md is missing from the repo root; writing a minimal one into the release.'
    $rr = @"
# PendriveAI $Version

A fully offline AI assistant that runs from this drive. Nothing is sent to the
internet: the model, the llama.cpp server and the web UI all live in this folder
and talk to each other over 127.0.0.1 only.

## Start it

- Windows: run ``StartAI.exe``. If it is missing or misbehaves, run
  ``StartAI.bat``, which does the same job with cmd.exe and PowerShell only.
- Linux: run ``./StartAI`` if that release was also copied here, otherwise
  ``sh StartAI.sh``.

## Folders

- ``runtime\`` llama.cpp binaries and DLLs
- ``models\``  the .gguf model file
- ``web\``     the browser UI
- ``config\``  config.json, documented inside the file
- ``data\``    logs and saved chats

Built $stamp by scripts\build-windows.ps1.
"@
    Set-Content -LiteralPath (Join-Path $dest 'README.md') -Value $rr -Encoding UTF8
}
$licenseSrc = Join-Path $Root 'LICENSE'
if (Test-Path -LiteralPath $licenseSrc) {
    Copy-Item -LiteralPath $licenseSrc -Destination (Join-Path $dest 'LICENSE') -Force
} else {
    Warn 'no LICENSE file in the repo root; the release will not contain one.'
}

# data directories
foreach ($d in @('data\chats', 'data\logs')) {
    $p = Join-Path $dest $d
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    Set-Content -LiteralPath (Join-Path $p '.gitkeep') -Value '' -Encoding ASCII
}

# .pendriveai-root marker
$marker = @"
$Version
built: $stamp
platform: windows
packaged-by: scripts/build-windows.ps1
"@
Set-Content -LiteralPath (Join-Path $dest '.pendriveai-root') -Value $marker -Encoding ASCII

# optional model
$modelIncluded = $false
if (-not [string]::IsNullOrWhiteSpace($Model)) {
    if (-not (Test-Path -LiteralPath $Model -PathType Leaf)) { Die "-Model is not a file: $Model" }
    $srcSize = (Get-Item -LiteralPath $Model).Length
    Step "Copying the model ($(Format-Bytes $srcSize))"
    Say 'On a slow USB drive this single copy can take several minutes.'
    Copy-Item -LiteralPath $Model -Destination (Join-Path $modelsDest 'model.gguf') -Force
    $modelIncluded = $true

    $base = Split-Path -Leaf $Model
    if ($base -eq 'model.gguf' -or $base -eq $ModelFileName) {
        Say 'verifying SHA-256 (reads the whole file)...'
        $actual = (Get-FileHash -LiteralPath (Join-Path $modelsDest 'model.gguf') -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -eq $ModelSha256) {
            Say "model checksum OK: $actual"
        } else {
            Warn @"
Model checksum MISMATCH
  expected $ModelSha256
  actual   $actual
The release was still assembled, but this file is not the reference
$ModelFileName. If it is a different quantisation that is fine; if it should be
the reference model, re-download it with models\download-model.ps1.
"@
        }
        if ($srcSize -ne $ModelBytes) {
            Warn "model size is $srcSize bytes, expected $ModelBytes for the reference model."
        }
    } else {
        Say "not verifying the checksum: only $ModelFileName (or model.gguf) has a known one."
    }
}

# --------------------------------------------------------------- report --------
Step "Release tree - $dest"
Get-ChildItem -LiteralPath $dest -Force | Sort-Object Name | ForEach-Object {
    $b = Get-TreeBytes $_.FullName
    $kind = if ($_.PSIsContainer) { 'dir ' } else { 'file' }
    Say ('  {0}  {1,-24} {2}' -f $kind, $_.Name, (Format-Bytes $b))
}

$total = Get-TreeBytes $dest
Say ''
Say ('  {0,-30} {1}' -f 'TOTAL', (Format-Bytes $total))
$free = $DriveUsableBytes - $total
Say "An 8 GB drive has about $(Format-Bytes $DriveUsableBytes) usable."
if ($free -ge 0) {
    Say "This release leaves $(Format-Bytes $free) free on it."
} else {
    Warn "this release is $(Format-Bytes ([Math]::Abs($free))) LARGER than an 8 GB drive can hold."
}

if (-not $modelIncluded) {
    Say ''
    Say 'NO MODEL IS INCLUDED in this release. It will not run until you add one.'
    Say "  Add $ModelBytes bytes ($(Format-Bytes $ModelBytes)) as models\model.gguf:"
    Say '    powershell -ExecutionPolicy Bypass -File models\download-model.ps1'
    Say '    or re-run this script with -Model <path-to.gguf>'
    $after = $free - $ModelBytes
    if ($after -ge 0) {
        Say "  With the model added, $(Format-Bytes $after) would remain free on an 8 GB drive."
    } else {
        Warn "with the model added this would exceed an 8 GB drive by $(Format-Bytes ([Math]::Abs($after)))."
    }
}

Step 'Windows build complete'
Say "Release: $dest"
Say 'Copy that PendriveAI folder to the root of your USB drive, then run'
Say 'StartAI.exe from the drive (or StartAI.bat as a fallback).'
