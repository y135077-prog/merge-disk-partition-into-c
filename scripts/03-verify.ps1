<#
.SYNOPSIS
    Read-only verification of a merged C:/D: disk layout and its WinRE recovery setup.

.DESCRIPTION
    Runs every non-invasive check that should pass after a partition merge, writes a
    single report file, and prints a PASS/FAIL summary.

    Nothing in this script modifies the disk. It only reads partition tables, the BCD
    store, and file listings on temporarily mounted volumes (mount paths are removed
    again before the script exits).

    Must be run from an ELEVATED PowerShell window (bcdedit / reagentc / DISM all
    require administrator rights).

.PARAMETER DiskNumber
    Disk to verify. Default 0.

.PARAMETER RecoveryPartitionNumber
    Partition number of the dedicated recovery partition. Default 4.

.PARAMETER ReportPath
    Where to write the report. Default: <script dir>\..\verify-report.txt

.EXAMPLE
    Run from an elevated PowerShell. The default execution policy is "Restricted",
    so a plain ".\03-verify.ps1" will be rejected - the -ExecutionPolicy Bypass
    below only applies to that one call and does not change machine settings.

    powershell -ExecutionPolicy Bypass -File .\03-verify.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\03-verify.ps1 -DiskNumber 0 -RecoveryPartitionNumber 4

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\03-verify.ps1 -ReportPath D:\verify.txt
#>

[CmdletBinding()]
param(
    [int]    $DiskNumber               = 0,
    [int]    $RecoveryPartitionNumber  = 4,
    [string] $ReportPath
)

$ErrorActionPreference = 'Continue'

if (-not $ReportPath) {
    $ReportPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'verify-report.txt'
}

# ---------------------------------------------------------------- helpers
# NOTE: this file is deliberately ASCII-only. Windows PowerShell 5.1 parses .ps1
# files using the system ANSI code page, so UTF-8 CJK comments silently turn into
# syntax errors on a zh-TW machine. See README "gotchas".
$script:Fails = 0
$script:Checks = 0

function W([string]$m) {
    Add-Content -Path $ReportPath -Value $m -Encoding UTF8
    Write-Host $m
}

function Section([string]$title) {
    W ''
    W ('=== ' + $title + ' ' + ('=' * [Math]::Max(0, 60 - $title.Length)))
}

# Run a command and capture its combined output as a single whitespace-normalised line.
# reagentc / bcdedit output can be empty or garbled when piped directly in a child
# process, so always redirect to a file first. See README "gotchas".
function CmdOut([string]$cmdline) {
    $tmp = Join-Path $env:TEMP ('vv_' + [guid]::NewGuid().ToString('N') + '.txt')
    cmd /c "chcp 65001 >nul && $cmdline > `"$tmp`" 2>&1" | Out-Null
    $text = ''
    if (Test-Path -LiteralPath $tmp) {
        $text = ((Get-Content -LiteralPath $tmp -Raw -EA SilentlyContinue) -replace '\s+', ' ').Trim()
        Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue
    }
    return $text
}

function Assert-True([bool]$condition, [string]$label, [string]$detail = '') {
    $script:Checks++
    if ($condition) {
        W ('  [PASS] ' + $label)
    } else {
        $script:Fails++
        W ('  [FAIL] ' + $label)
        if ($detail) { W ('         ' + $detail) }
    }
}

# Pick an unused drive letter so a partition can be mounted temporarily.
function Get-FreeDriveLetter([string[]]$Avoid = @()) {
    $used = (Get-PSDrive -PSProvider FileSystem -EA SilentlyContinue).Name
    foreach ($c in [char[]]'RQPSTUVWXYZ') {
        $l = [string]$c
        if ($used -notcontains $l -and $Avoid -notcontains $l) { return $l }
    }
    return $null
}

# Mount a partition at a temporary path, run a scriptblock, always unmount.
function With-MountedPartition([int]$PartitionNumber, [scriptblock]$Action) {
    $letter = Get-FreeDriveLetter
    if (-not $letter) { W '  (no free drive letter available - skipped)'; return $null }
    $path = "${letter}:\"
    if (-not (Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -AccessPath $path -EA SilentlyContinue)) {
        W "  (could not mount partition $PartitionNumber - skipped)"
        return $null
    }
    Start-Sleep -Seconds 1
    try { return (& $Action $letter) } finally {
        Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -AccessPath $path -EA SilentlyContinue
    }
}

# ---------------------------------------------------------------- start
Remove-Item -LiteralPath $ReportPath -Force -EA SilentlyContinue
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

W ('Partition merge verification report')
W ('Generated : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
W ('Computer  : ' + $env:COMPUTERNAME)
W ('Disk      : ' + $DiskNumber + '   Recovery partition: ' + $RecoveryPartitionNumber)
W ('Elevated  : ' + $isAdmin)
W ('Report    : ' + $ReportPath)

if (-not $isAdmin) {
    W ''
    W 'WARNING: not elevated. reagentc / bcdedit / DISM checks will fail.'
}

# ---------------------------------------------------------------- 1. partition layout
Section '1. Partition layout'
$parts = @(Get-Partition -DiskNumber $DiskNumber -EA SilentlyContinue | Sort-Object PartitionNumber)
if (-not $parts) {
    W '  (could not read partitions on disk ' + $DiskNumber + ')'
    $script:Checks++; $script:Fails++
} else {
    $parts | ForEach-Object {
        $type = if ($_.GptType) { ($_.GptType -replace '.*\\', '') } else { $_.Type }
        W ('  Part{0}  {1,-9} {2,-9} {3,10:N3} GB  offset {4}' -f `
            $_.PartitionNumber,
            $(if ($_.DriveLetter) { "$($_.DriveLetter):" } else { '(none)' }),
            $type,
            ($_.Size / 1GB),
            $_.Offset)
    }
    $sysPart = $parts | Where-Object { $_.GptType -like '*c12a7328*' }
    $msrPart = $parts | Where-Object { $_.GptType -like '*e3c9e316*' }
    $recPart = $parts | Where-Object { $_.PartitionNumber -eq $RecoveryPartitionNumber }
    $cPart   = $parts | Where-Object { $_.DriveLetter -eq 'C' }

    Assert-True ([bool]$sysPart) 'EFI system partition present (GPT type c12a7328)'
    Assert-True ([bool]$msrPart) 'Microsoft reserved partition present (GPT type e3c9e316)'
    Assert-True ([bool]$cPart)   'C: present on this disk'
    Assert-True ([bool]$recPart) ('recovery partition is Part' + $RecoveryPartitionNumber)
    if ($recPart) {
        Assert-True ($recPart.GptType -like '*de94bba4*') 'recovery partition has the Windows RE GPT type (de94bba4)' $recPart.GptType
    }
    # C: should reach nearly the end of the disk, minus the small tail partitions.
    $disk = Get-Disk -Number $DiskNumber -EA SilentlyContinue
    if ($cPart -and $disk) {
        $tail = [math]::Round(($disk.Size - ($cPart.Offset + $cPart.Size)) / 1GB, 3)
        W ('  free tail after C: = ' + $tail + ' GB (expected ~2 GB = the recovery partition)')
        Assert-True ($tail -gt 0 -and $tail -lt 5) 'C: extends to just before the trailing recovery partition'
    }
}

# ---------------------------------------------------------------- 2. drive letters
Section '2. Drive letters (target partition must be gone)'
$vol = Get-Volume -EA SilentlyContinue
$vol | Where-Object { $_.DriveLetter } | Sort-Object DriveLetter | ForEach-Object {
    W ('  {0}:  {1,10:N2} GB   {2}' -f $_.DriveLetter, ($_.Size / 1GB), $_.FileSystem)
}
$gone = -not ($vol | Where-Object { $_.DriveLetter -eq 'D' })
Assert-True $gone 'D: no longer exists'

# ---------------------------------------------------------------- 3. WinRE status
Section '3. WinRE status (reagentc /info)'
$reInfo = CmdOut 'reagentc /info'
W '  ' + $reInfo
$reEnabled = $reInfo -match 'Windows RE status:\s*Enabled'
Assert-True $reEnabled 'reagentc reports Windows RE Enabled'
if ($reInfo -match 'harddisk\d+\\partition(\d+)') {
    $rePart = $Matches[1]
    W '  WinRE lives on partition ' + $rePart
    Assert-True ($rePart -eq [string]$RecoveryPartitionNumber) 'WinRE is on the dedicated recovery partition'
} else {
    W '  (could not parse the WinRE location line)'
}

# ---------------------------------------------------------------- 4. BCD
Section '4. Boot Configuration Data'
$cur = CmdOut 'bcdedit /enum {current}'
$bmgr = CmdOut 'bcdedit /enum {bootmgr}'
W '  {current}:'
W ('    ' + $cur)
W '  {bootmgr}:'
W ('    ' + $bmgr)

Assert-True ($cur -match 'recoveryenabled\s+Yes') '{current} has recoveryenabled = Yes'
Assert-True ($cur -match 'recoverysequence\s+\{') '{current} has a recoverysequence (the WinRE object)'
Assert-True ($bmgr -match 'default\s+\{current\}') 'boot manager default is {current}'
Assert-True ($bmgr -match 'path\s+\\EFI\\Microsoft\\Boot\\bootmgfw\.efi') 'boot manager path points at the EFI system partition'

# Locate the WinRE boot loader object and make sure it is not [unknown].
$all = cmd /c 'bcdedit /enum all' 2>&1
$winreObj = $null
$currentId = $null
$bufId = $null
$bufHasUnknown = $false
foreach ($line in $all) {
    if ($line -match '^\s*identifier\s+(\{[0-9a-fA-F-]+\})') {
        if ($bufHasUnknown) { W '  ORPHAN: ' + $bufId + ' -> ramdisk points at [unknown]' }
        $bufId = $Matches[1]
        $bufHasUnknown = $false
    } else {
        if ($line -match '^\s*description\s+Windows Recovery Environment') { $winreObj = $bufId }
        if ($line -match 'recoverysequence\s+(\{[0-9a-fA-F-]+\})' -and $bufId -eq '{current}') { $currentId = $Matches[1] }
        if ($line -match '\[unknown\]') { $bufHasUnknown = $true }
    }
}
if ($bufHasUnknown) { W '  ORPHAN: ' + $bufId + ' -> ramdisk points at [unknown]' }
else { W '  no [unknown] ramdisk references found' }

Assert-True ($currentId -eq $winreObj) '{current}.recoverysequence points at the Windows Recovery Environment object' ("current=$currentId winre=$winreObj")
if ($winreObj) {
    $winreBlock = CmdOut ("bcdedit /enum " + $winreObj)
    W '  ' + $winreObj + ':'
    W ('    ' + $winreBlock)
    Assert-True ($winreBlock -match 'ramdisk=\[\\Device\\HarddiskVolume') 'WinRE ramdisk resolves to a real volume (not [unknown])'
    Assert-True ($winreBlock -match 'winpe\s+Yes') 'WinRE object is flagged winpe = Yes'
}

# ---------------------------------------------------------------- 5. EFI files
Section '5. EFI boot files'
$efiOk = $true
$efiDetail = ''
With-MountedPartition -PartitionNumber 1 -Action {
    param($L)
    foreach ($f in @('EFI\Microsoft\Boot\bootmgfw.efi', 'EFI\Microsoft\Boot\BCD', 'EFI\Boot\bootx64.efi')) {
        $full = "${L}:\$f"
        $present = Test-Path -LiteralPath $full
        W ('  {0,-44} {1}' -f $f, $present)
        if (-not $present) { $script:efiOk = $false; $script:efiDetail = "missing: $full" }
    }
} | Out-Null
Assert-True $efiOk 'EFI system partition contains the firmware boot manager' $efiDetail

# ---------------------------------------------------------------- 6. WinRE image integrity
Section '6. WinRE image integrity (DISM)'
With-MountedPartition -PartitionNumber $RecoveryPartitionNumber -Action {
    param($L)
    $wim = "${L}:\Recovery\WindowsRE\winre.wim"
    if (Test-Path -LiteralPath $wim) {
        # Get-Item can report "not found" on filtered/mounted volumes - Get-ChildItem does not.
        $size = (Get-ChildItem -LiteralPath "${L}:\Recovery\WindowsRE" -Filter 'winre.wim' -Force -EA SilentlyContinue |
                 Select-Object -First 1).Length
        W ('  winre.wim  {0:N0} bytes ({1:N2} GB)' -f $size, ($size / 1GB))
        W '  ' + (CmdOut ("dism /Get-WimInfo /WimFile:`"$wim`""))
    } else {
        W '  winre.wim NOT FOUND on the recovery partition'
    }
} | Out-Null

# ---------------------------------------------------------------- 7. stale copies
Section '7. Stale / leftover copies'
$cWim = 'C:\Recovery\WindowsRE\winre.wim'
if (Test-Path -LiteralPath $cWim) {
    $sz = (Get-ChildItem -LiteralPath 'C:\Recovery\WindowsRE' -Filter 'winre.wim' -Force -EA SilentlyContinue |
           Select-Object -First 1).Length
    W ('  C:\Recovery\WindowsRE\winre.wim still exists ({0:N0} bytes).' -f $sz)
    W '  It is unused while reagentc points at the recovery partition, but it wastes space'
    W '  and will silently win if you ever run "reagentc /enable" again. Safe to delete:'
    W '    takeown /f "C:\Recovery\WindowsRE" /r /d y'
    W '    icacls "C:\Recovery\WindowsRE" /grant *S-1-5-32-544:(OI)(CI)F /t /q'
    W '    rd /s /q "C:\Recovery\WindowsRE"'
} else {
    W '  C:\Recovery\WindowsRE does not exist (good - nothing to shadow the partition copy)'
}

# ---------------------------------------------------------------- 8. references to the removed volume
Section '8. References to the removed drive letter'
$refs = @()
$usf = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -EA SilentlyContinue
if ($usf) {
    $usf.PSObject.Properties | Where-Object { $_.Value -is [string] -and $_.Value -like 'D:*' } |
        ForEach-Object { $refs += ('User Shell Folders: ' + $_.Name + ' = ' + $_.Value) }
}
foreach ($scope in 'Machine', 'User') {
    [Environment]::GetEnvironmentVariables($scope).GetEnumerator() | Where-Object { "$($_.Value)" -like 'D:*' } |
        ForEach-Object { $refs += ($scope + ' env: ' + $_.Name + ' = ' + $_.Value) }
}
Get-CimInstance Win32_PageFileUsage -EA SilentlyContinue | Where-Object { $_.Name -like 'D:*' } |
    ForEach-Object { $refs += ('Page file: ' + $_.Name) }

if ($refs.Count) {
    $refs | ForEach-Object { W ('  ' + $_) }
    W '  These still point at the deleted volume and will break.'
    Assert-True $false 'no registry / environment / page-file references to D:'
} else {
    W '  none found'
    Assert-True $true 'no registry / environment / page-file references to D:'
}

# ---------------------------------------------------------------- summary
Section 'SUMMARY'
W ('  checks run : ' + $script:Checks)
W ('  failures   : ' + $script:Fails)
if ($script:Fails -eq 0) {
    W ''
    W '  RESULT: ALL CHECKS PASSED'
    W '  Next: reboot and run the on-machine tests listed in README.md'
    W '  (Win+Shift+Restart -> Use a device -> Troubleshoot -> Advanced options).'
} else {
    W ''
    W '  RESULT: ' + $script:Fails + ' CHECK(S) FAILED - review the report before rebooting.'
}
W ('  Report written to ' + $ReportPath)

if ($script:Fails -gt 0) { exit 1 } else { exit 0 }
