# Windows updates

Patch state on a Windows Server instance: what is installed, what failed, what is still waiting, and whether a reboot is pending.

**Investigation only.** Run in an elevated PowerShell session on the instance. Do not install updates or reboot from this guide (`Install-WindowsUpdate`, `Add-WUPackage`, `Restart-Computer`, `shutdown /r`). Windows Update `Search()` is a query; it does not download or install.

## Why this matters

- `Get-HotFix` is incomplete — `InstalledOn` is often blank; history is the install record.
- A KB can show as installed while a reboot is still pending.
- Pending vs downloaded-not-installed tells you whether Update is stuck or just waiting.

## 1. OS and last boot

```powershell
Get-CimInstance Win32_OperatingSystem |
  Select-Object CSName, Caption, Version, BuildNumber, LastBootUpTime
```

## 2. Installed hotfixes

```powershell
Get-HotFix |
  Sort-Object InstalledOn -Descending |
  Select-Object HotFixID, Description, InstalledBy, InstalledOn |
  Format-Table -AutoSize
```

One KB (replace the id):

```powershell
Get-HotFix -Id KB#########
```

## 3. Update history

Use this when dates in `Get-HotFix` are missing or you need success/failure.

`QueryHistory` is reverse chronological (most recent first). Skip the call when the log is empty — `QueryHistory(0, 0)` throws.

```powershell
$searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
$count = $searcher.GetTotalHistoryCount()
if ($count -eq 0) {
  'No update history'
} else {
  $searcher.QueryHistory(0, [Math]::Min($count, 30)) |
    Select-Object Date, Title, @{N='Result';E={
      switch ($_.ResultCode) {
        2 {'Succeeded'} 3 {'SucceededWithErrors'} 4 {'Failed'} 5 {'Aborted'} default {$_.ResultCode}
      }
    }} |
    Format-Table -AutoSize
}
```

## 4. Pending / available

Does not install or download anything. `Search` may take a while; it talks to Windows Update or WSUS.

```powershell
$searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
$result = $searcher.Search('IsInstalled=0 and IsHidden=0')
$result.Updates |
  Select-Object Title, IsDownloaded, MsrcSeverity, MaxDownloadSize |
  Format-Table -AutoSize
```

Downloaded, not installed:

```powershell
$searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
$result = $searcher.Search('IsInstalled=0 and IsDownloaded=1')
$result.Updates | Select-Object Title | Format-Table -AutoSize
```

## 5. Pending reboot

Read-only registry checks. Does not reboot.

```powershell
$cbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
$wu  = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
$sm  = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
$pfn = $null -ne $sm -and $null -ne $sm.PendingFileRenameOperations

[PSCustomObject]@{
  CbsRebootPending  = $cbs
  WuRebootRequired  = $wu
  PendingFileRename = [bool]$pfn
  RebootPending     = ($cbs -or $wu -or $pfn)
}
```

## Related

- [Windows on EC2](./README.md)
- [Manual / final snapshots](../manual-snapshots.md) — take a snapshot before any later patch reboot when rollback matters
