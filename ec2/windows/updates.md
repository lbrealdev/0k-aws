# Windows updates

Patch state on a Windows Server instance: what is installed, what failed, what is still waiting, and whether a reboot is pending.

Run in an elevated PowerShell session on the instance.

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

One KB:

```powershell
Get-HotFix -Id KB5044284
```

## 3. Update history

Use this when dates in `Get-HotFix` are missing or you need success/failure.

```powershell
$searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
$count = $searcher.GetTotalHistoryCount()
$searcher.QueryHistory(0, $count) |
  Select-Object Date, Title, @{N='Result';E={
    switch ($_.ResultCode) {
      2 {'Succeeded'} 3 {'SucceededWithErrors'} 4 {'Failed'} 5 {'Aborted'} default {$_.ResultCode}
    }
  }} |
  Sort-Object Date -Descending |
  Select-Object -First 30 |
  Format-Table -AutoSize
```

## 4. Pending / available

Does not install anything.

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

```powershell
$cbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
$wu  = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
$sm  = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
$pfn = $null -ne $sm.PendingFileRenameOperations

[PSCustomObject]@{
  CbsRebootPending  = $cbs
  WuRebootRequired  = $wu
  PendingFileRename = [bool]$pfn
  RebootPending     = ($cbs -or $wu -or $pfn)
}
```

## Related

- [Windows on EC2](./README.md)
- [Manual / final snapshots](../manual-snapshots.md)
