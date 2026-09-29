<#
.SYNOPSIS
    Read-only verification of a merged C:/D: disk layout and its WinRE recovery setup.

.DESCRIPTION
    Runs every non-invasive check that should pass after a partition merge, writes a
    report file, and prints a PASS / FAIL / SKIP summary.

    Nothing in this script modifies the disk. It only reads partition tables, the BCD
    store, and file listings on temporarily mounted volumes (mount paths are removed
    again before the script exits).

    MUST be run from an ELEVATED PowerShell window. bcdedit, reagentc, DISM and
    Add-PartitionAccessPath all require administrator rights, and without them most
    checks would report a misleading failure. The script refuses to run unelevated
    unless -AllowNotElevated is given (which marks the affected checks SKIP).

    Every check reports one of three states:
      PASS  - the condition holds
      FAIL  - the condition does not hold
      SKIP  - the check could not be evaluated (missing tool, denied access, ...)
    A SKIP is never counted as a pass, and the exit code is 2 if anything was skipped.

NOTE ON EXECUTION POLICY: the Windows PowerShell default is "Restricted", so a
    plain ".\03-verify.ps1" is rejected with PSSecurityException. Use the
    -ExecutionPolicy Bypass form below (applies to that one call only, it does not
    change any machine setting), or relax the current session first with
    "Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass".

NOTE ON ENCODING: this file is intentionally ASCII-only. Windows PowerShell 5.1
    reads .ps1 files using the system ANSI code page, so UTF-8 Chinese comments get
    mangled into syntax errors and the script silently does nothing.

.PARAMETER DiskNumber
    Disk to verify. Default 0.

.PARAMETER RecoveryPartitionNumber
    Partition number of the dedicated recovery partition. Default 4.

.PARAMETER TargetLetter
    Drive letter that should no longer exist after the merge. Default 'D'.

.PARAMETER ReportPath
    Where to write the report. Default: <repo root>\verify-report.txt

.PARAMETER AllowNotElevated
    Run anyway without administrator rights. Elevation-dependent checks become SKIP
    instead of FAIL. Useful for a quick look at the partition layout only.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\03-verify.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\03-verify.ps1 -DiskNumber 0 -RecoveryPartitionNumber 4

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\03-verify.ps1 -ReportPath D:\verify.txt
#>

[CmdletBinding()]
param(
    [int]    $DiskNumber              = 0,
    [int]    $RecoveryPartitionNumber = 4,
    [string] $TargetLetter            = 'D',
    [string] $ReportPath,
    [switch] $AllowNotElevated
)

$ErrorActionPreference = 'Continue'

if (-not $ReportPath) {
    $ReportPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'verify-report.txt'
}

# ---------------------------------------------------------------- helpers
$script:Pass = 0
$script:Fail = 0
$script:Skip = 0

function W([string]$m) {
    Add-Content -Path $ReportPath -Value $m -Encoding UTF8
    Write-Host $m
}

# NOTE: every W call below passes ONE already-formatted string. Do not write
# "W 'a' + $b" - PowerShell parses that as the command W with the single argument
# 'a', and the "+ $b" tail becomes a discarded statement. Always use
# "W ('a' + $b)" or the -f operator.
function Section([string]$title) {
    $pad = [Math]::Max(3, 62 - $title.Length)
    W ''
    W ('=== ' + $title + ' ' + ('=' * $pad))
}

# Run a command and capture its combined output as a single whitespace-normalised line.
# reagentc / bcdedit output can be empty or garbled when piped directly in a child
# process, so always redirect to a file first.
function CmdOut([string]$cmdline) {
    $tmp = Join-Path $env:TEMP ('vv_' + [guid]::NewGuid().ToString('N') + '.txt')
    cmd /c ('chcp 65001 >nul && ' + $cmdline + ' > "' + $tmp + '" 2>&1') | Out-Null
    $text = ''
    if (Test-Path -LiteralPath $tmp) {
        $text = ((Get-Content -LiteralPath $tmp -Raw -EA SilentlyContinue) -replace '\s+', ' ').Trim()
        Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue
    }
    return $text
}

function Assert-True([bool]$ok, [string]$label, [string]$detail = '') {
    if ($ok) {
        $script:Pass++
        W ('  [PASS] ' + $label)
    } else {
        $script:Fail++
        W ('  [FAIL] ' + $label)
        if ($detail) { W ('         ' + $detail) }
    }
}

# A check that could not be evaluated. Never counted as a pass.
function Assert-Skip([string]$label, [string]$reason) {
    $script:Skip++
    W ('  [SKIP] ' + $label)
    W ('         reason: ' + $reason)
}

# Pick an unused drive letter so a partition can be mounted temporarily.
function Get-FreeDriveLetter {
    $used = (Get-PSDrive -PSProvider FileSystem -EA SilentlyContinue).Name
    foreach ($c in [char[]]'RQPSTUVWYZ') {
        $l = [string]$c
        if ($used -notcontains $l) { return $l }
    }
    return $null
}

# Mount a partition, run $Action, always unmount.
# Returns a hashtable: @{ Mounted = $bool; Letter = 'R'; Value = <action result> }
# Callers MUST check .Mounted before trusting .Value, otherwise a failed mount
# silently reports the default value as a pass.
function With-MountedPartition([int]$PartitionNumber, [scriptblock]$Action) {
    $res = @{ Mounted = $false; Letter = $null; Value = $null; Reason = '' }

    if (-not $script:IsAdmin) {
        $res.Reason = 'not elevated - Add-PartitionAccessPath requires administrator'
        return $res
    }
    $letter = Get-FreeDriveLetter
    if (-not $letter) {
        $res.Reason = 'no free drive letter available'
        return $res
    }
    $path = "${letter}:\"

    # Add-PartitionAccessPath emits NO output on success, so its return value cannot
    # be used as a success test - "-not (Add-PartitionAccessPath ...)" is TRUE even
    # when the mount worked. Test for a terminating error instead.
    try {
        Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -AccessPath $path -ErrorAction Stop
    } catch {
        $res.Reason = ('could not mount partition ' + $PartitionNumber + ' at ' + $path + ': ' + $_.Exception.Message)
        $res.Reason += '  (a volume can only be mounted at one path - check mountvol for a stale mount point)'
        return $res
    }

    Start-Sleep -Seconds 1
    $res.Mounted = $true
    $res.Letter = $letter
    try { $res.Value = & $Action $letter } finally {
        Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -AccessPath $path -EA SilentlyContinue
    }
    return $res
}

# Test-Path that reports a third state instead of throwing on access denied.
# Returns 'yes' / 'no' / 'denied'.
function Path-State([string]$p) {
    try {
        return $(if (Test-Path -LiteralPath $p -EA Stop) { 'yes' } else { 'no' })
    } catch [System.UnauthorizedAccessException] {
        return 'denied'
    } catch {
        return 'denied'
    }
}

# ---------------------------------------------------------------- start
Remove-Item -LiteralPath $ReportPath -Force -EA SilentlyContinue

$wid = [Security.Principal.WindowsIdentity]::GetCurrent()
$script:IsAdmin = ([Security.Principal.WindowsPrincipal]$wid).IsInRole(
                     [Security.Principal.WindowsBuiltInRole]::Administrator)

W 'Partition merge verification report'
W ('Generated : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
W ('Computer  : ' + $env:COMPUTERNAME)
W ('Disk      : ' + $DiskNumber + '   Recovery partition: ' + $RecoveryPartitionNumber + '   Target letter: ' + $TargetLetter)
W ('Elevated  : ' + $script:IsAdmin)
W ('Report    : ' + $ReportPath)

if (-not $script:IsAdmin) {
    W ''
    W '*** NOT ELEVATED ***'
    W 'reagentc, bcdedit, DISM and partition mounting all require administrator rights.'
    W 'Re-run from an "Administrator: Windows PowerShell" window, or pass -AllowNotElevated'
    W 'to run a reduced report where the elevation-dependent checks are SKIP rather than FAIL.'
    if (-not $AllowNotElevated) {
        W ''
        W 'Aborting. Nothing was checked.'
        Write-Host ''
        Write-Host 'Re-run as Administrator, e.g.:' -ForegroundColor Yellow
        Write-Host '  powershell -ExecutionPolicy Bypass -File .\03-verify.ps1'
        exit 2
    }
    W ''
    W 'Continuing with -AllowNotElevated.'
}

# ---------------------------------------------------------------- 1. partition layout
Section '1. Partition layout'
$parts = @(Get-Partition -DiskNumber $DiskNumber -EA SilentlyContinue | Sort-Object PartitionNumber)
if (-not $parts) {
    Assert-True $false ('can read the partition table on disk ' + $DiskNumber) 'Get-Partition returned nothing'
} else {
    $rows = @()
    foreach ($p in $parts) {
        $type = if ($p.GptType) { ($p.GptType -replace '.*\\', '') } else { $p.Type }
        $ltr  = if ($p.DriveLetter) { [string]$p.DriveLetter + ':' } else { '(none)' }
        $rows += ('  Part{0}  {1,-7} {2,-38} {3,10:N3} GB  offset {4}' -f `
                    $p.PartitionNumber, $ltr, $type, ($p.Size / 1GB), $p.Offset)
    }
    $rows | ForEach-Object { W $_ }

    $sysPart = $parts | Where-Object { $_.GptType -like '*c12a7328*' }
    $msrPart = $parts | Where-Object { $_.GptType -like '*e3c9e316*' }
    $recPart = $parts | Where-Object { $_.PartitionNumber -eq $RecoveryPartitionNumber }
    $cPart   = $parts | Where-Object { $_.DriveLetter -eq 'C' }

    Assert-True ([bool]$sysPart) 'EFI system partition present (GPT type c12a7328)'
    Assert-True ([bool]$msrPart) 'Microsoft reserved partition present (GPT type e3c9e316)'
    Assert-True ([bool]$cPart)   'C: present on this disk'
    Assert-True ([bool]$recPart) ('recovery partition is Part' + $RecoveryPartitionNumber)
    if ($recPart) {
        Assert-True ($recPart.GptType -like '*de94bba4*') `
                    'recovery partition has the Windows RE GPT type (de94bba4)' $recPart.GptType
        # A recovery partition smaller than the wim cannot hold the image.
        if ($script:IsAdmin) {
            $recFree = (Get-PartitionSupportedSize -DiskNumber $DiskNumber -PartitionNumber $RecoveryPartitionNumber -EA SilentlyContinue)
            if ($recFree) { W ('  recovery partition free space: {0:N2} GB' -f ($recFree.SizeMax / 1GB)) }
        }
    }

    $disk = Get-Disk -Number $DiskNumber -EA SilentlyContinue
    if ($cPart -and $disk) {
        $tail = ($disk.Size - ($cPart.Offset + $cPart.Size))
        W ('  unallocated tail after C: = {0:N3} GB' -f ($tail / 1GB))
        Assert-True (($tail -gt 0) -and ($tail -lt 5GB)) `
                    'C: extends to just before the trailing recovery partition'
    }
}

# ---------------------------------------------------------------- 2. drive letters
Section '2. Drive letters (the merged-away letter must be gone)'
$vol = Get-Volume -EA SilentlyContinue
($vol | Where-Object { $_.DriveLetter } | Sort-Object DriveLetter) | ForEach-Object {
    W ('  {0}:  {1,10:N2} GB   {2}' -f $_.DriveLetter, ($_.Size / 1GB), $_.FileSystem)
}
$target = $vol | Where-Object { $_.DriveLetter -eq $TargetLetter }
Assert-True (-not $target) ($TargetLetter + ': no longer exists')

# ---------------------------------------------------------------- 3. WinRE status
Section '3. WinRE status (reagentc /info)'
if (-not $script:IsAdmin) {
    Assert-Skip 'reagentc reports Windows RE Enabled' 'not elevated'
} else {
    $reInfo = CmdOut 'reagentc /info'
    W ('  ' + $reInfo)
    $reEnabled = $reInfo -match 'Windows RE status:\s*Enabled'
    Assert-True $reEnabled 'reagentc reports Windows RE Enabled'
    if ($reInfo -match 'harddisk\d+\\partition(\d+)') {
        $rePart = $Matches[1]
        W ('  WinRE lives on partition ' + $rePart)
        Assert-True ($rePart -eq [string]$RecoveryPartitionNumber) `
                    'WinRE is on the dedicated recovery partition' `
                    ('reported partition ' + $rePart + ', expected ' + $RecoveryPartitionNumber)
    } else {
        Assert-Skip 'WinRE is on the dedicated recovery partition' 'could not parse the WinRE location line'
    }
}

# ---------------------------------------------------------------- 4. BCD
Section '4. Boot Configuration Data'
$currentId = $null
$winreObj  = $null

if (-not $script:IsAdmin) {
    Assert-Skip 'BCD checks' 'not elevated - bcdedit needs administrator rights'
} else {
    $cur  = CmdOut 'bcdedit /enum {current}'
    $bmgr = CmdOut 'bcdedit /enum {bootmgr}'
    W '  {current}:'
    W ('    ' + $cur)
    W '  {bootmgr}:'
    W ('    ' + $bmgr)

    # bcdedit reports permission / store errors as ordinary text - catch those first
    # so they are not mistaken for "property absent".
    $bcdReadable = ($cur -notmatch 'could not be opened') -and ($cur -notmatch 'Access is denied') -and
                   ($bmgr -notmatch 'could not be opened') -and ($bmgr -notmatch 'Access is denied')
    if (-not $bcdReadable) {
        Assert-Skip 'BCD checks' 'bcdedit could not open the boot configuration data store'
    } else {
        Assert-True ($cur  -match 'recoveryenabled\s+Yes') '{current} has recoveryenabled = Yes'
        Assert-True ($cur  -match 'recoverysequence\s+\{') '{current} has a recoverysequence (the WinRE object)'
        Assert-True ($bmgr -match 'default\s+\{current\}') 'boot manager default is {current}'
        Assert-True ($bmgr -match 'path\s+\\EFI\\Microsoft\\Boot\\bootmgfw\.efi') `
                    'boot manager path points at the EFI system partition'

        # Walk the object list once, tracking which identifier each line belongs to.
        # NOTE: the identifier pattern must accept aliases such as {current} as well
        # as GUIDs. A GUID-only pattern like \{[0-9a-f-]+\} silently fails on
        # "identifier {current}" because "current" is not hex, and then every
        # following property gets attributed to the previous object.
        $all = cmd /c 'bcdedit /enum all' 2>&1
        $bufId = $null
        $bufHasUnknown = $false
        $orphanCount = 0
        foreach ($line in $all) {
            if ($line -match '^\s*identifier\s+(\{[^{}]+\})') {
                if ($bufHasUnknown) {
                    W ('  ORPHAN: ' + $bufId + ' -> ramdisk points at [unknown]')
                    $orphanCount++
                }
                $bufId = $Matches[1]
                $bufHasUnknown = $false
            } else {
                if ($line -match '^\s*description\s+Windows Recovery Environment') { $winreObj = $bufId }
                if ($line -match '^\s*recoverysequence\s+(\{[^{}]+\})' -and $bufId -eq '{current}') { $currentId = $Matches[1] }
                if ($line -match '\[unknown\]') { $bufHasUnknown = $true }
            }
        }
        if ($bufHasUnknown) {
            W ('  ORPHAN: ' + $bufId + ' -> ramdisk points at [unknown]')
            $orphanCount++
        } else {
            W '  no [unknown] ramdisk references found'
        }
        Assert-True ($orphanCount -eq 0) 'no orphaned [unknown] BCD objects left over from the deleted recovery partition'

        # Both identifiers must actually have been found - a null -eq null comparison
        # would otherwise report a bogus pass.
        if ($currentId -and $winreObj) {
            Assert-True ($currentId -eq $winreObj) `
                        '{current}.recoverysequence points at the Windows Recovery Environment object' `
                        ('current=' + $currentId + ' winre=' + $winreObj)
        } else {
            Assert-Skip '{current}.recoverysequence points at the Windows Recovery Environment object' `
                       ('could not identify the objects (recoverysequence=' + $currentId + ', winre object=' + $winreObj + ')')
        }

        if ($winreObj) {
            $winreBlock = CmdOut ('bcdedit /enum ' + $winreObj)
            W ('  ' + $winreObj + ':')
            W ('    ' + $winreBlock)
            Assert-True ($winreBlock -match 'ramdisk=\[\\Device\\HarddiskVolume') `
                        'WinRE ramdisk resolves to a real volume (not [unknown])'
            Assert-True ($winreBlock -match 'winpe\s+Yes') 'WinRE object is flagged winpe = Yes'
        }
    }
}

# ---------------------------------------------------------------- 5. EFI files
Section '5. EFI boot files'
$efi = With-MountedPartition -PartitionNumber 1 -Action {
    param($L)
    $missing = @()
    foreach ($f in @('EFI\Microsoft\Boot\bootmgfw.efi', 'EFI\Microsoft\Boot\BCD', 'EFI\Boot\bootx64.efi')) {
        $full = "${L}:\$f"
        $present = $false
        try { $present = Test-Path -LiteralPath $full -EA Stop } catch { $present = $false }
        W ('  {0,-44} {1}' -f $f, $present)
        if (-not $present) { $missing += $full }
    }
    return $missing
}
if ($efi.Mounted) {
    if ($efi.Value -and $efi.Value.Count -gt 0) {
        Assert-True $false 'EFI system partition contains the firmware boot manager' ('missing: ' + ($efi.Value -join ', '))
    } else {
        Assert-True $true 'EFI system partition contains the firmware boot manager'
    }
} else {
    Assert-Skip 'EFI system partition contains the firmware boot manager' $efi.Reason
}

# ---------------------------------------------------------------- 6. WinRE image integrity
Section '6. WinRE image integrity (DISM)'
$wim = With-MountedPartition -PartitionNumber $RecoveryPartitionNumber -Action {
    param($L)
    $wimPath = "${L}:\Recovery\WindowsRE\winre.wim"
    $st = Path-State $wimPath
    if ($st -eq 'no')   { return @{ State = 'missing'; Size = 0; Info = '' } }
    if ($st -eq 'denied') { return @{ State = 'denied'; Size = 0; Info = '' } }
    # Get-Item can report "not found" on filtered/mounted volumes - Get-ChildItem does not.
    $sz = (Get-ChildItem -LiteralPath "${L}:\Recovery\WindowsRE" -Filter 'winre.wim' -Force -EA SilentlyContinue |
             Select-Object -First 1).Length
    return @{ State = 'found'; Size = $sz; Info = (CmdOut ('dism /Get-WimInfo /WimFile:"' + $wimPath + '"')) }
}
if (-not $wim.Mounted) {
    Assert-Skip 'winre.wim is present on the recovery partition' $wim.Reason
} else {
    switch ($wim.Value.State) {
        'missing' { Assert-True $false 'winre.wim is present on the recovery partition' 'not found under \Recovery\WindowsRE\' }
        'denied'  { Assert-Skip 'winre.wim is present on the recovery partition' 'access denied while reading the recovery partition' }
        default {
            W ('  winre.wim  {0:N0} bytes ({1:N2} GB) on disk' -f $wim.Value.Size, ($wim.Value.Size / 1GB))
            Assert-True ($wim.Value.Size -gt 0) 'winre.wim is present on the recovery partition'
            W ('  ' + $wim.Value.Info)
            $infoOk = $wim.Value.Info -match 'Windows Recovery Environment'
            Assert-True $infoOk 'DISM can read the wim and it is a Windows Recovery Environment image'

            # DISM prints "Size : N bytes" (with a space before the colon).
            if ($wim.Value.Info -match 'Size\s*:\s*([0-9,]+)') {
                $uncompressed = [int64](($Matches[1]) -replace '[^0-9]', '')
                W ('  uncompressed payload: {0:N0} bytes ({1:N2} GB)' -f $uncompressed, ($uncompressed / 1GB))
                W '  Note: the uncompressed size is the RAM footprint at boot time, NOT the'
                W '  space the partition needs. The wim stays compressed on disk and is'
                W '  expanded into memory. Size the partition from the FILE size.'
            }

            $rec = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $RecoveryPartitionNumber -EA SilentlyContinue
            if ($rec) {
                $used = $wim.Value.Size
                $freePct = [int](100 * ($rec.Size - $used) / $rec.Size)
                W ('  recovery partition: {0:N2} GB total, {1:N2} GB free after the wim ({2}% headroom)' -f `
                    ($rec.Size / 1GB), (($rec.Size - $used) / 1GB), $freePct)
                # The wim must fit, with room for NTFS metadata and for reagentc /enable
                # to rewrite it. 25% headroom is a reasonable floor.
                Assert-True ($rec.Size -ge ($used * 1.25)) `
                            'recovery partition is big enough for the wim plus reagentc rewrite headroom' `
                            ('partition {0:N2} GB vs wim {1:N2} GB' -f ($rec.Size/1GB), ($used/1GB))
            }
        }
    }
}

# ---------------------------------------------------------------- 7. stale copies
Section '7. Stale / leftover copies'
$cWimState = Path-State 'C:\Recovery\WindowsRE\winre.wim'
switch ($cWimState) {
    'denied' {
        Assert-Skip 'no stale C:\Recovery\WindowsRE shadow copy' 'access denied reading C:\Recovery (re-run elevated)'
        W '  From an elevated shell you can inspect it with:'
        W '    dir /a "C:\Recovery\WindowsRE"'
    }
    'yes' {
        $sz = (Get-ChildItem -LiteralPath 'C:\Recovery\WindowsRE' -Filter 'winre.wim' -Force -EA SilentlyContinue |
                Select-Object -First 1).Length
        W ('  C:\Recovery\WindowsRE\winre.wim still exists ({0:N0} bytes, {1:N2} GB).' -f $sz, ($sz / 1GB))
        W '  It is unused while reagentc points at the recovery partition, but it wastes'
        W '  space and it will silently win the next time you run "reagentc /enable".'
        W '  Safe to delete (the folder has a protected ACL, so take ownership first):'
        W '    takeown /f "C:\Recovery\WindowsRE" /r /d y'
        W '    icacls "C:\Recovery\WindowsRE" /grant *S-1-5-32-544:(OI)(CI)F /t /q'
        W '    rd /s /q "C:\Recovery\WindowsRE"'
        Assert-True $false 'no stale C:\Recovery\WindowsRE shadow copy' 'wasted space, and shadows the partition copy on reagentc /enable'
    }
    default {
        W '  C:\Recovery\WindowsRE does not exist (good - nothing to shadow the partition copy)'
        Assert-True $true 'no stale C:\Recovery\WindowsRE shadow copy'
    }
}

# ---------------------------------------------------------------- 8. references to the removed volume
Section ('8. References to the removed drive letter ' + $TargetLetter)
$refs = @()
$usf = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -EA SilentlyContinue
if ($usf) {
    $usf.PSObject.Properties | Where-Object { $_.Value -is [string] -and $_.Value -like ($TargetLetter + ':*') } |
        ForEach-Object { $refs += ('User Shell Folders: ' + $_.Name + ' = ' + $_.Value) }
}
foreach ($scope in 'Machine', 'User') {
    [Environment]::GetEnvironmentVariables($scope).GetEnumerator() |
        Where-Object { "$($_.Value)" -like ($TargetLetter + ':*') } |
        ForEach-Object { $refs += ($scope + ' env: ' + $_.Name + ' = ' + $_.Value) }
}
Get-CimInstance Win32_PageFileUsage -EA SilentlyContinue |
    Where-Object { $_.Name -like ($TargetLetter + ':*') } |
    ForEach-Object { $refs += ('Page file: ' + $_.Name) }

if ($refs.Count) {
    $refs | ForEach-Object { W ('  ' + $_) }
    W '  These still point at the deleted volume and will break.'
    Assert-True $false 'no registry / environment / page-file references to ' + $TargetLetter
} else {
    W '  none found'
    Assert-True $true ('no registry / environment / page-file references to ' + $TargetLetter)
}

# ---------------------------------------------------------------- summary
Section 'SUMMARY'
W ('  passed : ' + $script:Pass)
W ('  failed : ' + $script:Fail)
W ('  skipped: ' + $script:Skip)
W ''

if ($script:Fail -gt 0) {
    W ('  RESULT: ' + $script:Fail + ' CHECK(S) FAILED - review the report before rebooting.')
} elseif ($script:Skip -gt 0) {
    W '  RESULT: no failures, but some checks were skipped.'
    W '  Re-run from an Administrator shell to get a complete report.'
} else {
    W '  RESULT: ALL CHECKS PASSED'
    W '  Next: reboot and run the on-machine tests listed in README.md'
    W '  (Win+Shift+Restart -> Use a device -> Troubleshoot -> Advanced options).'
}
W ''
W ('  Report written to ' + $ReportPath)

if ($script:Fail -gt 0)          { exit 1 }
elseif ($script:Skip -gt 0)      { exit 2 }
else                             { exit 0 }
