param(
    [string]$CleanupTaskName = "Windows cleanup at selected user logon",
    [string]$DefaultLogonTaskName = "Keep selected Windows logon user",
    [string]$InstallDir = "C:\ProgramData\WindowsCleanupAtLogon",
    [switch]$RemoveInstalledFiles
)

$ErrorActionPreference = "Stop"

foreach ($taskName in @($CleanupTaskName, $DefaultLogonTaskName)) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "Removed scheduled task: $taskName"
    }
}

if ($RemoveInstalledFiles -and (Test-Path -LiteralPath $InstallDir)) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
    Write-Host "Removed install directory: $InstallDir"
}
