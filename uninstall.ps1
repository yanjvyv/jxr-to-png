# uninstall.ps1 - stops the watcher and removes its auto-start registration.
# Tool files (scripts, log) are left in place; delete the folder manually if wanted.
$ErrorActionPreference = 'Continue'

$taskName = 'Jxr2PngWatcher'

# 1) scheduled task
try {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        Write-Host "Removed scheduled task '$taskName'."
    } else {
        Write-Host "Scheduled task '$taskName' not present."
    }
} catch {
    Write-Host "Task removal failed: $($_.Exception.Message)"
}

# 2) running watcher process(es)
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*JxrToPng.ps1*' } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host ("Stopped watcher process {0}." -f $_.ProcessId)
    }

# 3) startup shortcut (fallback install path)
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Jxr2PngWatcher.lnk'
if (Test-Path -LiteralPath $lnk) {
    Remove-Item -LiteralPath $lnk -Force
    Write-Host 'Removed Startup shortcut.'
}

Write-Host 'Uninstall done.'
