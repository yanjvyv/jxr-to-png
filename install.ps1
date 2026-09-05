# install.ps1 - one-click install of the JXR->PNG watcher for ANY user.
#
#  What it does:
#    1. asks for (or takes -ScanRoot) the folder to watch (recursive)
#    2. writes config.json next to this script
#    3. re-launches itself elevated if needed (UAC prompt)
#    4. registers a hidden, logon-triggered scheduled task 'Jxr2PngWatcher'
#       (falls back to a Startup-folder shortcut if Task Scheduler is denied)
#    5. stops any older watcher instance and starts the new one
#
#  Usage:
#    .\install.ps1                                   # asks interactively
#    .\install.ps1 -ScanRoot "D:\pictures\screens"   # fully scripted
#    .\install.ps1 -ScanRoot "D:\pictures" -IntervalSec 30 -MaxRetry 4
#
[CmdletBinding()]
param(
    [string]$ScanRoot = '',
    [int]   $IntervalSec = 15,
    [int]   $MaxRetry    = 4
)
$ErrorActionPreference = 'Stop'

$dir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$core    = Join-Path $dir 'JxrToPng.ps1'
$config  = Join-Path $dir 'config.json'
$vbs     = Join-Path $dir 'launcher.vbs'
$taskName = 'Jxr2PngWatcher'

if (-not (Test-Path -LiteralPath $core)) { throw "Missing core script: $core" }

# -------------------------------------------------------------- 1) scan root --
if ([string]::IsNullOrWhiteSpace($ScanRoot)) {
    $ScanRoot = Read-Host 'Please enter the folder to watch (recursive), e.g. D:\pictures'
    if ([string]::IsNullOrWhiteSpace($ScanRoot)) {
        Write-Host 'No folder given. Aborting.' -ForegroundColor Yellow
        exit 1
    }
}
$ScanRoot = $ScanRoot.Trim().Trim('"')
try { $ScanRoot = [System.IO.Path]::GetFullPath($ScanRoot) } catch { }
if (-not (Test-Path -LiteralPath $ScanRoot -PathType Container)) {
    Write-Host "Folder does not exist: $ScanRoot" -ForegroundColor Yellow
    exit 1
}

# --------------------------------------------------- 2) elevation if needed --
$isAdmin = (New-Object Security.Principal.WindowsPrincipal(
                [Security.Principal.WindowsIdentity]::GetCurrent()
            )).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Admin rights are required to register the scheduled task.'
    Write-Host 'Re-launching elevated (please confirm the UAC prompt)...'
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ScanRoot "{1}" -IntervalSec {2} -MaxRetry {3}' -f `
        $MyInvocation.MyCommand.Path, $ScanRoot, $IntervalSec, $MaxRetry
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine -Wait
    Write-Host 'Elevated install finished.'
    exit 0
}

# ----------------------------------------------------------- 3) config.json --
$cfgObj = [ordered]@{
    ScanRoot   = $ScanRoot
    IntervalSec = [int]$IntervalSec
    MaxRetry    = [int]$MaxRetry
}
$cfgJson = $cfgObj | ConvertTo-Json
[System.IO.File]::WriteAllText($config, $cfgJson,
    (New-Object System.Text.UTF8Encoding($false)))
Write-Host "config.json written: $config"
Write-Host ("  ScanRoot={0}  IntervalSec={1}  MaxRetry={2}" -f $ScanRoot, $IntervalSec, $MaxRetry)

# ---------------------------------------- 4) launcher.vbs (hidden, no flash) --
$vbsLines = @(
    'Option Explicit',
    'Dim fso, sh, dir, core, cmd',
    'Set fso = CreateObject("Scripting.FileSystemObject")',
    'Set sh  = CreateObject("WScript.Shell")',
    'dir = fso.GetParentFolderName(WScript.ScriptFullName)',
    'core = dir & "\JxrToPng.ps1"',
    'cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & core & """"',
    'sh.Run cmd, 0, False'
)
[System.IO.File]::WriteAllLines($vbs, $vbsLines, (New-Object System.Text.ASCIIEncoding))

# --------------------------------------------------------- 5) auto-start reg --
$action    = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $vbs)
$trigger   = New-ScheduledTaskTrigger -AtLogOn
$settings  = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries `
                 -DontStopIfGoingOnBatteries -StartWhenAvailable `
                 -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
                 -LogonType Interactive -RunLevel Limited

$registered = $false
try {
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal `
        -Description 'JXR to PNG watcher (silent background)' `
        -Force -ErrorAction Stop | Out-Null
    $registered = $true
    Write-Host "Scheduled task '$taskName' registered (logon trigger, hidden)."
} catch {
    Write-Host "Task Scheduler registration failed: $($_.Exception.Message)"
    Write-Host 'Falling back to a Startup-folder shortcut...'
    $lnkPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Jxr2PngWatcher.lnk'
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($lnkPath)
    $lnk.TargetPath   = 'wscript.exe'
    $lnk.Arguments    = '"{0}"' -f $vbs
    $lnk.WorkingDirectory = $dir
    $lnk.WindowStyle  = 7
    $lnk.Description  = 'JXR->PNG watcher (silent)'
    $lnk.Save()
    Write-Host "Startup shortcut created: $lnkPath"
}

# --------------------- 6) stop stale watcher, then start the new one now --
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*JxrToPng.ps1*' } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host ("Stopped stale watcher process {0}." -f $_.ProcessId)
    }

if ($registered) {
    Start-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Write-Host ("Task state: {0}" -f $t.State)
} else {
    Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}"' -f $vbs) -WindowStyle Hidden
}

Write-Host ''
Write-Host 'Install done.'
Write-Host ("  Watch folder : {0}" -f $ScanRoot)
Write-Host ("  Log          : {0}" -f (Join-Path $dir 'JxrToPng.log'))
Write-Host '  New .jxr files in that folder (and subfolders) are now converted to PNG automatically.'
