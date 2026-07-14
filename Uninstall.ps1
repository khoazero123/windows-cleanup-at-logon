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

$configPath = Join-Path $InstallDir "config.json"
if (Test-Path -LiteralPath $configPath) {
    try {
        $saved = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($saved.DisabledAutomaticRestartSignOn) {
            $policyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
            if (Get-ItemProperty -LiteralPath $policyPath -Name "DisableAutomaticRestartSignOn" -ErrorAction SilentlyContinue) {
                Remove-ItemProperty -LiteralPath $policyPath -Name "DisableAutomaticRestartSignOn" -ErrorAction SilentlyContinue
                Write-Host "Restored Automatic Restart Sign-On policy (removed DisableAutomaticRestartSignOn)."
            }
        }
    }
    catch {
        Write-Warning "Could not read installer config while uninstalling: $($_.Exception.Message)"
    }
}

if ($RemoveInstalledFiles -and (Test-Path -LiteralPath $InstallDir)) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
    Write-Host "Removed install directory: $InstallDir"
}
