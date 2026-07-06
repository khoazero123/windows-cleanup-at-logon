param(
    [string]$ConfigPath,
    [string]$TriggerUser,
    [string]$TargetUser,
    [string[]]$CleanupItems,
    [string[]]$CustomPaths,
    [string]$BitLockerPassword,
    [string]$WslDistro = "Ubuntu",
    [string]$WslUser = "ubuntu",
    [string]$WebhookUrl,
    [string]$LogPath = "C:\ProgramData\WindowsCleanupAtLogon\cleanup.log",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$script:CleanupResults = @()
$script:StartedAt = Get-Date

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

function Add-CleanupResult {
    param(
        [string]$Section,
        [string]$Target,
        [string]$Status,
        [string]$Message
    )

    $script:CleanupResults += [pscustomobject]@{
        section = $Section
        target  = $Target
        status  = $Status
        message = $Message
    }
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
    if ($config.TriggerUser) {
        $script:TriggerUser = [string]$config.TriggerUser
    }
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
    if ($config.WebhookUrl) {
        $script:WebhookUrl = [string]$config.WebhookUrl
    }
    if ($config.LogPath) {
        $script:LogPath = [string]$config.LogPath
    }
    if ($config.CustomPaths) {
        $script:CustomPaths = @($config.CustomPaths | ForEach-Object { [string]$_ })
    }
    if ($config.PSObject.Properties.Name -contains 'BitLockerPassword' -and $config.BitLockerPassword) {
        $script:BitLockerPassword = [string]$config.BitLockerPassword
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

function Normalize-CustomPaths {
    param([string[]]$Paths)

    $normalized = @()
    foreach ($entry in @($Paths)) {
        if ($null -eq $entry) {
            continue
        }
        $normalized += (
            [string]$entry -split "[\r\n,]" |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ }
        )
    }
    return @($normalized | Select-Object -Unique)
}

function Get-DriveLettersFromPaths {
    param([string[]]$Paths)

    $letters = @()
    foreach ($path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }

        $root = [System.IO.Path]::GetPathRoot($path.Trim())
        if ($root -match '^([A-Za-z]):\\$') {
            $letters += ($matches[1].ToUpperInvariant() + ':')
        }
    }
    return @($letters | Select-Object -Unique)
}

function Get-BitLockerVolumeSnapshot {
    param([string]$MountPoint)

    $snapshot = [pscustomobject]@{
        MountPoint = $MountPoint
        Available  = $false
        Protected  = $false
        AutoUnlock = $false
        Locked     = $false
    }

    if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
        return $snapshot
    }

    try {
        $volume = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction Stop
        $snapshot.Available = $true
        $snapshot.Protected = ($volume.ProtectionStatus -eq 'On')
        $snapshot.Locked = ($volume.LockStatus -eq 'Locked')

        foreach ($protector in @($volume.KeyProtector)) {
            if ($protector.KeyProtectorType -eq 'AutoUnlock') {
                $snapshot.AutoUnlock = $true
                break
            }
        }
    }
    catch {
        return $snapshot
    }

    return $snapshot
}

function Unlock-BitLockerVolumesForPaths {
    param(
        [string[]]$Paths,
        [string]$Password
    )

    if (-not $Password) {
        return
    }
    if (-not (Get-Command Unlock-BitLocker -ErrorAction SilentlyContinue)) {
        Write-Log "BitLocker unlock skipped; Unlock-BitLocker cmdlet is unavailable"
        Add-CleanupResult -Section "BitLocker" -Target "Unlock-BitLocker" -Status "skipped" -Message "BitLocker cmdlet unavailable"
        return
    }

    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    foreach ($letter in Get-DriveLettersFromPaths -Paths $Paths) {
        $mountPoint = "$letter\"
        $snapshot = Get-BitLockerVolumeSnapshot -MountPoint $mountPoint
        if (-not $snapshot.Available -or -not $snapshot.Protected) {
            continue
        }
        if (-not $snapshot.Locked) {
            Write-Log "BitLocker volume already unlocked: $mountPoint"
            Add-CleanupResult -Section "BitLocker" -Target $mountPoint -Status "skipped" -Message "Volume already unlocked"
            continue
        }

        if ($DryRun) {
            Write-Log "DryRun unlock BitLocker volume: $mountPoint"
            Add-CleanupResult -Section "BitLocker" -Target $mountPoint -Status "dry_run" -Message "Volume would be unlocked"
            continue
        }

        try {
            Unlock-BitLocker -MountPoint $mountPoint -Password $securePassword -ErrorAction Stop | Out-Null
            Write-Log "Unlocked BitLocker volume: $mountPoint"
            Add-CleanupResult -Section "BitLocker" -Target $mountPoint -Status "unlocked" -Message "Volume unlocked"
        }
        catch {
            Write-Log "Failed to unlock BitLocker volume ${mountPoint}: $($_.Exception.Message)"
            Add-CleanupResult -Section "BitLocker" -Target $mountPoint -Status "failed" -Message $_.Exception.Message
        }
    }
}

function Remove-CustomPaths {
    param([string[]]$Paths)

    foreach ($path in @($Paths)) {
        $snapshot = $null
        $root = [System.IO.Path]::GetPathRoot($path.Trim())
        if ($root -match '^([A-Za-z]):\\$') {
            $snapshot = Get-BitLockerVolumeSnapshot -MountPoint $root
            if ($snapshot.Available -and $snapshot.Protected -and $snapshot.Locked) {
                Write-Log "Skip custom path on locked BitLocker volume: $path"
                Add-CleanupResult -Section "CustomPaths" -Target $path -Status "skipped_locked" -Message "BitLocker volume is locked"
                continue
            }
        }

        Remove-PathSafe -Path $path -Section "CustomPaths"
    }
}

function Has-CleanupItem {
    param([string]$Name)

    return @($CleanupItems) -contains $Name
}

function Send-CleanupWebhook {
    param([string]$Status)

    if (-not $WebhookUrl) {
        return
    }

    try {
        $finishedAt = Get-Date
        $summary = [ordered]@{}
        foreach ($group in ($script:CleanupResults | Group-Object -Property status)) {
            $summary[$group.Name] = $group.Count
        }

        $payload = [ordered]@{
            event        = "windows_cleanup_at_logon.completed"
            status       = $Status
            machine      = $env:COMPUTERNAME
            triggerUser  = $TriggerUser
            targetUser   = $TargetUser
            cleanupItems = @($CleanupItems)
            customPaths  = @($CustomPaths)
            wslDistro    = $WslDistro
            wslUser      = $WslUser
            dryRun       = [bool]$DryRun
            startedAt    = $script:StartedAt.ToString("o")
            finishedAt   = $finishedAt.ToString("o")
            summary      = $summary
            results      = @($script:CleanupResults)
        }

        $body = $payload | ConvertTo-Json -Depth 8
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $body -ContentType "application/json" -ErrorAction Stop | Out-Null
        Write-Log "Sent cleanup webhook: $WebhookUrl"
    }
    catch {
        Write-Log "Failed to send cleanup webhook: $($_.Exception.Message)"
    }
}

function Remove-PathSafe {
    param(
        [string]$Path,
        [string]$Section = "Path"
    )

    if (-not $Path) {
        return
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "Skip missing path: $Path"
        Add-CleanupResult -Section $Section -Target $Path -Status "skipped_missing" -Message "Path does not exist"
        return
    }

    if ($DryRun) {
        Write-Log "DryRun remove path: $Path"
        Add-CleanupResult -Section $Section -Target $Path -Status "dry_run" -Message "Path would be removed"
        return
    }

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        Write-Log "Removed path: $Path"
        Add-CleanupResult -Section $Section -Target $Path -Status "removed" -Message "Path removed"
    }
    catch {
        Write-Log "Failed to remove path: $Path ; $($_.Exception.Message)"
        Add-CleanupResult -Section $Section -Target $Path -Status "failed" -Message $_.Exception.Message
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
                        Add-CleanupResult -Section "BrowserProcesses" -Target "$name.exe PID $($process.ProcessId)" -Status "dry_run" -Message "Process would be stopped"
                    }
                    else {
                        Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
                        Write-Log "Stopped process: $name.exe PID $($process.ProcessId) owned by $UserName"
                        Add-CleanupResult -Section "BrowserProcesses" -Target "$name.exe PID $($process.ProcessId)" -Status "stopped" -Message "Process stopped"
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
            Add-CleanupResult -Section "RdpHistory" -Target $ntUserDat -Status "skipped_missing" -Message "NTUSER.DAT does not exist"
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
                Add-CleanupResult -Section "RdpHistory" -Target $ntUserDat -Status "failed" -Message "Failed to load user hive"
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
                    Add-CleanupResult -Section "RdpHistory" -Target $key -Status "dry_run" -Message "Registry key would be removed"
                }
                else {
                    Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction Stop
                    Write-Log "Removed registry key: $key"
                    Add-CleanupResult -Section "RdpHistory" -Target $key -Status "removed" -Message "Registry key removed"
                }
            }
            else {
                Write-Log "Skip missing registry key: $key"
                Add-CleanupResult -Section "RdpHistory" -Target $key -Status "skipped_missing" -Message "Registry key does not exist"
            }
        }
    }
    catch {
        Write-Log "Failed during RDP registry cleanup: $($_.Exception.Message)"
        Add-CleanupResult -Section "RdpHistory" -Target "RDP registry cleanup" -Status "failed" -Message $_.Exception.Message
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
$CustomPaths = Normalize-CustomPaths -Paths $CustomPaths

if (-not $TargetUser) {
    throw "TargetUser is required."
}

$hasCleanupItems = $CleanupItems -and $CleanupItems.Count -gt 0
$hasCustomPaths = $CustomPaths -and $CustomPaths.Count -gt 0
if (-not $hasCleanupItems -and -not $hasCustomPaths) {
    Write-Log "No cleanup items or custom paths configured; exiting"
    Add-CleanupResult -Section "Config" -Target "CleanupItems" -Status "skipped" -Message "No cleanup items or custom paths configured"
    Send-CleanupWebhook -Status "skipped"
    exit 0
}

Write-Log "Cleanup started for user: $TargetUser ; TriggerUser=$TriggerUser ; Items=$($CleanupItems -join ',') ; CustomPaths=$($CustomPaths.Count) ; DryRun=$DryRun"

if (Has-CleanupItem "WslSsh") {
    Remove-PathSafe -Path "\\wsl.localhost\$WslDistro\home\$WslUser\.ssh" -Section "WslSsh"
}
if (Has-CleanupItem "WslBashHistory") {
    Remove-PathSafe -Path "\\wsl.localhost\$WslDistro\home\$WslUser\.bash_history" -Section "WslBashHistory"
}

if ($hasCustomPaths) {
    Unlock-BitLockerVolumesForPaths -Paths $CustomPaths -Password $BitLockerPassword
    Remove-CustomPaths -Paths $CustomPaths
}

if (-not $hasCleanupItems) {
    Write-Log "Cleanup finished for user: $TargetUser"
    Send-CleanupWebhook -Status "completed"
    exit 0
}

$profile = Resolve-TargetProfile -UserName $TargetUser

if (-not $profile) {
    Write-Log "No Windows profile folder found for user: $TargetUser ; Windows user cleanup skipped"
    Add-CleanupResult -Section "WindowsProfile" -Target $TargetUser -Status "skipped_missing" -Message "Windows profile folder not found"
    Send-CleanupWebhook -Status "completed_with_skips"
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
        Remove-PathSafe -Path $path -Section "ChromeProfiles"
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
        Remove-PathSafe -Path $path -Section "EdgeProfiles"
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
        Remove-PathSafe -Path $path -Section "FirefoxProfiles"
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
        Remove-PathSafe -Path $path -Section "RdpHistory"
    }

    if ($userSid) {
        Remove-RdpHistoryFromHive -ProfilePath $profilePath -UserSid $userSid
    }
    else {
        Write-Log "Skip RDP registry cleanup because SID could not be resolved"
        Add-CleanupResult -Section "RdpHistory" -Target $TargetUser -Status "skipped" -Message "SID could not be resolved"
    }
}

if (Has-CleanupItem "WindowsSsh") {
    Remove-PathSafe -Path (Join-Path $profilePath ".ssh") -Section "WindowsSsh"
}

if (Has-CleanupItem "PowerShellHistory") {
    Remove-PathSafe -Path (Join-Path $profilePath "AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt") -Section "PowerShellHistory"
}

Write-Log "Cleanup finished for user: $TargetUser"
Send-CleanupWebhook -Status "completed"
