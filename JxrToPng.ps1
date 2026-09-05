# ============================================================================
#  JxrToPng.ps1 - silent background watcher: JXR -> PNG converter with pixel
#  verification.  Watches one folder (recursively) for .jxr files.
#
#  Behaviour per JXR file found:
#    1. Decode the JXR (WIC/WPF), convert to PNG in the same folder.
#    2. Re-decode the PNG and pixel-compare it against the JXR decode.
#    3. Match        -> delete the JXR, keep the PNG.
#       No match     -> delete the PNG we just wrote, keep the JXR and rename
#                       it to "<name>.not.jxr" so it is never retried.
#    4. Files that cannot be decoded (locked / still being copied / corrupt)
#       are retried over several cycles, then marked *.not.jxr as well.
#
#  Settings are resolved in this order:
#      1. command line:  -ScanRoot / -IntervalSec / -MaxRetry
#      2. config.json next to this script (written by install.ps1)
#      3. built-in defaults (interval 15 s, maxRetry 4)
#  ScanRoot is required to run; run install.ps1 first or pass -ScanRoot.
#
#  Run modes:
#    - as a scheduled task at logon (hidden, silent) - production use
#    - once, for a test pass:  powershell -File JxrToPng.ps1 -ScanRoot X -Once
#
#  Tuning knobs:
#    -ScanRoot       folder to watch (recursive)
#    -IntervalSec    poll interval in seconds (default 15)
#    -MaxRetry       consecutive decode failures before *.not.jxr (default 4,
#                    0 = mark on the very first failure)
#    -Once           single scan pass, then exit
#    -SkipMutex      test-only: do not exit when another watcher is running
# ============================================================================

[CmdletBinding()]
param(
    [string]$ScanRoot,
    [int]   $IntervalSec = -1,
    [int]   $MaxRetry    = -1,
    [switch]$Once,
    [switch]$SkipMutex
)

$ErrorActionPreference = 'Stop'

$script:ScriptDir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogPath        = Join-Path $script:ScriptDir 'JxrToPng.log'
$script:ConfigPath     = Join-Path $script:ScriptDir 'config.json'
$script:RetryMap       = @{}
$script:LogWrites      = 0
$script:LastMissingLog = (Get-Date).AddMinutes(-30)

# ------------------------------------------------------- settings resolution --
# NOTE: internal vars are named so they CANNOT collide with the parameters
# (PowerShell variables are case-insensitive).
$resolvedRoot  = ''
$interval      = 15
$retry         = 4
$cfgSource     = 'defaults'
$cfgRoot       = ''
$cfgInterval   = -1
$cfgMaxRetry   = -1

if (Test-Path -LiteralPath $script:ConfigPath) {
    try {
        $cfgRaw = [System.IO.File]::ReadAllText($script:ConfigPath,
                      (New-Object System.Text.UTF8Encoding($false)))
        $cfg = $cfgRaw | ConvertFrom-Json
        if ($null -ne $cfg.ScanRoot -and [string]$cfg.ScanRoot) { $cfgRoot = [string]$cfg.ScanRoot }
        if ($null -ne $cfg.IntervalSec) { $cfgInterval = [int]$cfg.IntervalSec }
        if ($null -ne $cfg.MaxRetry)    { $cfgMaxRetry = [int]$cfg.MaxRetry }
    } catch {
        Write-Host ("WARN  config.json unreadable ({0}); using defaults" -f $_.Exception.Message)
    }
}

$rootOnCmdLine = $PSBoundParameters.ContainsKey('ScanRoot') -and
                 -not [string]::IsNullOrWhiteSpace($ScanRoot)
if ($rootOnCmdLine) { $resolvedRoot = $ScanRoot }
elseif ($cfgRoot)   { $resolvedRoot = $cfgRoot }

# precedence: command line > config.json > built-in default
if ($IntervalSec -ge 0)          { $interval = $IntervalSec }
elseif ($cfgInterval -ge 0)      { $interval = $cfgInterval }
if ($MaxRetry -ge 0)             { $retry = $MaxRetry }
elseif ($cfgMaxRetry -ge 0)      { $retry = $cfgMaxRetry }

$anyCmdLine = $rootOnCmdLine -or ($IntervalSec -ge 0) -or ($MaxRetry -ge 0)
if ($anyCmdLine) { $cfgSource = 'command line' }
elseif (Test-Path -LiteralPath $script:ConfigPath) { $cfgSource = 'config.json' }

if (-not [string]::IsNullOrWhiteSpace($resolvedRoot)) {
    try { $resolvedRoot = [System.IO.Path]::GetFullPath($resolvedRoot) } catch { }
    while ($resolvedRoot.Length -gt 3 -and $resolvedRoot.EndsWith('\')) {
        $resolvedRoot = $resolvedRoot.TrimEnd('\')
    }
}

if ([string]::IsNullOrWhiteSpace($resolvedRoot)) {
    Write-Host 'No scan folder configured.'
    Write-Host 'Run install.ps1 once (it writes config.json), or pass -ScanRoot <folder>.'
    exit 1
}

$script:MaxRetry = [Math]::Max(0, $retry)

# pixel-match thresholds (empirically safe for same-pipeline PNG round trip)
$script:BadByteDiff   = 4      # a pixel is "bad" when any channel differs by more than this
$script:MaxByteDiff   = 12     # hard ceiling for the largest single channel delta
$script:MaxMeanDiff   = 1.5    # ceiling for the mean absolute byte delta
$script:MaxBadRatio   = 0.0005 # ceiling for the share of bad pixels (0.05 %)

# ---------------------------------------------------------------- logging --
function Write-Log {
    param([string]$Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    $script:LogWrites++
    try {
        if ($script:LogWrites % 200 -eq 0) {
            $fi = Get-Item -LiteralPath $script:LogPath -ErrorAction SilentlyContinue
            if ($fi -and $fi.Length -gt 2MB) {
                $utf8 = New-Object System.Text.UTF8Encoding($false)
                $keep = [System.IO.File]::ReadAllLines($script:LogPath, $utf8)
                if ($keep.Length -gt 600) {
                    $keep = $keep[($keep.Length - 600)..($keep.Length - 1)]
                }
                [System.IO.File]::WriteAllLines($script:LogPath, $keep, $utf8)
            }
        }
        [System.IO.File]::AppendAllText($script:LogPath, $line + [Environment]::NewLine,
            (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
    Write-Host $line
}

# --------------------------------------------------- single-instance guard --
$mutex  = New-Object System.Threading.Mutex($false, 'Local\Jxr2PngWatcher_Mutex')
$owned  = $mutex.WaitOne(0)
if (-not $owned -and -not $SkipMutex) {
    Write-Log 'Another watcher instance is already running - exiting.'
    exit 0
}

Add-Type -AssemblyName PresentationCore -ErrorAction Stop
Add-Type -AssemblyName WindowsBase -ErrorAction Stop

# ------------------------------------------------------------ image helpers --
# Decode any WIC image (JXR/PNG/...) to a Bgra32 BitmapSource (raw, unmanaged).
function Read-BitmapAsBgra {
    param([string]$Path)
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $opts = [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat -bor
                [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreColorProfile -bor
                [System.Windows.Media.Imaging.BitmapCreateOptions]::OnLoad
        $dec = [System.Windows.Media.Imaging.BitmapDecoder]::Create($fs, $opts,
                    [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        if ($null -eq $dec -or $dec.Frames.Count -eq 0) { throw 'No image frames decoded.' }
        $ctorArgs = @($dec.Frames[0], [System.Windows.Media.PixelFormats]::Bgra32, $null, [double]0.0)
        $conv = New-Object System.Windows.Media.Imaging.FormatConvertedBitmap -ArgumentList $ctorArgs
        return $conv
    } finally {
        $fs.Dispose()
    }
}

function Get-PixelBytes {
    param($Bitmap)
    $w = [int]$Bitmap.PixelWidth
    $h = [int]$Bitmap.PixelHeight
    $stride = $w * 4
    $buf = New-Object byte[] ($w * $h * 4)
    $rect = New-Object System.Windows.Int32Rect -ArgumentList 0, 0, $w, $h
    $Bitmap.CopyPixels($rect, $buf, $stride, 0)
    return , $buf
}

function Save-BgraToPng {
    param($Bitmap, [string]$PngPath)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($Bitmap))
    $fs = [System.IO.File]::Open($PngPath, [System.IO.FileMode]::Create)
    try { $enc.Save($fs) } finally { $fs.Dispose() }
}

# Pixel-compare two Bgra32 byte arrays.
function Test-PixelMatch {
    param([byte[]]$RefPixels, [byte[]]$NewPixels)
    $len = $RefPixels.Length
    if ($len -ne $NewPixels.Length) {
        return [pscustomobject]@{ Pass=$false; Reason='size-mismatch'; MaxDiff=255; MeanDiff=-1.0; BadRatio=1.0 }
    }
    if ($len -eq 0) {
        return [pscustomobject]@{ Pass=$true; Reason='empty-ok'; MaxDiff=0; MeanDiff=0.0; BadRatio=0.0 }
    }
    # fast path: byte-identical content
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $h1 = $sha.ComputeHash($RefPixels)
        $h2 = $sha.ComputeHash($NewPixels)
        $same = $true
        for ($i = 0; $i -lt $h1.Length; $i++) {
            if ($h1[$i] -ne $h2[$i]) { $same = $false; break }
        }
        if ($same) {
            return [pscustomobject]@{ Pass=$true; Reason='identical'; MaxDiff=0; MeanDiff=0.0; BadRatio=0.0 }
        }
    } finally {
        $sha.Dispose()
    }
    # slow path: full diff scan with early abort
    $maxDiff = 0L
    $sumDiff = 0L
    $bad     = 0L
    $pixels  = [int]($len / 4)
    $badLimit = [long][Math]::Ceiling($pixels * $script:MaxBadRatio)
    for ($i = 0; $i -lt $len; $i += 4) {
        $d0 = [Math]::Abs([int]$RefPixels[$i]     - [int]$NewPixels[$i])
        $d1 = [Math]::Abs([int]$RefPixels[$i + 1] - [int]$NewPixels[$i + 1])
        $d2 = [Math]::Abs([int]$RefPixels[$i + 2] - [int]$NewPixels[$i + 2])
        $d3 = [Math]::Abs([int]$RefPixels[$i + 3] - [int]$NewPixels[$i + 3])
        $mx = $d0; if ($d1 -gt $mx) { $mx = $d1 }; if ($d2 -gt $mx) { $mx = $d2 }; if ($d3 -gt $mx) { $mx = $d3 }
        $sumDiff += $d0 + $d1 + $d2 + $d3
        if ($mx -gt $maxDiff) { $maxDiff = $mx }
        if ($mx -gt $script:BadByteDiff) { $bad++ }
        if ($mx -gt $script:MaxByteDiff)  { break }      # cannot pass anymore
        if ($bad  -gt $badLimit)          { break }      # cannot pass anymore
    }
    $mean     = ($sumDiff / [double]$len)
    $badRatio = ($bad / [double]$pixels)
    $pass = ($maxDiff -le $script:MaxByteDiff) -and
            ($mean     -le $script:MaxMeanDiff) -and
            ($badRatio -le $script:MaxBadRatio)
    return [pscustomobject]@{
        Pass     = $pass
        Reason   = if ($pass) { 'close-match' } else { 'differs' }
        MaxDiff  = [int]$maxDiff
        MeanDiff = [double]$mean
        BadRatio = $badRatio
    }
}

# ------------------------------------------------------- per-file workflow --
function Invoke-ProcessFile {
    param([System.IO.FileInfo]$File)
    $full    = $File.FullName
    $name    = $File.Name
    if ($name -like '*.not.jxr') { return 'skip' }

    $pngPath = [System.IO.Path]::ChangeExtension($full, '.png')
    $base    = [System.IO.Path]::GetFileNameWithoutExtension($full)
    $notName = $base + '.not.jxr'
    $notPath = Join-Path $File.DirectoryName $notName

    # ---- 1) decode source JXR ----
    $jxrBmp = $null
    try {
        $jxrBmp = Read-BitmapAsBgra -Path $full
    } catch {
        $fails = ([int]$script:RetryMap[$full]) + 1
        $script:RetryMap[$full] = $fails
        if ($fails -gt $script:MaxRetry) {
            Write-Log ("FAIL  {0}  decode error x{1} ({2}); marking *.not.jxr" -f $name, $fails, $_.Exception.Message)
            Remove-Item -LiteralPath $notPath -Force -ErrorAction SilentlyContinue
            try { Rename-Item -LiteralPath $full -NewName $notName -Force } catch {
                Write-Log ("WARN  {0}  rename to {1} failed: {2}" -f $name, $notName, $_.Exception.Message)
            }
            $script:RetryMap.Remove($full) | Out-Null
        } else {
            Write-Log ("RETRY {0}  decode failed ({1}/{2}): {3}" -f $name, $fails, $script:MaxRetry, $_.Exception.Message)
        }
        return 'fail'
    }
    $script:RetryMap.Remove($full) | Out-Null
    $refPixels = Get-PixelBytes $jxrBmp

    # ---- 2) make sure a matching PNG exists next to it ----
    $stats = $null
    $rewrote = $false
    if (Test-Path -LiteralPath $pngPath) {
        $pngOk = $false
        try {
            $pngBmp = Read-BitmapAsBgra -Path $pngPath
            if ($pngBmp.PixelWidth  -eq $jxrBmp.PixelWidth -and
                $pngBmp.PixelHeight -eq $jxrBmp.PixelHeight) {
                $r0 = Test-PixelMatch -RefPixels $refPixels -NewPixels (Get-PixelBytes $pngBmp)
                if ($r0.Pass) { $stats = $r0; $pngOk = $true }
                else { Write-Log ("WARN  {0}  existing PNG does not match JXR ({1}); rewriting" -f $name, $r0.Reason) }
            } else {
                Write-Log ("WARN  {0}  existing PNG has different dimensions; rewriting" -f $name)
            }
        } catch {
            Write-Log ("WARN  {0}  existing PNG unreadable ({1}); rewriting" -f $name, $_.Exception.Message)
        }
        if (-not $pngOk) { Remove-Item -LiteralPath $pngPath -Force -ErrorAction SilentlyContinue }
    }

    if ($null -eq $stats) {
        try {
            Save-BgraToPng -Bitmap $jxrBmp -PngPath $pngPath
            $rewrote = $true
            $pngBmp  = Read-BitmapAsBgra -Path $pngPath
            $stats   = Test-PixelMatch -RefPixels $refPixels -NewPixels (Get-PixelBytes $pngBmp)
        } catch {
            Write-Log ("WARN  {0}  PNG write/verify error (retry later): {1}" -f $name, $_.Exception.Message)
            return 'fail'
        }
        if (-not $stats.Pass) {
            Remove-Item -LiteralPath $pngPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $notPath -Force -ErrorAction SilentlyContinue
            try { Rename-Item -LiteralPath $full -NewName $notName -Force } catch {
                Write-Log ("WARN  {0}  rename to {1} failed: {2}" -f $name, $notName, $_.Exception.Message)
            }
            Write-Log ("FAIL  {0}  pixel check failed (max={1}, mean={2}, bad={3}%); PNG deleted, JXR marked NOT" -f `
                $name, $stats.MaxDiff, [math]::Round($stats.MeanDiff, 3), [math]::Round($stats.BadRatio * 100, 4))
            return 'fail'
        }
    }

    # ---- 3) verified: delete the JXR, keep the PNG ----
    try { Remove-Item -LiteralPath $full -Force } catch {
        Write-Log ("WARN  {0}  PNG verified ({1}) but JXR delete failed (locked?); will retry later" -f $name, $stats.Reason)
        return 'retry'
    }
    $how = if ($rewrote) { 'converted' } else { 'existing-png-verified' }
    Write-Log ("OK    {0} -> {1}  [{2}]  (max={3}, mean={4}, bad={5}%)" -f $name,
        [System.IO.Path]::GetFileName($pngPath), $how, $stats.MaxDiff,
        [math]::Round($stats.MeanDiff, 3), [math]::Round($stats.BadRatio * 100, 4))
    return 'ok'
}

# ------------------------------------------------------------ scan a folder --
function Invoke-ScanPass {
    param([string]$Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        $now = Get-Date
        if ($now -gt $script:LastMissingLog.AddMinutes(15)) {
            Write-Log ("WARN  scan root is not present (yet): {0}" -f $Root)
            $script:LastMissingLog = $now
        }
        return
    }
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.jxr' -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -notlike '*.not.jxr' })
    if ($files.Count -eq 0) { return }

    Write-Log ("SCAN  {0}: {1} JXR file(s) to process" -f $Root, $files.Count)
    $ok = 0; $fail = 0
    foreach ($f in $files) {
        try {
            $r = Invoke-ProcessFile -File $f
            if ($r -eq 'ok')   { $ok++ }
            elseif ($r -eq 'fail') { $fail++ }
        } catch {
            Write-Log ("ERROR {0}: {1}" -f $f.Name, $_.Exception.Message)
        }
    }
    Write-Log ("DONE  pass finished: ok={0} fail={1}" -f $ok, $fail)
}

# ------------------------------------------------------------------- main --
Write-Log ("START watcher   root={0}  interval={1}s  maxRetry={2}  (settings: {3})" -f `
    $resolvedRoot, $interval, $script:MaxRetry, $cfgSource)
do {
    try { Invoke-ScanPass -Root $resolvedRoot } catch {
        Write-Log ('FATAL ' + $_.Exception.Message)
    }
    if ($Once) { break }
    Start-Sleep -Seconds ([Math]::Max(2, $interval))
} while ($true)
Write-Log 'STOP  watcher exiting'
try { $mutex.ReleaseMutex() } catch { }
