param(
    [string]$ConfigPath,
    [string]$TargetUser,
    [string[]]$CleanupItems,
    [string]$WslDistro = "Ubuntu",
    [string]$WslUser = "ubuntu",
    [string]$LogPath = "C:\ProgramData\WindowsCleanupAtLogon\cleanup.log",
    [switch]$DryRun
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

function Import-CleanupConfig {
    param([string]$Path)

    if (-not $Path) {
        return
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path"
    }

    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($config.TargetUser) {
        $script:TargetUser = [string]$config.TargetUser
    }
    if ($config.CleanupItems) {
        $script:CleanupItems = @($config.CleanupItems | ForEach-Object { [string]$_ })
    }
    if ($config.WslDistro) {
        $script:WslDistro = [string]$config.WslDistro
    }
    if ($config.WslUser) {
        $script:WslUser = [string]$config.WslUser
    }
    if ($config.LogPath) {
        $script:LogPath = [string]$config.LogPath
    }
}

function Normalize-CleanupItems {
    param([string[]]$Items)

    $normalized = @()
    foreach ($item in @($Items)) {
        if ($null -eq $item) {
            continue
        }
        $normalized += ([string]$item -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    return @($normalized | Select-Object -Unique)
}

function Has-CleanupItem {
    param([string]$Name)

    return @($CleanupItems) -contains $Name
}

function Remove-PathSafe {
    param([string]$Path)

    if (-not $Path) {
        return
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "Skip missing path: $Path"
        return
    }

    if ($DryRun) {
        Write-Log "DryRun remove path: $Path"
        return
    }

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        Write-Log "Removed path: $Path"
    }
    catch {
        Write-Log "Failed to remove path: $Path ; $($_.Exception.Message)"
    }
}

function Stop-TargetBrowserProcesses {
    param(
        [string]$UserName,
        [string[]]$ProcessNames
    )

    foreach ($name in $ProcessNames | Select-Object -Unique) {
        try {
            $processes = Get-CimInstance Win32_Process -Filter "name='$name.exe'" -ErrorAction Stop
            foreach ($process in $processes) {
                $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwner -ErrorAction SilentlyContinue
                if ($owner.User -ieq $UserName) {
                    if ($DryRun) {
                        Write-Log "DryRun stop process: $name.exe PID $($process.ProcessId) owned by $UserName"
                    }
                    else {
                        Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
                        Write-Log "Stopped process: $name.exe PID $($process.ProcessId) owned by $UserName"
                    }
                }
            }
        }
        catch {
            Write-Log "Could not inspect/stop $name.exe: $($_.Exception.Message)"
        }
    }
}

function Remove-RdpHistoryFromHive {
    param(
        [string]$ProfilePath,
        [string]$UserSid
    )

    $mountedHive = $false
    $hiveRoot = "Registry::HKEY_USERS\$UserSid"

    if (-not (Test-Path -LiteralPath $hiveRoot)) {
        $ntUserDat = Join-Path $ProfilePath "NTUSER.DAT"
        if (-not (Test-Path -LiteralPath $ntUserDat)) {
            Write-Log "Skip RDP registry cleanup; missing NTUSER.DAT: $ntUserDat"
            return
        }

        $tempHiveName = "TEMP_$($UserSid -replace '[^A-Za-z0-9]', '_')"
        $hiveRoot = "Registry::HKEY_USERS\$tempHiveName"

        if ($DryRun) {
            Write-Log "DryRun load user hive: $ntUserDat as HKU\$tempHiveName"
        }
        else {
            & reg.exe load "HKU\$tempHiveName" "$ntUserDat" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Log "Failed to load user hive: $ntUserDat"
                return
            }
            $mountedHive = $true
            Write-Log "Loaded user hive: $ntUserDat as HKU\$tempHiveName"
        }
    }

    try {
        $rdpKeys = @(
            "$hiveRoot\Software\Microsoft\Terminal Server Client\Default",
            "$hiveRoot\Software\Microsoft\Terminal Server Client\Servers",
            "$hiveRoot\Software\Microsoft\Terminal Server Client\LocalDevices",
            "$hiveRoot\Software\Microsoft\Terminal Server Client\PublisherBypassList"
        )

        foreach ($key in $rdpKeys) {
            if (Test-Path -LiteralPath $key) {
                if ($DryRun) {
                    Write-Log "DryRun remove registry key: $key"
                }
                else {
                    Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction Stop
                    Write-Log "Removed registry key: $key"
                }
            }
            else {
                Write-Log "Skip missing registry key: $key"
            }
        }
    }
    catch {
        Write-Log "Failed during RDP registry cleanup: $($_.Exception.Message)"
    }
    finally {
        if ($mountedHive) {
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            & reg.exe unload ($hiveRoot -replace '^Registry::HKEY_USERS\\', 'HKU\') | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Unloaded user hive: $hiveRoot"
            }
            else {
                Write-Log "Failed to unload user hive: $hiveRoot"
            }
        }
    }
}

function Resolve-TargetProfile {
    param([string]$UserName)

    $profile = Get-CimInstance Win32_UserProfile |
        Where-Object {
            $_.LocalPath -and
            ((Split-Path -Leaf $_.LocalPath) -ieq $UserName)
        } |
        Select-Object -First 1

    if ($profile) {
        return [pscustomobject]@{
            LocalPath = $profile.LocalPath
            SID       = $profile.SID
        }
    }

    $candidatePath = Join-Path $env:SystemDrive "Users\$UserName"
    if (-not (Test-Path -LiteralPath $candidatePath)) {
        return $null
    }

    $sid = $null
    try {
        $localUser = Get-LocalUser -Name $UserName -ErrorAction Stop
        $sid = $localUser.SID.Value
    }
    catch {
        try {
            $account = New-Object System.Security.Principal.NTAccount($UserName)
            $sid = $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
        }
        catch {
            Write-Log "Could not resolve SID for fallback profile path: $candidatePath"
        }
    }

    return [pscustomobject]@{
        LocalPath = $candidatePath
        SID       = $sid
    }
}

Import-CleanupConfig -Path $ConfigPath
$CleanupItems = Normalize-CleanupItems -Items $CleanupItems

if (-not $TargetUser) {
    throw "TargetUser is required."
}
if (-not $CleanupItems -or $CleanupItems.Count -eq 0) {
    Write-Log "No cleanup items selected; exiting"
    exit 0
}

Write-Log "Cleanup started for user: $TargetUser ; Items=$($CleanupItems -join ',') ; DryRun=$DryRun"

if (Has-CleanupItem "WslSsh") {
    Remove-PathSafe -Path "\\wsl.localhost\$WslDistro\home\$WslUser\.ssh"
}
if (Has-CleanupItem "WslBashHistory") {
    Remove-PathSafe -Path "\\wsl.localhost\$WslDistro\home\$WslUser\.bash_history"
}

$profile = Resolve-TargetProfile -UserName $TargetUser

if (-not $profile) {
    Write-Log "No Windows profile folder found for user: $TargetUser ; Windows user cleanup skipped"
    exit 0
}

$profilePath = $profile.LocalPath
$userSid = $profile.SID
Write-Log "Resolved profile: $profilePath ; SID=$userSid"

$browserProcesses = @()
if (Has-CleanupItem "ChromeProfiles") {
    $browserProcesses += @("chrome", "chrome_proxy")
}
if (Has-CleanupItem "EdgeProfiles") {
    $browserProcesses += @("msedge", "msedge_proxy")
}
if (Has-CleanupItem "FirefoxProfiles") {
    $browserProcesses += @("firefox")
}
if ($browserProcesses.Count -gt 0) {
    Stop-TargetBrowserProcesses -UserName $TargetUser -ProcessNames $browserProcesses
}

if (Has-CleanupItem "ChromeProfiles") {
    $chromePaths = @(
        (Join-Path $profilePath "AppData\Local\Google\Chrome\User Data"),
        (Join-Path $profilePath "AppData\Local\Google\Chrome Beta\User Data"),
        (Join-Path $profilePath "AppData\Local\Google\Chrome Dev\User Data"),
        (Join-Path $profilePath "AppData\Local\Google\Chrome SxS\User Data")
    )
    foreach ($path in $chromePaths | Select-Object -Unique) {
        Remove-PathSafe -Path $path
    }
}

if (Has-CleanupItem "EdgeProfiles") {
    $edgePaths = @(
        (Join-Path $profilePath "AppData\Local\Microsoft\Edge\User Data"),
        (Join-Path $profilePath "AppData\Local\Microsoft\Edge Beta\User Data"),
        (Join-Path $profilePath "AppData\Local\Microsoft\Edge Dev\User Data"),
        (Join-Path $profilePath "AppData\Local\Microsoft\Edge SxS\User Data")
    )
    foreach ($path in $edgePaths | Select-Object -Unique) {
        Remove-PathSafe -Path $path
    }
}

if (Has-CleanupItem "FirefoxProfiles") {
    $firefoxPaths = @(
        (Join-Path $profilePath "AppData\Roaming\Mozilla\Firefox"),
        (Join-Path $profilePath "AppData\Local\Mozilla\Firefox"),
        (Join-Path $profilePath "AppData\Roaming\Mozilla\Firefox Developer Edition"),
        (Join-Path $profilePath "AppData\Local\Mozilla\Firefox Developer Edition"),
        (Join-Path $profilePath "AppData\Roaming\Mozilla\Extensions")
    )
    foreach ($path in $firefoxPaths | Select-Object -Unique) {
        Remove-PathSafe -Path $path
    }
}

if (Has-CleanupItem "RdpHistory") {
    $rdpFilePaths = @(
        (Join-Path $profilePath "Documents\Default.rdp"),
        (Join-Path $profilePath "OneDrive\Documents\Default.rdp"),
        (Join-Path $profilePath "AppData\Local\Microsoft\Terminal Server Client"),
        (Join-Path $profilePath "AppData\Local\Microsoft\Remote Desktop Connection Manager"),
        (Join-Path $profilePath "AppData\Roaming\Microsoft\Remote Desktop Connection Manager")
    )
    foreach ($path in $rdpFilePaths | Select-Object -Unique) {
        Remove-PathSafe -Path $path
    }

    if ($userSid) {
        Remove-RdpHistoryFromHive -ProfilePath $profilePath -UserSid $userSid
    }
    else {
        Write-Log "Skip RDP registry cleanup because SID could not be resolved"
    }
}

if (Has-CleanupItem "WindowsSsh") {
    Remove-PathSafe -Path (Join-Path $profilePath ".ssh")
}

if (Has-CleanupItem "PowerShellHistory") {
    Remove-PathSafe -Path (Join-Path $profilePath "AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt")
}

Write-Log "Cleanup finished for user: $TargetUser"
