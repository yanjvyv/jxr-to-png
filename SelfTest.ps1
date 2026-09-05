# SelfTest.ps1 - end-to-end validation of JxrToPng.ps1.
#
# Fully self-contained: synthetic samples only (no real files needed).
# Optional: pass -RealJxr <path-to-a-real.jxr> to also validate against a
# genuine third-party JXR file (copied into the sandbox, original untouched).
#
#   powershell -ExecutionPolicy Bypass -File .\SelfTest.ps1
#   powershell -ExecutionPolicy Bypass -File .\SelfTest.ps1 -RealJxr "D:\x\sample.jxr"
#
[CmdletBinding()]
param(
    [string]$RealJxr = ''
)
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName System.Drawing

$sandbox = Join-Path $env:TEMP 'Jxr2PngSelfTest'
$scan    = Join-Path $sandbox 'scan'
foreach ($p in @($sandbox, $scan)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
Get-ChildItem -LiteralPath $scan -File -Force -ErrorAction SilentlyContinue | Remove-Item -Force
$core = Join-Path $PSScriptRoot 'JxrToPng.ps1'
$log  = Join-Path $PSScriptRoot 'JxrToPng.log'

function New-Bitmap {
    param([int]$W, [int]$H, [string]$Tag)
    $bmp = New-Object System.Drawing.Bitmap($W, $H)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(30, 40, 80))
    $font = New-Object System.Drawing.Font('Arial', 48)
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Orange)
    $g.DrawString($Tag, $font, $brush, 30, 30)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::Cyan, 2)
    for ($x = 0; $x -lt $W; $x += 80) { $g.DrawLine($pen, $x, 0, $x, $H) }
    for ($y = 0; $y -lt $H; $y += 80) { $g.DrawLine($pen, 0, $y, $W, $y) }
    $g.Dispose(); $font.Dispose(); $brush.Dispose(); $pen.Dispose()
    return $bmp
}

function Save-As-Jxr {
    param([string]$Path, [System.Drawing.Bitmap]$Bmp)
    $ms = New-Object System.IO.MemoryStream
    try {
        $Bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $ms.Position = 0
        $dec = [System.Windows.Media.Imaging.BitmapDecoder]::Create($ms,
                   [System.Windows.Media.Imaging.BitmapCreateOptions]::None,
                   [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $enc = New-Object System.Windows.Media.Imaging.WmpBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($dec.Frames[0]))
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create)
        try { $enc.Save($fs) } finally { $fs.Dispose() }
    } finally { $ms.Dispose() }
}

# --- cases --------------------------------------------------------------
# a.jxr      : valid synthetic JXR            -> expect a.png, jxr deleted
# c.jxr      : valid synthetic JXR + wrong pre-existing c.png (smaller image)
#              -> expect c.png rewritten, jxr deleted
# bad.jxr    : garbage content (not an image) -> expect bad.not.jxr, no png
# real.jxr   : (optional) copy of a genuine JXR -> expect real.png, jxr deleted
$bmp = New-Bitmap -W 640 -H 400 -Tag 'ALPHA'
Save-As-Jxr -Path (Join-Path $scan 'a.jxr') -Bmp $bmp
$bmp.Dispose()

$bmp = New-Bitmap -W 800 -H 500 -Tag 'CHARLIE'
Save-As-Jxr -Path (Join-Path $scan 'c.jxr') -Bmp $bmp
$bmp.Dispose()
$wrong = New-Bitmap -W 300 -H 200 -Tag 'WRONG'
$wrong.Save((Join-Path $scan 'c.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$wrong.Dispose()

[System.IO.File]::WriteAllText((Join-Path $scan 'bad.jxr'), 'this is definitely not a jxr image',
    (New-Object System.Text.ASCIIEncoding))

if ($RealJxr -and (Test-Path -LiteralPath $RealJxr)) {
    Copy-Item -LiteralPath $RealJxr (Join-Path $scan 'real.jxr') -Force
}

'--- scan folder BEFORE ---'
Get-ChildItem $scan -File | Select-Object Name, Length | Format-Table -AutoSize | Out-String

& $core -ScanRoot $scan -Once -MaxRetry 0 -SkipMutex

'--- scan folder AFTER ---'
Get-ChildItem $scan -File | Select-Object Name, Length | Format-Table -AutoSize | Out-String
'--- log tail ---'
Get-Content -LiteralPath $log -Tail 20 -Encoding UTF8

$pass = $true
function Assert($cond, $msg) { if ($cond) { "PASS: $msg" } else { $pass = $false; "FAIL: $msg" } }
Assert (Test-Path (Join-Path $scan 'a.png'))             'a.png produced'
Assert (-not (Test-Path (Join-Path $scan 'a.jxr')))      'a.jxr deleted after match'
Assert (Test-Path (Join-Path $scan 'c.png'))             'c.png exists (rewritten)'
Assert (-not (Test-Path (Join-Path $scan 'c.jxr')))      'c.jxr deleted after rewrite'
Assert (Test-Path (Join-Path $scan 'bad.not.jxr'))       'bad.jxr marked as bad.not.jxr'
Assert (-not (Test-Path (Join-Path $scan 'bad.png')))    'bad.jxr produced no png'
if ($RealJxr -and (Test-Path -LiteralPath $RealJxr)) {
    Assert (Test-Path (Join-Path $scan 'real.png'))          'real.png produced (real file)'
    Assert (-not (Test-Path (Join-Path $scan 'real.jxr')))   'real.jxr deleted after match'
}

''
if ($pass) { '=== SELFTEST: ALL PASS ===' } else { '=== SELFTEST: SOME CHECKS FAILED ===' }

