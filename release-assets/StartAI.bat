@echo off
rem ===========================================================================
rem  StartAI.bat - Windows zero-compile launcher for PendriveAI.
rem
rem  WHY THIS EXISTS
rem    StartAI.exe is the real launcher, but building it needs a Rust toolchain
rem    (MSVC on Windows, or mingw-w64 to cross-compile). This file needs no
rem    compiler at all: it uses only cmd.exe and Windows PowerShell, both of
rem    which are part of Windows itself. It makes the drive usable on a Windows
rem    machine that has nothing installed.
rem
rem  WHAT IT DOES
rem    Reads config\config.json, finds the model, picks a free loopback port,
rem    writes web\runtime-config.json, starts runtime\windows\llama-server.exe
rem    bound to 127.0.0.1, waits for /v1/health, and opens your browser.
rem
rem  WHAT IT DELIBERATELY DOES NOT DO (StartAI.exe does all of these)
rem    * No RAM gate. It measures and warns, but it never reduces the context
rem      automatically and it never refuses to start.
rem    * No single-instance guard. Two copies will start two servers.
rem    * No rotating log files. llama-server writes to this console instead.
rem    * No portable chat history sidecar, so chats stay in the browser's own
rem      storage on this computer and do NOT travel with the drive.
rem
rem  Usage:  StartAI.bat          (or just double-click it)
rem
rem  HOW IT IS PUT TOGETHER
rem    Everything below the #@PSBEGIN@ marker is PowerShell, not batch. cmd.exe
rem    never reaches it because of the `exit /b` above the marker. The batch
rem    part reads this same file, cuts everything after the marker, and hands
rem    that text to PowerShell as a *command* rather than as a .ps1 file, so no
rem    temporary file is created and the script-file execution policy does not
rem    apply.
rem ===========================================================================

setlocal
set "PENDRIVEAI_BAT_SELF=%~f0"

where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo.
    echo ERROR: powershell.exe was not found on this computer.
    echo   PendriveAI's fallback launcher is written in PowerShell, which ships
    echo   with Windows 7 and later. If PowerShell has been removed or blocked,
    echo   use StartAI.exe instead ^(see README.md section 10 for how to build it^).
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $t=[IO.File]::ReadAllText($env:PENDRIVEAI_BAT_SELF); $i=$t.LastIndexOf('#@PSBEGIN@'); if($i -lt 0){ Write-Host 'ERROR: StartAI.bat is damaged (no script section). Re-copy it from the release.'; exit 1 }; Invoke-Expression $t.Substring($i+10)"

set "PENDRIVEAI_EXIT=%ERRORLEVEL%"

if not "%PENDRIVEAI_EXIT%"=="0" (
    echo.
    echo PendriveAI stopped with exit code %PENDRIVEAI_EXIT%. The reason is above.
    pause
)

endlocal & exit /b %PENDRIVEAI_EXIT%

#@PSBEGIN@
# --------------------------------------------------------------------------
#  PowerShell section. cmd.exe never executes any of this.
# --------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'

# ConvertFrom-Json, Get-Content -Raw, Get-ChildItem -File and Get-CimInstance
# are all PowerShell 3.0 features. Windows 8 and later ship 3.0 or newer.
if ($PSVersionTable.PSVersion.Major -lt 3) {
    Write-Host ''
    Write-Host 'ERROR: this launcher needs Windows PowerShell 3.0 or newer.'
    Write-Host ('  This computer has ' + $PSVersionTable.PSVersion + '.')
    Write-Host '  Windows 8 and later are fine. On Windows 7, install Windows'
    Write-Host '  Management Framework 4.0, or use StartAI.exe instead.'
    Write-Host ''
    exit 1
}

$Self = $env:PENDRIVEAI_BAT_SELF
$Root = Split-Path -Parent $Self

function Say  ([string]$m) { Write-Host $m }
function Warn ([string]$m) { Write-Host ('WARNING: ' + $m) -ForegroundColor Yellow }

function Fail ([string]$m) {
    Write-Host ''
    Write-Host ('ERROR: ' + $m) -ForegroundColor Red
    Write-Host ''
    exit 1
}

Say 'PendriveAI (Windows fallback launcher)'
Say ('  drive root: ' + $Root)
Say ''

# ------------------------------------------------------------ layout checks --
$ServerExe = Join-Path $Root 'runtime\windows\llama-server.exe'
$WebDir    = Join-Path $Root 'web'
$ModelsDir = Join-Path $Root 'models'

if (-not (Test-Path -LiteralPath $ServerExe)) {
    Fail ("the llama.cpp engine is missing: " + $ServerExe + "`n" +
          "  There is nothing here to run the model with. Re-package the drive with`n" +
          "  scripts\fetch-runtime.ps1 followed by scripts\build-windows.ps1, or copy`n" +
          "  the release folder across again -- the copy may have been incomplete.")
}

if (-not (Test-Path -LiteralPath (Join-Path $WebDir 'index.html'))) {
    Fail ("the web UI build is missing: " + (Join-Path $WebDir 'index.html') + "`n" +
          "  Build it with 'npm ci' then 'npm run build' inside web\, and re-package.")
}

if (-not (Test-Path -LiteralPath $ModelsDir)) {
    Fail ("the models folder is missing: " + $ModelsDir)
}

# ----------------------------------------------------------------- config ----
# Every field is optional. A missing or malformed config falls back to the same
# defaults the Rust launcher uses, and says so rather than failing.
$cfg = $null
$cfgPath = Join-Path $Root 'config\config.json'
if (Test-Path -LiteralPath $cfgPath) {
    try {
        $cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
    } catch {
        Warn ('config\config.json is not valid JSON (' + $_.Exception.Message + ').')
        Warn 'Using built-in defaults for this run. The file was not modified.'
        $cfg = $null
    }
} else {
    Warn ($cfgPath + ' not found; using built-in defaults.')
}

function CfgSec ([string]$name) {
    if ($null -eq $cfg) { return $null }
    $p = $cfg.PSObject.Properties[$name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function CfgVal ($section, [string]$key, $fallback) {
    if ($null -eq $section) { return $fallback }
    $p = $section.PSObject.Properties[$key]
    if ($null -eq $p -or $null -eq $p.Value) { return $fallback }
    return $p.Value
}

function AsInt ($v, [int]$fallback) {
    try { return [int]$v } catch { return $fallback }
}

function AsNum ($v, [double]$fallback) {
    try { return [double]$v } catch { return $fallback }
}

$secServer = CfgSec 'server'
$secModel  = CfgSec 'model'
$secLlama  = CfgSec 'llama'
$secLaunch = CfgSec 'launcher'
$secUi     = CfgSec 'ui'

$DefaultSystemPrompt = 'You are PendriveAI, a helpful offline assistant running entirely on the ' +
                       "user's own computer. Be concise and correct. When you write code, use " +
                       'fenced code blocks with a language tag.'

$PrefPort    = AsInt (CfgVal $secServer 'port' 8080) 8080
$ScanFrom    = AsInt (CfgVal $secServer 'portScanFrom' 8081) 8081
$ScanTo      = AsInt (CfgVal $secServer 'portScanTo' 8180) 8180
$CtxSize     = AsInt (CfgVal $secLlama  'ctxSize' 4096) 4096
$ThreadsCfg  = AsInt (CfgVal $secLlama  'threads' 0) 0
$Parallel    = AsInt (CfgVal $secLlama  'parallel' 1) 1
$FlashAttn   = [string](CfgVal $secLlama 'flashAttn' 'auto')
$ExtraArgs   = @(CfgVal $secLlama 'extraArgs' @())
$OpenBrowser = [bool](CfgVal $secLaunch 'openBrowser' $true)
$TimeoutSecs = AsInt (CfgVal $secLaunch 'startupTimeoutSecs' 300) 300
$UiTemp      = AsNum (CfgVal $secUi 'temperature' 0.7) 0.7
$UiTopP      = AsNum (CfgVal $secUi 'topP' 0.95) 0.95
$UiMaxTokens = AsInt (CfgVal $secUi 'maxTokens' 1024) 1024
$UiSystem    = [string](CfgVal $secUi 'systemPrompt' $DefaultSystemPrompt)

# Ports below 1024 need administrator rights on Windows, which this launcher
# never asks for.
if ($PrefPort -lt 1024 -or $PrefPort -gt 65535) {
    Warn ('server.port ' + $PrefPort + ' is out of the range 1024-65535; using 8080.')
    $PrefPort = 8080
}
if ($ScanFrom -lt 1024 -or $ScanFrom -gt 65535) { $ScanFrom = 8081 }
if ($ScanTo   -lt 1024 -or $ScanTo   -gt 65535) { $ScanTo   = 8180 }
if ($ScanTo -lt $ScanFrom) {
    Warn ('server.portScanTo is below server.portScanFrom; using 8081-8180.')
    $ScanFrom = 8081
    $ScanTo   = 8180
}
if ($CtxSize -lt 512) {
    Warn ('llama.ctxSize ' + $CtxSize + ' is below the 512 floor; using 512.')
    $CtxSize = 512
}
if ($Parallel -lt 1) { $Parallel = 1 }
if ($TimeoutSecs -lt 10) { $TimeoutSecs = 10 }
if (@('auto','on','off') -notcontains $FlashAttn.ToLower()) {
    Warn ('llama.flashAttn "' + $FlashAttn + '" is not auto, on or off; using auto.')
    $FlashAttn = 'auto'
} else {
    $FlashAttn = $FlashAttn.ToLower()
}

# ------------------------------------------------------------------ model ----
# Same rule as the Rust launcher: an explicit config entry wins, then the
# conventional models\model.gguf, then the largest .gguf present.
$ModelPath = $null
$configured = ([string](CfgVal $secModel 'file' '')).Trim()

if ($configured -ne '') {
    if ([System.IO.Path]::IsPathRooted($configured)) {
        $ModelPath = $configured
    } else {
        $ModelPath = Join-Path $ModelsDir $configured
    }
    if (-not (Test-Path -LiteralPath $ModelPath -PathType Leaf)) {
        Fail ("config\config.json sets model.file to '" + $configured + "', but`n" +
              "  " + $ModelPath + "`n" +
              "  does not exist. Correct the path, or set model.file to `"`" to`n" +
              "  auto-detect the model in " + $ModelsDir + ".")
    }
} else {
    $conventional = Join-Path $ModelsDir 'model.gguf'
    if (Test-Path -LiteralPath $conventional -PathType Leaf) {
        $ModelPath = $conventional
    } else {
        $found = @(Get-ChildItem -LiteralPath $ModelsDir -Filter '*.gguf' -File -ErrorAction SilentlyContinue |
                   Sort-Object -Property Length -Descending)
        if ($found.Count -gt 0) { $ModelPath = $found[0].FullName }
    }
}

if (-not $ModelPath) {
    Fail ("no .gguf model found in " + $ModelsDir + "`n" +
          "  The drive carries the engine and the UI, but no model weights.`n" +
          "  Fix: run models\download-model.ps1 from the source repository and`n" +
          "  put the result in " + $ModelsDir + " as model.gguf.`n" +
          "  See models\README.md for the exact file, size and SHA-256.")
}

$ModelInfo = Get-Item -LiteralPath $ModelPath

# A GGUF for a 1.5B-4B model is never under 100 MB, so anything smaller is
# almost always a failed or partial copy. The magic-bytes check catches the
# other common case: a file that copied at full length but is not a GGUF.
if ($ModelInfo.Length -lt 104857600) {
    Fail ("the model file looks truncated: " + $ModelPath + "`n" +
          "  It is only " + ([math]::Round($ModelInfo.Length / 1MB, 1)) + " MB. A usable model is 1 GB or more.`n" +
          "  Fix: re-download it with models\download-model.ps1 and check the SHA-256`n" +
          "  against models\README.md.")
}

$magic = ''
try {
    $fs = [System.IO.File]::OpenRead($ModelPath)
    try {
        $head = New-Object byte[] 4
        [void]$fs.Read($head, 0, 4)
        $magic = [System.Text.Encoding]::ASCII.GetString($head)
    } finally { $fs.Close() }
} catch {
    Fail ("cannot read the model file: " + $ModelPath + "`n  " + $_.Exception.Message)
}

if ($magic -ne 'GGUF') {
    Fail ("this is not a GGUF model file: " + $ModelPath + "`n" +
          "  It starts with '" + $magic + "' instead of 'GGUF', so the copy is corrupt or`n" +
          "  the file is something else that was renamed. Re-download it with`n" +
          "  models\download-model.ps1 and verify the SHA-256.")
}

# ---------------------------------------------------------------- hardware ----
# Same thread rule as the Rust launcher. llama.cpp CPU inference is bound by
# memory bandwidth, so using every logical core is often slower and leaves the
# machine unusable for anything else.
$Cores = [int][System.Environment]::ProcessorCount
if ($Cores -lt 1) { $Cores = 1 }

if ($ThreadsCfg -gt 0) {
    $Threads = $ThreadsCfg
} elseif ($Cores -le 2) {
    $Threads = $Cores
} elseif ($Cores -le 4) {
    $Threads = $Cores - 1
} else {
    $Threads = [math]::Max([math]::Floor($Cores / 2), 4)
}
$Threads = [int][math]::Max(1, [math]::Min(16, $Threads))

$AvailBytes = $null
$TotalBytes = $null
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $AvailBytes = [int64]$os.FreePhysicalMemory * 1024
    $TotalBytes = [int64]$os.TotalVisibleMemorySize * 1024
} catch {
    try {
        $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop
        $AvailBytes = [int64]$os.FreePhysicalMemory * 1024
        $TotalBytes = [int64]$os.TotalVisibleMemorySize * 1024
    } catch {
        $AvailBytes = $null
        $TotalBytes = $null
    }
}

function HumanBytes ([double]$b) {
    if ($b -ge 1073741824) { return ('{0:N2} GiB' -f ($b / 1073741824)) }
    if ($b -ge 1048576)    { return ('{0:N0} MiB' -f ($b / 1048576)) }
    return ('{0:N0} B' -f $b)
}

Say 'Configuration'
Say ('  model:    ' + $ModelPath)
Say ('  size:     ' + (HumanBytes $ModelInfo.Length))
Say ('  context:  ' + $CtxSize + ' tokens')
Say ('  threads:  ' + $Threads + ' of ' + $Cores + ' logical cores')
Say ('  parallel: ' + $Parallel + ' slot(s)')

# The KV cache for this model costs roughly 144 KiB per token, and llama.cpp
# needs about 400 MiB of assorted buffers on top of the weights.
$NeedBytes = [int64]$ModelInfo.Length + ([int64]$CtxSize * 147456) + 419430400

if ($null -ne $AvailBytes) {
    Say ('  RAM:      ' + (HumanBytes $AvailBytes) + ' available of ' + (HumanBytes $TotalBytes) + ' total')
    Say ('  estimate: ' + (HumanBytes $NeedBytes) + ' needed (weights + KV cache + buffers)')
    if ($NeedBytes -gt $AvailBytes) {
        Say ''
        Warn ('this configuration is estimated to need ' + (HumanBytes $NeedBytes) +
              ' but only ' + (HumanBytes $AvailBytes) + ' is free.')
        Warn 'Starting anyway. This fallback launcher does not reduce the context'
        Warn 'automatically the way StartAI.exe does. If the engine dies or the'
        Warn 'machine starts swapping, close other programs, or lower llama.ctxSize'
        Warn ('in ' + $cfgPath + ' and try again.')
    }
} else {
    Warn 'could not read how much RAM this computer has, so no estimate is possible.'
    Warn 'Starting anyway, making no claim about whether the model will fit.'
}

# -------------------------------------------------------------------- port ----
function Test-PortFree ([int]$p) {
    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener -ArgumentList ([System.Net.IPAddress]::Loopback), $p
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $listener) { try { $listener.Stop() } catch { } }
    }
}

$Port = 0
if (Test-PortFree $PrefPort) {
    $Port = $PrefPort
} else {
    Say ''
    Say ('  port ' + $PrefPort + ' is already in use; scanning ' + $ScanFrom + '-' + $ScanTo + ' for a free one')
    for ($p = $ScanFrom; $p -le $ScanTo; $p++) {
        if (Test-PortFree $p) { $Port = $p; break }
    }
}

if ($Port -eq 0) {
    Fail ("no free loopback port found. Tried " + $PrefPort + " and " + $ScanFrom + "-" + $ScanTo + ".`n" +
          "  Something is occupying that whole range. Close it, or widen`n" +
          "  server.portScanFrom / server.portScanTo in " + $cfgPath + ".")
}

# ---------------------------------------------------------- engine version ----
$Engine = 'unknown'
$prevPref = $ErrorActionPreference
$ErrorActionPreference = 'SilentlyContinue'
try {
    $verOut = (& $ServerExe '--version' 2>&1 | Out-String)
    $m = [regex]::Match($verOut, 'version:\s*(\S+)')
    if ($m.Success) {
        $Engine = $m.Groups[1].Value
    } else {
        $firstLine = ($verOut -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1)
        if ($firstLine) { $Engine = $firstLine.Trim() }
    }
} catch {
    $Engine = 'unknown'
}
$ErrorActionPreference = $prevPref

# --------------------------------------------------- runtime-config for UI ----
# The UI reads this to learn the defaults and the model name. apiBase is the
# empty string, meaning "same origin": the page and the API are served by the
# same llama-server process on the same port, so there is nothing to configure
# and nothing that can point the UI at a remote host.
#
# storeBase is null because this fallback launcher has no chat-history sidecar.
# The UI falls back to the browser's own storage, so chats stay on this computer
# and do not travel with the drive. StartAI.exe is what makes them portable.
$runtimeCfg = [ordered]@{
    apiBase       = ''
    storeBase     = $null
    llamaPort     = $Port
    modelName     = $ModelInfo.Name
    engineVersion = $Engine
    offline       = $true
    defaults      = [ordered]@{
        temperature  = $UiTemp
        topP         = $UiTopP
        maxTokens    = $UiMaxTokens
        ctxSize      = $CtxSize
        systemPrompt = $UiSystem
    }
}

$rcPath = Join-Path $WebDir 'runtime-config.json'
try {
    $json = $runtimeCfg | ConvertTo-Json -Depth 5
    # No byte order mark: the file is fetched and parsed as JSON by the browser.
    $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($rcPath, $json, $utf8NoBom)
} catch {
    Warn ('could not write ' + $rcPath + ' (' + $_.Exception.Message + ').')
    Warn 'The UI will fall back to its built-in defaults. Chat still works.'
}

# ------------------------------------------------------------ start engine ----
# Windows joins the command line back into a single string, so each argument is
# quoted here. Paths cannot contain a double quote on Windows, so the only case
# that needs care is a trailing backslash, which must be doubled before the
# closing quote or CommandLineToArgvW treats it as an escape.
function QuoteArg ([string]$a) {
    if ($a -eq '') { return '""' }
    if ($a -notmatch '[\s"]') { return $a }
    $trailing = 0
    while ($trailing -lt $a.Length -and $a[$a.Length - 1 - $trailing] -eq '\') { $trailing++ }
    return '"' + $a.Substring(0, $a.Length - $trailing) + ('\' * ($trailing * 2)) + '"'
}

# These flags are the same argv the Rust launcher builds, verified against
# llama.cpp b10549. Note what is absent: --no-webui is never passed, because it
# disables llama.cpp's entire static file handler and then --path stops serving
# our React build too (both / and asset paths return 404).
$argv = @(
    '--model',        $ModelPath,
    '--host',         '127.0.0.1',
    '--port',         $Port.ToString(),
    '--ctx-size',     $CtxSize.ToString(),
    '--threads',      $Threads.ToString(),
    '--parallel',     $Parallel.ToString(),
    '--path',         $WebDir,
    '--cors-origins', 'localhost',
    '--flash-attn',   $FlashAttn
)

foreach ($e in $ExtraArgs) {
    if ($null -ne $e) {
        $s = [string]$e
        if ($s -ne '') { $argv += $s }
    }
}

$cmdLine = (($argv | ForEach-Object { QuoteArg $_ }) -join ' ')

Say ''
Say 'Starting the engine'
Say ('  ' + $ServerExe)
Say ('  listening on 127.0.0.1:' + $Port + ' only -- not reachable from the network')
Say ''

$Proc = $null
$EngineExit = 0
try {
    $startArgs = @{
        FilePath         = $ServerExe
        ArgumentList     = $cmdLine
        WorkingDirectory = $Root
        NoNewWindow      = $true
        PassThru         = $true
    }
    $Proc = Start-Process @startArgs
} catch {
    Fail ("could not start " + $ServerExe + "`n  " + $_.Exception.Message + "`n" +
          "  If Windows blocked it, right-click the file, open Properties and press`n" +
          "  Unblock, or allow it in your antivirus. The engine is an unsigned`n" +
          "  binary downloaded from the llama.cpp releases page.")
}

try {
    # ------------------------------------------------------------- health ----
    function Get-HttpStatus ([string]$url, [int]$timeoutMs) {
        $res = $null
        try {
            $req = [System.Net.WebRequest]::Create($url)
            $req.Method = 'GET'
            $req.Timeout = $timeoutMs
            $req.ReadWriteTimeout = $timeoutMs
            # Never let a system proxy intercept a loopback request.
            $req.Proxy = $null
            $res = $req.GetResponse()
            return [int]$res.StatusCode
        } catch [System.Net.WebException] {
            $r = $_.Exception.Response
            if ($null -ne $r) {
                $code = [int]$r.StatusCode
                try { $r.Close() } catch { }
                return $code
            }
            return 0
        } catch {
            return 0
        } finally {
            if ($null -ne $res) { try { $res.Close() } catch { } }
        }
    }

    $base = 'http://127.0.0.1:' + $Port
    Say ('Waiting for the engine to load the model (up to ' + $TimeoutSecs + ' seconds).')
    Say 'Loading a 2.5 GB model from a USB stick genuinely takes a while the first'
    Say 'time. The engine prints its own progress below.'
    Say ''

    $deadline = (Get-Date).AddSeconds($TimeoutSecs)
    $ready = $false

    while ((Get-Date) -lt $deadline) {
        if ($Proc.HasExited) {
            Fail ("the engine stopped on its own with exit code " + $Proc.ExitCode + ".`n" +
                  "  Its own error messages are printed above this line -- read those first.`n" +
                  "  Common causes: not enough RAM for llama.ctxSize, a corrupt model file,`n" +
                  "  or a missing Visual C++ runtime DLL next to llama-server.exe.")
        }

        $code = Get-HttpStatus ($base + '/v1/health') 3000
        if ($code -eq 404) {
            # Older or newer builds expose /health instead.
            $code = Get-HttpStatus ($base + '/health') 3000
        }
        if ($code -eq 200) { $ready = $true; break }

        Start-Sleep -Milliseconds 700
    }

    if (-not $ready) {
        Warn ('the engine did not report healthy within ' + $TimeoutSecs + ' seconds.')
        Warn 'It may still be loading. Leave this window open and try the address'
        Warn 'below in your browser in a minute. To wait longer next time, raise'
        Warn ('launcher.startupTimeoutSecs in ' + $cfgPath + '.')
    }

    # ------------------------------------------------------------ browser ----
    Say ''
    Say '  ----------------------------------------'
    Say ('  PendriveAI is ready at  ' + $base)
    Say '  ----------------------------------------'
    Say ''

    if ($OpenBrowser) {
        try {
            Start-Process $base | Out-Null
            Say '  opened your default browser'
        } catch {
            Warn ('could not open a browser (' + $_.Exception.Message + '). Open the address above yourself.')
        }
    } else {
        Say '  browser auto-open is off in config; open the address above yourself'
    }

    Say ''
    Say '  Chats are kept in this browser''s own storage on this computer.'
    Say '  They do NOT travel with the drive: that needs StartAI.exe.'
    Say ''
    Say '  Press Ctrl+C in this window, or close it, to stop PendriveAI.'
    Say ''

    # ---------------------------------------------------------- supervise ----
    while (-not $Proc.HasExited) {
        Start-Sleep -Milliseconds 500
    }

    Say ''
    Say ('The engine exited with code ' + $Proc.ExitCode + '.')
    $EngineExit = [int]$Proc.ExitCode
}
finally {
    # Reached on Ctrl+C too, in the normal case. Ctrl+C in a console goes to the
    # whole process group, so llama-server.exe usually stops by itself; this is
    # the belt-and-braces path for when it does not.
    if ($null -ne $Proc) {
        try {
            if (-not $Proc.HasExited) {
                Say 'Stopping the engine...'
                $Proc.Kill()
                [void]$Proc.WaitForExit(5000)
            }
        } catch { }
    }
}

# A non-zero code here is the engine crashing, and cmd pauses the window on it.
exit $EngineExit
