# Windows cleanup at logon

PowerShell installer for Windows 10 and 11 that creates a Scheduled Task to clean selected data for one user when another user logs on.

## Requirements

- Windows 10 or 11
- PowerShell 5.1 or later
- Run the installer from an elevated PowerShell session
- Local user accounts for the trigger and target users

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
- Optional webhook URL for cleanup completion notifications.
- Additional file or folder paths to delete (one per line in the GUI).
- Optional BitLocker password to unlock non-auto-unlock drives before custom-path cleanup.
- Whether to keep the trigger user selected as the default Windows login user.

If the GUI cannot open, run the console installer:

```powershell
.\Install.ps1 -NoGui
```

When you run the installer again on the same machine, it loads the previous settings from `C:\ProgramData\WindowsCleanupAtLogon\config.json` and pre-fills the form or console prompts. Command-line parameters still override saved values.

## Cleanup Sections

- Chrome profiles: Stable, Beta, Dev, and Canary/SxS `User Data`.
- Microsoft Edge profiles: Stable, Beta, Dev, and Canary/SxS `User Data`.
- Brave profiles: Stable, Beta, and Nightly `User Data`.
- Firefox and Firefox Developer Edition profiles, including `dev-edition-default`.
- Remote Desktop Connection history and related registry keys.
- Windows user `.ssh` folder.
- PowerShell PSReadLine history: `ConsoleHost_history.txt`.
- WSL `.ssh`: `\\wsl.localhost\<distro>\home\<user>\.ssh` (falls back to `\\wsl$\<distro>\...` on older Windows 10 / WSL setups).
- WSL `.bash_history`: same path pattern as WSL `.ssh`, ending in `.bash_history`.
- Custom paths: any extra file or folder paths configured during install.

## Custom Paths and BitLocker

During install, you can list extra paths to delete (one per line). On save, the installer checks each drive letter in those paths:

- If a drive has BitLocker enabled **without** auto-unlock and no BitLocker password was provided, a warning is shown.
- Installation still completes successfully after the warning.

At cleanup time, if a BitLocker password is configured, the task tries to unlock locked volumes before deleting custom paths. The same password is used for every protected drive referenced by your custom paths.

The BitLocker password is stored in `config.json` in plain text so the scheduled task can run unattended. Restrict access to `C:\ProgramData\WindowsCleanupAtLogon`.

## Non-interactive Install Example

```powershell
.\Install.ps1 `
  -NoGui `
  -TriggerUser "khoa" `
  -TargetUser "khoatest" `
  -WslDistro "Ubuntu" `
  -WslUser "ubuntu" `
  -WebhookUrl "https://example.com/webhook" `
  -CustomPaths "D:\Sensitive\cache","D:\Projects\temp" `
  -BitLockerPassword "your-bitlocker-password" `
  -CleanupItems ChromeProfiles,EdgeProfiles,BraveProfiles,FirefoxProfiles,RdpHistory,WindowsSsh,PowerShellHistory,WslSsh,WslBashHistory `
  -SetTriggerUserAsDefaultLogon $true
```

## Webhook Payload

If a webhook URL is configured, the cleanup runner sends an HTTP POST with JSON after each run. The payload includes:

- `event`: `windows_cleanup_at_logon.completed`.
- `status`: `completed`, `completed_with_skips`, or `skipped`.
- `machine`, `triggerUser`, `targetUser`, `cleanupItems`, `customPaths`, `wslDistro`, `wslUser`, and `dryRun`.
- `startedAt` and `finishedAt` timestamps.
- `summary`: counts grouped by cleanup result status.
- `results`: per-path and per-registry-key cleanup details.

## Installed Files

By default the installer writes to:

```text
C:\ProgramData\WindowsCleanupAtLogon
```

Important files:

- `config.json`: selected users, cleanup sections, custom paths, and installer settings. Re-running the installer loads this file as defaults.
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
