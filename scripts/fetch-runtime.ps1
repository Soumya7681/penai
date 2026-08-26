<#
.SYNOPSIS
    Download and stage the llama.cpp Windows runtime for PenAI.

.DESCRIPTION
    Windows PowerShell equivalent of scripts/fetch-runtime.sh, for the windows
    platform only. Downloads the official prebuilt llama.cpp Windows CPU build
    into vendor\, then copies ONLY the files PenAI needs into
    runtime\windows\.

    All 15 ggml-cpu-*.dll variants are kept on purpose: llama.cpp loads the one
    matching the CPU it finds at run time, and keeping the whole set is what
    lets one drive work on any x86-64 machine. Windows resolves DLLs from the
    executable's own directory, so no PATH change is ever needed.

    Requires PowerShell 5 or newer (Invoke-WebRequest, Expand-Archive).

.PARAMETER Tag
    llama.cpp release tag. Default b10549.

.PARAMETER Force
    Re-download even when the archive is already cached in vendor\.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\fetch-runtime.ps1
    powershell -ExecutionPolicy Bypass -File scripts\fetch-runtime.ps1 -Tag b10549 -Force
#>

[CmdletBinding()]
param(
    [string] $Tag = 'b10549',
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ---------------------------------------------------------------- locations --
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root      = Split-Path -Parent $ScriptDir
$Repo      = 'ggml-org/llama.cpp'
$MinArchiveBytes = 5MB   # anything smaller is an HTML error page, not a runtime

function Say  ([string] $m) { Write-Host $m }
function Step ([string] $m) { Write-Host ''; Write-Host "==> $m" }
function Warn ([string] $m) { Write-Warning $m }
function Die  ([string] $m) { Write-Host ''; Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Die @"
PowerShell 5 or newer is required (this is $($PSVersionTable.PSVersion)).
Windows 10 and 11 ship with 5.1 already. On older systems install the
Windows Management Framework 5.1, or use scripts\fetch-runtime.sh under WSL.
"@
}

# ------------------------------------------------------------- minimal set ---
$WindowsFiles = @(
    'llama-server.exe',
    'llama-server-impl.dll',
    'llama-common.dll',
    'llama.dll',
    'mtmd.dll',
    'ggml.dll',
    'ggml-base.dll',
    'ggml-rpc.dll',
    'libomp.dll',
    'ggml-cpu-alderlake.dll',
    'ggml-cpu-cannonlake.dll',
    'ggml-cpu-cascadelake.dll',
    'ggml-cpu-cooperlake.dll',
    'ggml-cpu-haswell.dll',
    'ggml-cpu-icelake.dll',
    'ggml-cpu-ivybridge.dll',
    'ggml-cpu-piledriver.dll',
    'ggml-cpu-sandybridge.dll',
    'ggml-cpu-sapphirerapids.dll',
    'ggml-cpu-skylakex.dll',
    'ggml-cpu-sse42.dll',
    'ggml-cpu-x64.dll',
    'ggml-cpu-zen4.dll',
    'LICENSE-LLVM-OpenMP'
)

function Format-Bytes ([long] $b) {
    if ($b -ge 1GB) { return ('{0:N2} GiB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N2} MiB' -f ($b / 1MB)) }
    return ('{0:N0} KiB' -f ($b / 1KB))
}

# --------------------------------------------------------------------- main --
$Asset      = "llama-$Tag-bin-win-cpu-x64.zip"
$Url        = "https://github.com/$Repo/releases/download/$Tag/$Asset"
$VendorDir  = Join-Path $Root 'vendor'
$Archive    = Join-Path $VendorDir $Asset
$RuntimeDir = Join-Path $Root 'runtime\windows'

Say 'PenAI runtime fetcher (Windows)'
Say "  repo root: $Root"
Say "  platform:  windows"
Say "  tag:       $Tag"
Say "  cache:     $VendorDir"

New-Item -ItemType Directory -Force -Path $VendorDir | Out-Null

# ---- download (cached) ------------------------------------------------------
Step "Downloading $Asset"
$needDownload = $true
if ((Test-Path -LiteralPath $Archive) -and (-not $Force)) {
    $cachedSize = (Get-Item -LiteralPath $Archive).Length
    if ($cachedSize -ge $MinArchiveBytes) {
        Say "cached: $Asset ($(Format-Bytes $cachedSize)) - use -Force to re-download"
        $needDownload = $false
    } else {
        Warn "cached archive is only $(Format-Bytes $cachedSize); re-downloading."
        Remove-Item -LiteralPath $Archive -Force
    }
}

if ($needDownload) {
    Say "URL: $Url"
    $partial = "$Archive.part"
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    try {
        # Progress rendering makes Invoke-WebRequest many times slower on large
        # files, so it is disabled for the transfer and restored afterwards.
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing
        $ProgressPreference = $oldProgress
    } catch {
        Die @"
Download failed: $Url
  $($_.Exception.Message)
Check the network, and check that release tag '$Tag' really has this asset:
  https://github.com/$Repo/releases/tag/$Tag
"@
    }

    $size = (Get-Item -LiteralPath $partial).Length
    if ($size -lt $MinArchiveBytes) {
        Say 'First bytes of the response:'
        Say ((Get-Content -LiteralPath $partial -TotalCount 3 -ErrorAction SilentlyContinue) -join "`n")
        Remove-Item -LiteralPath $partial -Force
        Die @"
The downloaded file is only $(Format-Bytes $size), far too small for a llama.cpp
runtime. That is an HTML error page or a truncated transfer, not an archive.
Verify the asset name for tag '$Tag' at
  https://github.com/$Repo/releases/tag/$Tag
"@
    }
    Move-Item -LiteralPath $partial -Destination $Archive -Force
    Say "saved $Asset ($(Format-Bytes $size))"
}

# ---- extract ----------------------------------------------------------------
$Temp = Join-Path ([System.IO.Path]::GetTempPath()) ("penai-runtime-" + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $Temp | Out-Null
try {
    Step "Extracting to $Temp"
    try {
        Expand-Archive -LiteralPath $Archive -DestinationPath $Temp -Force
    } catch {
        Die @"
Expand-Archive failed on $Archive
  $($_.Exception.Message)
The cached archive may be corrupt. Re-run with -Force to download it again.
"@
    }

    # This asset stores its files at the ZIP root, but search the tree anyway so
    # a differently laid out release still works.
    $serverExe = Get-ChildItem -LiteralPath $Temp -Recurse -File -Filter 'llama-server.exe' |
                 Select-Object -First 1
    if (-not $serverExe) {
        Die "No 'llama-server.exe' anywhere inside $Asset. Wrong asset for tag '$Tag'?"
    }
    Say "found llama-server.exe in $($serverExe.DirectoryName)"

    # ---- stage the minimal set ---------------------------------------------
    Step "Staging into $RuntimeDir"
    New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null

    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($name in $WindowsFiles) {
        $src = Get-ChildItem -LiteralPath $Temp -Recurse -File -Filter $name | Select-Object -First 1
        if (-not $src) {
            $missing.Add($name) | Out-Null
            continue
        }
        Copy-Item -LiteralPath $src.FullName -Destination (Join-Path $RuntimeDir $name) -Force
    }

    if ($missing.Count -gt 0) {
        Say ''
        Say "The archive is missing $($missing.Count) required file(s):"
        foreach ($m in $missing) { Say "  - $m" }
        Die @"
Refusing to leave a half-staged runtime in $RuntimeDir.
Either release tag '$Tag' packages different file names, or the download was
incomplete. Inspect the asset listing at
  https://github.com/$Repo/releases/tag/$Tag
and re-run with -Force, or pin a tag that is known to work: -Tag b10549
"@
    }

    # ---- version file -------------------------------------------------------
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $versionText = @"
llama.cpp release tag: $Tag
source URL:            $Url
repository:            https://github.com/$Repo
staged on:             $stamp
staged by:             scripts/fetch-runtime.ps1
"@
    Set-Content -LiteralPath (Join-Path $RuntimeDir 'RUNTIME_VERSION.txt') -Value $versionText -Encoding ASCII
    Say 'wrote RUNTIME_VERSION.txt'

    # ---- report -------------------------------------------------------------
    $staged = Get-ChildItem -LiteralPath $RuntimeDir -Recurse -File
    $total  = ($staged | Measure-Object -Property Length -Sum).Sum
    Say ''
    Say "staged runtime: $RuntimeDir"
    Say "  files: $($staged.Count)"
    Say "  size:  $(Format-Bytes $total)"
}
finally {
    if (Test-Path -LiteralPath $Temp) {
        Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Step 'Done'
Say 'Next step: build a Windows release with scripts\build-windows.ps1'
