param(
    [string]$DefaultUser,
    [string]$LogPath = "C:\ProgramData\WindowsCleanupAtLogon\default-logon-user.log"
)

$ErrorActionPreference = "Stop"

$PasswordCredentialProviderId = "{60B78E88-EAD8-445C-9CFD-0B87F74EA6CD}"

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

function Get-LocalAccountSamName {
    param([string]$UserName)

    try {
        $computerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($computerSystem.PartOfDomain) {
            return "$($computerSystem.Domain)\$UserName"
        }
    }
    catch {
    }

    return "$($env:COMPUTERNAME)\$UserName"
}

function Get-LogonProviderIdForSid {
    param([string]$Sid)

    $userTilePath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\UserTile"
    if (Test-Path -LiteralPath $userTilePath) {
        $provider = (Get-ItemProperty -LiteralPath $userTilePath -Name $Sid -ErrorAction SilentlyContinue).$Sid
        if ($provider) {
            return [string]$provider
        }
    }

    $userTileRemotePath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\UserTileRemote"
    if (Test-Path -LiteralPath $userTileRemotePath) {
        $provider = (Get-ItemProperty -LiteralPath $userTileRemotePath -Name $Sid -ErrorAction SilentlyContinue).$Sid
        if ($provider) {
            return [string]$provider
        }
    }

    return $PasswordCredentialProviderId
}

function Ensure-LocalUserProfile {
    param(
        [string]$UserName,
        [string]$Sid
    )

    $existing = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { $_.SID -eq $Sid }
    if ($existing) {
        return $existing.LocalPath
    }

    if (-not ("Win32.UserEnv" -as [type])) {
        Add-Type -Namespace Win32 -Name UserEnv -MemberDefinition @"
[DllImport("userenv.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern int CreateProfile(
    string pszUserSid,
    string pszUserName,
    System.Text.StringBuilder pszProfilePath,
    uint cchProfilePath);
"@
    }

    $profilePath = New-Object System.Text.StringBuilder 260
    $result = [Win32.UserEnv]::CreateProfile($Sid, $UserName, $profilePath, [uint32]$profilePath.Capacity)
    if ($result -ne 0) {
        throw "CreateProfile failed for $UserName (HRESULT=0x$('{0:X8}' -f $result))."
    }

    return $profilePath.ToString()
}

function Set-LogonUiStringValue {
    param(
        [string]$Path,
        [string]$Name,
        [string]$Value
    )

    Set-ItemProperty -LiteralPath $Path -Name $Name -Type String -Value $Value
}

if (-not $DefaultUser) {
    throw "DefaultUser is required."
}

$localUser = Get-LocalUser -Name $DefaultUser -ErrorAction Stop
$sid = $localUser.SID.Value
$samUser = Get-LocalAccountSamName -UserName $DefaultUser
$displayName = if ([string]::IsNullOrWhiteSpace($localUser.FullName)) { $DefaultUser } else { $localUser.FullName }
$providerId = Get-LogonProviderIdForSid -Sid $sid
$logonUiPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI"
$winlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

try {
    $profilePath = Ensure-LocalUserProfile -UserName $DefaultUser -Sid $sid
    Write-Log "Ensured profile for $DefaultUser at $profilePath"
}
catch {
    Write-Log "WARN: Could not ensure profile for ${DefaultUser}: $($_.Exception.Message)"
}

# Only update the "last logged on" selection used by the welcome screen.
# Do not rewrite SessionData\* — those keys describe active/locked sessions.
Set-LogonUiStringValue -Path $logonUiPath -Name "LastLoggedOnDisplayName" -Value $displayName
Set-LogonUiStringValue -Path $logonUiPath -Name "LastLoggedOnSAMUser" -Value $samUser
Set-LogonUiStringValue -Path $logonUiPath -Name "LastLoggedOnUser" -Value $samUser
Set-LogonUiStringValue -Path $logonUiPath -Name "LastLoggedOnUserSID" -Value $sid
Set-LogonUiStringValue -Path $logonUiPath -Name "SelectedUserSID" -Value $sid
Set-LogonUiStringValue -Path $logonUiPath -Name "LastLoggedOnProvider" -Value $providerId
Set-ItemProperty -LiteralPath $logonUiPath -Name "IsFirstLogonAfterSignOut" -Type DWord -Value 0

Set-LogonUiStringValue -Path $winlogonPath -Name "LastUsedUsername" -Value $DefaultUser
Set-LogonUiStringValue -Path $winlogonPath -Name "DefaultUserName" -Value $DefaultUser
Set-LogonUiStringValue -Path $winlogonPath -Name "DefaultDomainName" -Value "."

Write-Log "Set default LogonUI user to $samUser ; SID=$sid ; Provider=$providerId"
