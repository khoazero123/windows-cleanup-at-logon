param(
    [string]$DefaultUser,
    [string]$LogPath = "C:\ProgramData\WindowsCleanupAtLogon\default-logon-user.log"
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    $logDir = Split-Path -Parent $LogPath
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

if (-not $DefaultUser) {
    throw "DefaultUser is required."
}

$localUser = Get-LocalUser -Name $DefaultUser -ErrorAction Stop
$sid = $localUser.SID.Value
$samUser = ".\$DefaultUser"
$logonUiPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI"

Set-ItemProperty -LiteralPath $logonUiPath -Name "LastLoggedOnSAMUser" -Type String -Value $samUser
Set-ItemProperty -LiteralPath $logonUiPath -Name "LastLoggedOnUser" -Type String -Value $samUser
Set-ItemProperty -LiteralPath $logonUiPath -Name "LastLoggedOnUserSID" -Type String -Value $sid
Set-ItemProperty -LiteralPath $logonUiPath -Name "SelectedUserSID" -Type String -Value $sid
Set-ItemProperty -LiteralPath $logonUiPath -Name "IsFirstLogonAfterSignOut" -Type DWord -Value 0

Write-Log "Set default LogonUI user to $samUser ; SID=$sid"
