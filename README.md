# Windows cleanup at logon

PowerShell installer for Windows 11 that creates a Scheduled Task to clean selected data for one user when another user logs on.

## Install Without Cloning

Run PowerShell as Administrator:

```powershell
irm https://raw.githubusercontent.com/khoazero123/windows-cleanup-at-logon/main/Install.ps1 | iex
```

This opens the installer UI and downloads the required helper scripts automatically.

## Install From a Cloned Repo

Run PowerShell as Administrator:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Install.ps1
```

The installer asks for:

- Trigger username: the user whose logon starts the cleanup task.
- Target username: the user whose data should be cleaned.
- Cleanup sections to enable.
- WSL distro and username for WSL paths.
- Whether to keep the trigger user selected as the default Windows login user.

If the GUI cannot open, run the console installer:

```powershell
.\Install.ps1 -NoGui
```

## Cleanup Sections

- Chrome profiles and extensions: Stable, Beta, Dev, and Canary/SxS `User Data`.
- Microsoft Edge profiles and extensions: Stable, Beta, Dev, and Canary/SxS `User Data`.
- Firefox and Firefox Developer Edition profiles and extensions, including `dev-edition-default`.
- Remote Desktop Connection history and related registry keys.
- Windows user `.ssh` folder.
- PowerShell PSReadLine history: `ConsoleHost_history.txt`.
- WSL `.ssh`: `\\wsl.localhost\<distro>\home\<user>\.ssh`.
- WSL `.bash_history`: `\\wsl.localhost\<distro>\home\<user>\.bash_history`.

## Non-interactive Install Example

```powershell
.\Install.ps1 `
  -NoGui `
  -TriggerUser "khoa" `
  -TargetUser "khoatest" `
  -WslDistro "Ubuntu" `
  -WslUser "ubuntu" `
  -CleanupItems ChromeProfiles,EdgeProfiles,FirefoxProfiles,RdpHistory,WindowsSsh,PowerShellHistory,WslSsh,WslBashHistory `
  -SetTriggerUserAsDefaultLogon $true
```

## Installed Files

By default the installer writes to:

```text
C:\ProgramData\WindowsCleanupAtLogon
```

Important files:

- `config.json`: selected users and cleanup sections.
- `Invoke-UserDataCleanup.ps1`: task runner.
- `Set-DefaultLogonUser.ps1`: optional helper that keeps the trigger user selected on the Windows login screen.
- `Uninstall.ps1`: uninstaller copied by the installer.
- `cleanup.log`: cleanup log.
- `default-logon-user.log`: default login user log.

## Uninstall

Remove the Scheduled Tasks only:

```powershell
C:\ProgramData\WindowsCleanupAtLogon\Uninstall.ps1
```

Remove the Scheduled Tasks and installed files:

```powershell
C:\ProgramData\WindowsCleanupAtLogon\Uninstall.ps1 -RemoveInstalledFiles
```
