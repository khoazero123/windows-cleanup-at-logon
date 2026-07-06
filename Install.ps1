param(
    [string]$TriggerUser,
    [string]$TargetUser,
    [string[]]$CleanupItems,
    [string]$WslDistro = "Ubuntu",
    [string]$WslUser = "ubuntu",
    [string]$WebhookUrl,
    [bool]$SetTriggerUserAsDefaultLogon = $true,
    [string]$InstallDir = "C:\ProgramData\WindowsCleanupAtLogon",
    [string]$CleanupTaskName = "Windows cleanup at selected user logon",
    [string]$DefaultLogonTaskName = "Keep selected Windows logon user",
    [string]$SourceBaseUrl = "https://raw.githubusercontent.com/khoazero123/windows-cleanup-at-logon/main",
    [switch]$NoGui
)

$ErrorActionPreference = "Stop"

$availableItems = @(
    [pscustomobject]@{ Id = "ChromeProfiles"; Label = "Chrome profiles"; Default = $true },
    [pscustomobject]@{ Id = "EdgeProfiles"; Label = "Microsoft Edge profiles"; Default = $true },
    [pscustomobject]@{ Id = "FirefoxProfiles"; Label = "Firefox / Firefox Developer Edition profiles"; Default = $true },
    [pscustomobject]@{ Id = "RdpHistory"; Label = "Remote Desktop Connection history"; Default = $true },
    [pscustomobject]@{ Id = "WindowsSsh"; Label = "Windows user .ssh folder"; Default = $true },
    [pscustomobject]@{ Id = "PowerShellHistory"; Label = "PowerShell PSReadLine ConsoleHost_history.txt"; Default = $true },
    [pscustomobject]@{ Id = "WslSsh"; Label = "WSL .ssh folder"; Default = $true },
    [pscustomobject]@{ Id = "WslBashHistory"; Label = "WSL .bash_history"; Default = $true }
)

function Test-IsAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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

function Get-InstallerSourceRoot {
    param([string]$BaseUrl)

    $requiredFiles = @(
        "Invoke-UserDataCleanup.ps1",
        "Set-DefaultLogonUser.ps1",
        "Uninstall.ps1"
    )

    if ($PSScriptRoot) {
        $missingLocalFiles = @(
            $requiredFiles |
                Where-Object { -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $_)) }
        )
        if ($missingLocalFiles.Count -eq 0) {
            return $PSScriptRoot
        }
    }

    $downloadRoot = Join-Path $env:TEMP ("WindowsCleanupAtLogonInstall-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null

    foreach ($file in $requiredFiles) {
        $uri = "$($BaseUrl.TrimEnd('/'))/$file"
        $destination = Join-Path $downloadRoot $file
        Invoke-WebRequest -Uri $uri -OutFile $destination -UseBasicParsing -ErrorAction Stop
    }

    return $downloadRoot
}

function Get-ConsoleInstallOptions {
    if (-not $script:TriggerUser) {
        $script:TriggerUser = Read-Host "Username that triggers cleanup at logon"
    }
    if (-not $script:TargetUser) {
        $script:TargetUser = Read-Host "Target username to clean"
    }

    if (-not $script:CleanupItems -or $script:CleanupItems.Count -eq 0) {
        $selected = @()
        foreach ($item in $availableItems) {
            $defaultText = if ($item.Default) { "Y" } else { "N" }
            $answer = Read-Host "$($item.Label)? [Y/N] default $defaultText"
            if (-not $answer) {
                $enabled = $item.Default
            }
            else {
                $enabled = $answer -match '^(y|yes)$'
            }
            if ($enabled) {
                $selected += $item.Id
            }
        }
        $script:CleanupItems = $selected
    }

    $distro = Read-Host "WSL distro name default [$script:WslDistro]"
    if ($distro) {
        $script:WslDistro = $distro
    }
    $user = Read-Host "WSL username default [$script:WslUser]"
    if ($user) {
        $script:WslUser = $user
    }
    $webhook = Read-Host "Webhook URL optional, leave blank to disable"
    if ($webhook) {
        $script:WebhookUrl = $webhook
    }
    $defaultLogon = Read-Host "Set trigger user as Windows default login user? [Y/N] default Y"
    if ($defaultLogon) {
        $script:SetTriggerUserAsDefaultLogon = $defaultLogon -match '^(y|yes)$'
    }
}

function Show-InstallForm {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Windows cleanup at logon installer"
    $form.Width = 620
    $form.Height = 600
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $triggerLabel = New-Object System.Windows.Forms.Label
    $triggerLabel.Text = "Username that triggers cleanup at logon"
    $triggerLabel.Left = 18
    $triggerLabel.Top = 20
    $triggerLabel.Width = 260
    $form.Controls.Add($triggerLabel)

    $triggerBox = New-Object System.Windows.Forms.TextBox
    $triggerBox.Left = 300
    $triggerBox.Top = 18
    $triggerBox.Width = 280
    $triggerBox.Text = $TriggerUser
    $form.Controls.Add($triggerBox)

    $targetLabel = New-Object System.Windows.Forms.Label
    $targetLabel.Text = "Target username to clean"
    $targetLabel.Left = 18
    $targetLabel.Top = 55
    $targetLabel.Width = 260
    $form.Controls.Add($targetLabel)

    $targetBox = New-Object System.Windows.Forms.TextBox
    $targetBox.Left = 300
    $targetBox.Top = 53
    $targetBox.Width = 280
    $targetBox.Text = $TargetUser
    $form.Controls.Add($targetBox)

    $wslDistroLabel = New-Object System.Windows.Forms.Label
    $wslDistroLabel.Text = "WSL distro"
    $wslDistroLabel.Left = 18
    $wslDistroLabel.Top = 90
    $wslDistroLabel.Width = 260
    $form.Controls.Add($wslDistroLabel)

    $wslDistroBox = New-Object System.Windows.Forms.TextBox
    $wslDistroBox.Left = 300
    $wslDistroBox.Top = 88
    $wslDistroBox.Width = 280
    $wslDistroBox.Text = $WslDistro
    $form.Controls.Add($wslDistroBox)

    $wslUserLabel = New-Object System.Windows.Forms.Label
    $wslUserLabel.Text = "WSL username"
    $wslUserLabel.Left = 18
    $wslUserLabel.Top = 125
    $wslUserLabel.Width = 260
    $form.Controls.Add($wslUserLabel)

    $wslUserBox = New-Object System.Windows.Forms.TextBox
    $wslUserBox.Left = 300
    $wslUserBox.Top = 123
    $wslUserBox.Width = 280
    $wslUserBox.Text = $WslUser
    $form.Controls.Add($wslUserBox)

    $webhookLabel = New-Object System.Windows.Forms.Label
    $webhookLabel.Text = "Webhook URL optional"
    $webhookLabel.Left = 18
    $webhookLabel.Top = 160
    $webhookLabel.Width = 260
    $form.Controls.Add($webhookLabel)

    $webhookBox = New-Object System.Windows.Forms.TextBox
    $webhookBox.Left = 300
    $webhookBox.Top = 158
    $webhookBox.Width = 280
    $webhookBox.Text = $WebhookUrl
    $form.Controls.Add($webhookBox)

    $group = New-Object System.Windows.Forms.GroupBox
    $group.Text = "Cleanup sections"
    $group.Left = 18
    $group.Top = 200
    $group.Width = 562
    $group.Height = 260
    $form.Controls.Add($group)

    $checkboxes = @{}
    $top = 28
    foreach ($item in $availableItems) {
        $checkbox = New-Object System.Windows.Forms.CheckBox
        $checkbox.Text = $item.Label
        $checkbox.Left = 18
        $checkbox.Top = $top
        $checkbox.Width = 510
        $checkbox.Checked = if ($CleanupItems) { @($CleanupItems) -contains $item.Id } else { $item.Default }
        $group.Controls.Add($checkbox)
        $checkboxes[$item.Id] = $checkbox
        $top += 27
    }

    $defaultLogonCheck = New-Object System.Windows.Forms.CheckBox
    $defaultLogonCheck.Text = "Set trigger user as default Windows login user"
    $defaultLogonCheck.Left = 18
    $defaultLogonCheck.Top = 475
    $defaultLogonCheck.Width = 420
    $defaultLogonCheck.Checked = $SetTriggerUserAsDefaultLogon
    $form.Controls.Add($defaultLogonCheck)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "Install"
    $okButton.Left = 405
    $okButton.Top = 510
    $okButton.Width = 82
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.AcceptButton = $okButton
    $form.Controls.Add($okButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.Left = 498
    $cancelButton.Top = 510
    $cancelButton.Width = 82
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.CancelButton = $cancelButton
    $form.Controls.Add($cancelButton)

    $result = $form.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        throw "Installation canceled."
    }

    $script:TriggerUser = $triggerBox.Text.Trim()
    $script:TargetUser = $targetBox.Text.Trim()
    $script:WslDistro = $wslDistroBox.Text.Trim()
    $script:WslUser = $wslUserBox.Text.Trim()
    $script:WebhookUrl = $webhookBox.Text.Trim()
    $script:SetTriggerUserAsDefaultLogon = $defaultLogonCheck.Checked
    $script:CleanupItems = @($availableItems | Where-Object { $checkboxes[$_.Id].Checked } | ForEach-Object { $_.Id })
}

if (-not (Test-IsAdministrator)) {
    throw "Run this installer from an elevated PowerShell session."
}

if (-not $NoGui) {
    try {
        Show-InstallForm
    }
    catch {
        if ($_.Exception.Message -eq "Installation canceled.") {
            throw
        }
        Write-Warning "GUI installer could not be opened: $($_.Exception.Message)"
        Get-ConsoleInstallOptions
    }
}
else {
    Get-ConsoleInstallOptions
}

if (-not $TriggerUser) {
    throw "TriggerUser is required."
}
if (-not $TargetUser) {
    throw "TargetUser is required."
}
$CleanupItems = Normalize-CleanupItems -Items $CleanupItems
if (-not $CleanupItems -or $CleanupItems.Count -eq 0) {
    throw "Select at least one cleanup section."
}
if (-not $WslDistro) {
    $WslDistro = "Ubuntu"
}
if (-not $WslUser) {
    $WslUser = "ubuntu"
}
if ($WebhookUrl) {
    try {
        $parsedWebhookUri = [uri]$WebhookUrl
        if (-not $parsedWebhookUri.IsAbsoluteUri -or $parsedWebhookUri.Scheme -notin @("http", "https")) {
            throw "Webhook URL must use http or https."
        }
    }
    catch {
        throw "WebhookUrl must be a valid http or https URL."
    }
}

Get-LocalUser -Name $TriggerUser -ErrorAction Stop | Out-Null

if (-not (Test-Path -LiteralPath $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

$sourceRoot = Get-InstallerSourceRoot -BaseUrl $SourceBaseUrl
$cleanupScript = Join-Path $InstallDir "Invoke-UserDataCleanup.ps1"
$defaultLogonScript = Join-Path $InstallDir "Set-DefaultLogonUser.ps1"
$uninstallScript = Join-Path $InstallDir "Uninstall.ps1"
$configPath = Join-Path $InstallDir "config.json"
$cleanupLogPath = Join-Path $InstallDir "cleanup.log"
$defaultLogonLogPath = Join-Path $InstallDir "default-logon-user.log"

Copy-Item -LiteralPath (Join-Path $sourceRoot "Invoke-UserDataCleanup.ps1") -Destination $cleanupScript -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot "Set-DefaultLogonUser.ps1") -Destination $defaultLogonScript -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot "Uninstall.ps1") -Destination $uninstallScript -Force

$config = [ordered]@{
    TriggerUser                 = $TriggerUser
    TargetUser                  = $TargetUser
    CleanupItems                = @($CleanupItems)
    WslDistro                   = $WslDistro
    WslUser                     = $WslUser
    WebhookUrl                  = $WebhookUrl
    LogPath                     = $cleanupLogPath
    SetTriggerUserAsDefaultLogon = [bool]$SetTriggerUserAsDefaultLogon
}
$config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath -Encoding UTF8

$cleanupArgument = "-NoProfile -ExecutionPolicy Bypass -File `"$cleanupScript`" -ConfigPath `"$configPath`""
$cleanupAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $cleanupArgument
$cleanupTrigger = New-ScheduledTaskTrigger -AtLogOn -User $TriggerUser
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -Compatibility Win8 -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask `
    -TaskName $CleanupTaskName `
    -Action $cleanupAction `
    -Trigger $cleanupTrigger `
    -Principal $principal `
    -Settings $settings `
    -Description "Cleans selected data for $TargetUser when $TriggerUser logs on." `
    -Force | Out-Null

if ($SetTriggerUserAsDefaultLogon) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $defaultLogonScript -DefaultUser $TriggerUser -LogPath $defaultLogonLogPath

    $defaultArgument = "-NoProfile -ExecutionPolicy Bypass -File `"$defaultLogonScript`" -DefaultUser `"$TriggerUser`" -LogPath `"$defaultLogonLogPath`""
    $defaultAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $defaultArgument
    $startupTrigger = New-ScheduledTaskTrigger -AtStartup
    $anyLogonTrigger = New-ScheduledTaskTrigger -AtLogOn

    Register-ScheduledTask `
        -TaskName $DefaultLogonTaskName `
        -Action $defaultAction `
        -Trigger @($startupTrigger, $anyLogonTrigger) `
        -Principal $principal `
        -Settings $settings `
        -Description "Keeps $TriggerUser selected as the default Windows LogonUI user." `
        -Force | Out-Null
}

Write-Host "Installed cleanup task: $CleanupTaskName"
Write-Host "Trigger user: $TriggerUser"
Write-Host "Target user: $TargetUser"
Write-Host "Cleanup items: $($CleanupItems -join ', ')"
Write-Host "Install directory: $InstallDir"
Write-Host "Config: $configPath"
Write-Host "Cleanup log: $cleanupLogPath"
Write-Host "Uninstaller: $uninstallScript"
if ($WebhookUrl) {
    Write-Host "Webhook notifications: enabled"
}
else {
    Write-Host "Webhook notifications: disabled"
}
if ($SetTriggerUserAsDefaultLogon) {
    Write-Host "Installed default-logon task: $DefaultLogonTaskName"
    Write-Host "Default-logon log: $defaultLogonLogPath"
}
