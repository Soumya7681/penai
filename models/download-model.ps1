<#
.SYNOPSIS
    Fetch the PendriveAI model (Windows).

.DESCRIPTION
    Downloads a GGUF quantisation of Qwen3-4B-Instruct-2507 from Hugging Face
    and saves it next to this script as model.gguf, the name the launcher looks
    for first. The result is verified against a known SHA-256 and byte size.

    The model is Apache-2.0 licensed, is NOT gated, and needs no account, token
    or authentication of any kind.

    A note on resuming: Invoke-WebRequest cannot resume a partial download, it
    always starts from byte zero. curl.exe ships with Windows 10 1803 and later
    and does support resuming (curl -C -), so this script uses curl.exe when it
    is available and only falls back to Invoke-WebRequest when it is not. On
    that fallback path an interrupted 2.5 GB download has to be restarted from
    the beginning.

.PARAMETER Dest
    Where to write the file. Default: model.gguf next to this script.

.PARAMETER Quant
    Which quantisation to download: Q2_K, Q3_K_M, Q4_K_M, Q5_K_M or Q6_K.
    Default Q4_K_M, which is the only one with a verified SHA-256 here.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File models\download-model.ps1
    powershell -ExecutionPolicy Bypass -File models\download-model.ps1 -Quant Q5_K_M
#>

[CmdletBinding()]
param(
    [string] $Dest = '',
    [ValidateSet('Q2_K', 'Q3_K_M', 'Q4_K_M', 'Q5_K_M', 'Q6_K')]
    [string] $Quant = 'Q4_K_M'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$RepoId  = 'unsloth/Qwen3-4B-Instruct-2507-GGUF'
$BaseUrl = "https://huggingface.co/$RepoId/resolve/main"

# Only Q4_K_M has a verified checksum and size.
$VerifiedQuant  = 'Q4_K_M'
$VerifiedSha256 = '3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597'
$VerifiedBytes  = 2497281120

function Say  ([string] $m) { Write-Host $m }
function Step ([string] $m) { Write-Host ''; Write-Host "==> $m" }
function Warn ([string] $m) { Write-Warning $m }
function Die  ([string] $m) { Write-Host ''; Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

function Format-Bytes ([long] $b) {
    if ($b -ge 1GB) { return ('{0:N2} GiB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N2} MiB' -f ($b / 1MB)) }
    return ('{0:N0} KiB' -f ($b / 1KB))
}

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Die "PowerShell 5 or newer is required (this is $($PSVersionTable.PSVersion)). Windows 10 and 11 ship with 5.1."
}

if ([string]::IsNullOrWhiteSpace($Dest)) {
    $Dest = Join-Path $ScriptDir 'model.gguf'
}

$FileName = "Qwen3-4B-Instruct-2507-$Quant.gguf"
$Url      = "$BaseUrl/$FileName"

$ExpectSha   = $null
$ExpectBytes = 0
if ($Quant -eq $VerifiedQuant) {
    $ExpectSha   = $VerifiedSha256
    $ExpectBytes = $VerifiedBytes
}

# ------------------------------------------------------------------ banner ----
Say 'PendriveAI model download'
Say "  repository:  $RepoId"
Say "  file:        $FileName"
Say "  URL:         $Url"
Say '  licence:     Apache-2.0 (not gated, no account or token needed)'
Say "  destination: $Dest"
if ($Quant -eq $VerifiedQuant) {
    Say "  size:        $VerifiedBytes bytes ($(Format-Bytes $VerifiedBytes))"
    Say "  SHA-256:     $VerifiedSha256"
    Say ''
    Say 'You need about 2.5 GB of free space at the destination, plus a little more'
    Say 'if you later copy the file to a drive.'
} else {
    Say ''
    Warn @"
Quantisation $Quant has NO verified checksum in this repository. Only $VerifiedQuant does.
The download will be checked for plausibility (GGUF magic bytes and a sane size)
but not against a known digest. Files in this repository range from roughly
1.5 GB to 3.5 GB, so plan for about 4 GB of free space to be safe.
"@
}

$DestDir = Split-Path -Parent $Dest
if ([string]::IsNullOrWhiteSpace($DestDir)) { $DestDir = (Get-Location).Path }
New-Item -ItemType Directory -Force -Path $DestDir | Out-Null

function Get-Sha256 ([string] $path) {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# ------------------------------------------------------ already downloaded? ----
if (Test-Path -LiteralPath $Dest) {
    Step 'A file is already at the destination'
    $existing = (Get-Item -LiteralPath $Dest).Length
    Say "size: $existing bytes ($(Format-Bytes $existing))"
    if ($ExpectSha) {
        Say 'verifying SHA-256 (reads the whole file, takes a few seconds)...'
        $actual = Get-Sha256 $Dest
        if ($actual -eq $ExpectSha) {
            Say "checksum matches: $actual"
            Say ''
            Say "Nothing to do: $Dest is already the correct $FileName."
            exit 0
        }
        Warn @"
Checksum does NOT match:
  expected $ExpectSha
  actual   $actual
Treating the file as an incomplete or different download and resuming.
"@
    } else {
        Say "No verified checksum for $Quant; will resume the download if it is incomplete."
    }
}

# ------------------------------------------------------------- free space ------
try {
    $qualifier = (Split-Path -Qualifier (Resolve-Path -LiteralPath $DestDir).Path)
    $driveName = $qualifier.TrimEnd(':')
    $free = (Get-PSDrive -Name $driveName -ErrorAction Stop).Free
    Say ''
    Say "free space on ${qualifier}: $(Format-Bytes $free)"
    $need = if ($ExpectBytes -gt 0) { $ExpectBytes } else { 4GB }
    if ($free -lt $need) {
        Warn @"
That is less than the $(Format-Bytes $need) this download may need. If the destination
is a FAT32 drive, remember that no single file above 4 GiB can exist there at all.
"@
    }
} catch {
    Warn "could not determine free space on the destination drive: $($_.Exception.Message)"
}

# ------------------------------------------------------------- download --------
Step 'Downloading'
$curl = Get-Command curl.exe -ErrorAction SilentlyContinue
if ($curl) {
    Say "using $($curl.Source) (supports resume: rerun this script to continue an interrupted download)"
    Say 'Ctrl+C is safe.'
    Say ''
    & $curl.Source '-fL' '-C' '-' '--retry' '5' '--retry-delay' '5' '--connect-timeout' '30' '--progress-bar' '-o' $Dest $Url
    if ($LASTEXITCODE -ne 0) {
        Die @"
Download failed (curl.exe exit code $LASTEXITCODE). Run this script again to resume
where it stopped. If it keeps failing, check the network and that the URL is
reachable:
  $Url
"@
    }
} else {
    Warn @"
curl.exe was not found (it ships with Windows 10 1803 and later), so
Invoke-WebRequest is used instead. It CANNOT resume: if this transfer is
interrupted, the whole file has to be downloaded again from the start.
"@
    try {
        $oldProgress = $ProgressPreference
        # Progress rendering makes Invoke-WebRequest many times slower on a
        # multi-GB file, so it is turned off for the transfer.
        $ProgressPreference = 'SilentlyContinue'
        Say 'downloading (no progress bar; this takes a while for 2.5 GB)...'
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
        $ProgressPreference = $oldProgress
    } catch {
        Die @"
Download failed: $($_.Exception.Message)
Invoke-WebRequest cannot resume, so the partial file at
  $Dest
should be deleted before retrying:
  Remove-Item -LiteralPath '$Dest'
URL: $Url
"@
    }
}

# ------------------------------------------------------------- verification ----
Step 'Verifying'
if (-not (Test-Path -LiteralPath $Dest)) { Die "the download reported success but $Dest does not exist." }
$size = (Get-Item -LiteralPath $Dest).Length
Say "size: $size bytes ($(Format-Bytes $size))"

# Every GGUF file starts with the ASCII magic "GGUF". Read exactly four bytes
# with a FileStream: 'Get-Content -Encoding Byte' exists only in PowerShell 5.x,
# and reading the whole 2.5 GB file into memory would be absurd.
$magic = ''
try {
    $fs  = [System.IO.File]::OpenRead($Dest)
    $buf = New-Object byte[] 4
    $read = $fs.Read($buf, 0, 4)
    $fs.Close()
    if ($read -eq 4) { $magic = -join ($buf | ForEach-Object { [char] $_ }) }
} catch {
    Warn "could not read the first bytes of $Dest ($($_.Exception.Message)); skipping the GGUF magic check."
    $magic = 'GGUF'
}
if ($magic -ne 'GGUF') {
    Die @"
This is not a GGUF file: it does not start with the 'GGUF' magic bytes. It is
almost certainly an HTML error page. Delete it and retry:
  Remove-Item -LiteralPath '$Dest'
  powershell -ExecutionPolicy Bypass -File models\download-model.ps1 -Quant $Quant
"@
}
Say 'GGUF magic: OK'

$fail = $false

if ($ExpectBytes -gt 0) {
    if ($size -eq $ExpectBytes) {
        Say "size matches the expected $ExpectBytes bytes"
    } else {
        Warn "size mismatch: expected $ExpectBytes bytes, got $size"
        $fail = $true
    }
}

if ($ExpectSha) {
    Say 'computing SHA-256...'
    $actual = Get-Sha256 $Dest
    if ($actual -eq $ExpectSha) {
        Say "SHA-256 matches: $actual"
    } else {
        Warn @"
SHA-256 MISMATCH
  expected $ExpectSha
  actual   $actual
"@
        $fail = $true
    }
} else {
    Say "No verified checksum exists for $Quant; skipping the digest check."
}

if ($fail) {
    Say ''
    Say "The file has been KEPT at $Dest so you can inspect it, but it does not match"
    Say "the expected $FileName. Do not ship it. To start over:"
    Say "  Remove-Item -LiteralPath '$Dest'"
    Say "  powershell -ExecutionPolicy Bypass -File models\download-model.ps1 -Quant $Quant"
    Say ''
    Say 'A mismatch after a completed download usually means the transfer was'
    Say 'corrupted, or a proxy modified it, or the upstream file was replaced.'
    exit 1
}

Step 'Done'
Say "Model ready: $Dest"
Say "  $(Format-Bytes $size)"
Say ''
Say 'The launcher picks up models\model.gguf automatically. If you saved it'
Say 'elsewhere, either move it into the models folder of the release, or set'
Say '  "model": { "file": "<name>.gguf" }   in config\config.json'
