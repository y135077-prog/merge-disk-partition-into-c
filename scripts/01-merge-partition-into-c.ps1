<#
.SYNOPSIS
    Merge an empty secondary partition (e.g. D:) into the system partition C:,
    preserving / relocating the Windows Recovery Environment.

.DESCRIPTION
    Built entirely with Windows built-in tooling (PowerShell storage cmdlets +
    reagentc). No third-party partition manager required.

    Steps
      1. Pre-flight checks (elevation, target emptiness, free space, BitLocker)
      2. Back up WinRE  <-- done MANUALLY, because reagentc /backup is missing
                              on some Windows editions (see notes)
      3. reagentc /disable
      4. Delete the target partition and the recovery partition that sits
         between it and C:
      5. Extend C: to the maximum size
      6. Verify

    Pair with 02-rebuild-winre.ps1 if you want the recovery partition back.

    NOTE ON ENCODING: this file is intentionally ASCII-only. Windows PowerShell
    5.1 reads .ps1 files using the system ANSI code page, so UTF-8 Chinese
    comments get mangled into syntax errors and the script silently does
    nothing. If you want non-ASCII comments, save the file as "UTF-8 with BOM".

NOTE ON EXECUTION POLICY: the Windows PowerShell default is "Restricted", so a
    plain ".\01-merge-partition-into-c.ps1" is rejected with PSSecurityException.
    Use the -ExecutionPolicy Bypass form below (applies to that one call only, it
    does not change any machine setting), or relax the current session first with
    "Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass".

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\01-merge-partition-into-c.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\01-merge-partition-into-c.ps1 -DiskNumber 0 -TargetLetter 'D:'
#>

[CmdletBinding()]
param(
    [int]    $DiskNumber    = 0,
    [string] $TargetLetter  = 'D:',
    [string] $BackupDir     = 'C:\WinREBackup',
    [int]    $MinFreeGB     = 3
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- helpers ---

$script:LogFile = Join-Path $PSScriptRoot ("merge-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] {1,-5} {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Write-Host $line
    try { Add-Content -Path $script:LogFile -Value $line -ErrorAction Stop } catch { }
}

function Invoke-Native {
    <# Run a native exe and reliably capture stdout+stderr.
       Piping native output straight into PowerShell sometimes yields nothing
       inside elevated child processes - redirecting to a file always works. #>
    param([string]$CommandLine)
    $tmp = Join-Path $env:TEMP ("_native_{0}.txt" -f ([guid]::NewGuid().ToString('N')))
    cmd /c "$CommandLine > `"$tmp`" 2>&1"
    $text = ''
    if (Test-Path -LiteralPath $tmp) {
        $text = (Get-Content -LiteralPath $tmp -Raw -ErrorAction SilentlyContinue) -replace '\s+', ' '
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return '(no output)' }
    return $text.Trim()
}

function Get-FileSizeBytes {
    <# Get-Item can report "not found" for files that Test-Path and
       Get-ChildItem both see clearly (filter-driver / mount quirks).
       Enumerate the parent directory instead. #>
    param([string]$Path)
    $item = Get-ChildItem -LiteralPath (Split-Path -Parent $Path) -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ceq (Split-Path -Leaf $Path) } |
            Select-Object -First 1
    if ($item) { return [int64]$item.Length }
    return -1
}

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-GB {
    param([double]$Bytes)
    return [math]::Round($Bytes / 1GB, 3)
}

function Get-FreeDriveLetter {
    $used = (Get-PSDrive -PSProvider FileSystem).Name
    return @('R', 'Q', 'S', 'T', 'U', 'V', 'W', 'X') | Where-Object { $used -notcontains $_ } | Select-Object -First 1
}

# ------------------------------------------------------------------ start ---

Write-Log "=== merge D: into C: ===" 'INFO'

if (-not (Test-Elevated)) {
    Write-Log 'This script MUST run from an elevated PowerShell (Run as administrator).' 'FATAL'
    exit 9
}
Write-Log "Running elevated. Log: $script:LogFile"

# ---- 1. pre-flight checks --------------------------------------------------

if (-not (Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue)) {
    Write-Log "Disk $DiskNumber not found." 'FATAL'
    exit 1
}
$disk = Get-Disk -Number $DiskNumber
if ($disk.PartitionStyle -ne 'GPT') {
    Write-Log "Partition style is $($disk.PartitionStyle), expected GPT. Aborting." 'FATAL'
    exit 1
}
Write-Log ("Disk {0}: {1} ({2} GB, {3})" -f $DiskNumber, $disk.FriendlyName, (Format-GB $disk.Size), $disk.PartitionStyle)

$all = @(Get-Partition -DiskNumber $DiskNumber | Sort-Object PartitionNumber)

$cPart = $all | Where-Object { $_.DriveLetter -eq 'C' } | Select-Object -First 1
if (-not $cPart) { Write-Log 'C: not found on this disk.' 'FATAL'; exit 1 }

$letter = $TargetLetter.TrimEnd(':')
$tPart = $all | Where-Object { $_.DriveLetter -eq $letter } | Select-Object -First 1
if (-not $tPart) { Write-Log "$TargetLetter not found on disk $DiskNumber." 'FATAL'; exit 1 }

# partitions sitting between C: and the target - these must go too
$between = @($all | Where-Object {
    $_.PartitionNumber -gt $cPart.PartitionNumber -and
    $_.PartitionNumber -lt $tPart.PartitionNumber
})
Write-Log ("C:  = partition {0} ({1} GB)" -f $cPart.PartitionNumber, (Format-GB $cPart.Size))
Write-Log ("{0} = partition {1} ({2} GB)" -f $TargetLetter, $tPart.PartitionNumber, (Format-GB $tPart.Size))
if ($between.Count) {
    Write-Log ("Between them: {0}" -f (($between | ForEach-Object {
        "partition $($_.PartitionNumber) [$($_.Type), $(Format-GB $_.Size) GB]" }) -join ', '))
}

# target must be empty
$driveRoot = "$($tPart.DriveLetter):\"
$items = @(Get-ChildItem $driveRoot -Force -Recurse -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -ne 'System Volume Information' })
Write-Log "$TargetLetter contains $($items.Count) item(s) (excluding System Volume Information)"
if ($items.Count -gt 0) {
    Write-Log "$TargetLetter is NOT empty. Aborting to avoid data loss." 'FATAL'
    $items | Select-Object -First 20 | ForEach-Object { Write-Log "    $($_.FullName)" 'FATAL' }
    exit 2
}

# free space on C:
$cVol = Get-Volume -DriveLetter C
Write-Log ("C: free space: {0} GB (need >= {1} GB)" -f (Format-GB $cVol.SizeRemaining), $MinFreeGB)
if ($cVol.SizeRemaining -lt ($MinFreeGB * 1GB)) {
    Write-Log 'Not enough free space on C:.' 'FATAL'
    exit 3
}

# BitLocker would block the operation
try {
    $bl = @(Get-BitLockerVolume -ErrorAction Stop | Where-Object { $_.VolumeType -eq 'Filesystem' -and $_.ProtectionStatus -eq 'On' })
    if ($bl.Count) {
        Write-Log "BitLocker is on for: $(($bl.MountPoint) -join ', ')" 'WARN'
        Write-Log 'Suspend BitLocker (Manage BitLocker -> Suspend) before continuing.' 'FATAL'
        exit 4
    }
} catch { Write-Log 'Could not query BitLocker state (ignored).' 'WARN' }

Write-Log 'Pre-flight checks passed.' 'INFO'

# ---- 2. back up WinRE (manually) ------------------------------------------

Write-Log 'Locating the WinRE partition...' 'INFO'
$winreSource = $null
foreach ($p in $all) {
    $free = Get-FreeDriveLetter
    if (-not $free) { break }
    try {
        Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $p.PartitionNumber -AccessPath "${free}:\" -ErrorAction Stop
        Start-Sleep -Milliseconds 800
        $candidate = Get-ChildItem "${free}:\" -Recurse -Force -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -ieq 'winre.wim' } | Select-Object -First 1
        if ($candidate) {
            $winreSource = [pscustomobject]@{
                PartitionNumber = $p.PartitionNumber
                Directory       = $candidate.DirectoryName
                File            = $candidate.Name
            }
            Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $p.PartitionNumber -AccessPath "${free}:\" -ErrorAction SilentlyContinue
            break
        }
        Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $p.PartitionNumber -AccessPath "${free}:\" -ErrorAction SilentlyContinue
    } catch {
        Write-Log "Could not probe partition $($p.PartitionNumber): $($_.Exception.Message)" 'WARN'
    }
}

if (-not $winreSource) {
    Write-Log 'No winre.wim found on any partition. Nothing to back up (WinRE may already be on C:).' 'WARN'
} else {
    Write-Log ("Found winre.wim on partition {0} at {1}" -f $winreSource.PartitionNumber, $winreSource.Directory)
    $free = Get-FreeDriveLetter
    Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $winreSource.PartitionNumber -AccessPath "${free}:\" -ErrorAction Stop
    Start-Sleep -Milliseconds 800
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    # the path captured while probing belongs to the previous mount,
    # so re-resolve it through the drive letter we just assigned
    $rebuilt = Get-ChildItem "${free}:\" -Recurse -Force -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -ieq 'winre.wim' } | Select-Object -First 1
    if ($rebuilt) {
        Copy-Item $rebuilt.FullName $BackupDir -Force
        $siblingDir = $rebuilt.DirectoryName
        Get-ChildItem -LiteralPath $siblingDir -Force -ErrorAction SilentlyContinue |
            ForEach-Object { Copy-Item $_.FullName $BackupDir -Force -ErrorAction SilentlyContinue }
        Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $winreSource.PartitionNumber -AccessPath "${free}:\" -ErrorAction SilentlyContinue
        Write-Log "Unmounted ${free}:."

        $sz = Get-FileSizeBytes (Join-Path $BackupDir $rebuilt.Name)
        Write-Log ("Backup written to {0} ({1} bytes)" -f $BackupDir, $sz)
        if ($sz -lt 100MB) {
            Write-Log 'Backup looks truncated. Aborting before anything destructive happens.' 'FATAL'
            exit 5
        }
    } else {
        Write-Log 'winre.wim vanished from the recovery partition. Aborting.' 'FATAL'
        exit 5
    }
}

# ---- 3. disable WinRE -----------------------------------------------------

Write-Log 'Disabling WinRE...'
Write-Log ("reagentc /disable -> " + (Invoke-Native 'reagentc /disable'))

# ---- 4. delete partitions from the back ----------------------------------

$toDelete = @($tPart) + $between
$toDelete = $toDelete | Sort-Object PartitionNumber -Descending

foreach ($p in $toDelete) {
    Write-Log ("Deleting partition {0} [{1}, {2} GB]" -f $p.PartitionNumber, $p.Type, (Format-GB $p.Size))
    try {
        $p | Remove-Partition -Confirm:$false -ErrorAction Stop
        Write-Log '  -> removed'
    } catch {
        Write-Log "  -> FAILED: $($_.Exception.Message)" 'FATAL'
        exit 6
    }
}

# ---- 5. extend C: ---------------------------------------------------------

Start-Sleep -Seconds 2
$sup = Get-PartitionSupportedSize -DiskNumber $DiskNumber -PartitionNumber $cPart.PartitionNumber
Write-Log ("C:: {0} GB -> max {1} GB" -f (Format-GB $cPart.Size), (Format-GB $sup.SizeMax))
try {
    Get-Partition -DiskNumber $DiskNumber -PartitionNumber $cPart.PartitionNumber |
        Resize-Partition -Size $sup.SizeMax -ErrorAction Stop
    Write-Log '  -> extended'
} catch {
    Write-Log "  -> FAILED: $($_.Exception.Message)" 'FATAL'
    exit 7
}

# ---- 6. verify ------------------------------------------------------------

Write-Log '--- resulting layout ---'
foreach ($p in (Get-Partition -DiskNumber $DiskNumber | Sort-Object PartitionNumber)) {
    $l = if ($p.DriveLetter) { "$($p.DriveLetter):" } else { '(none)' }
    Write-Log ("  Part{0}  {1,-8} {2,-9} {3,9} GB  {4}" -f $p.PartitionNumber, $l, $p.Type, (Format-GB $p.Size), $p.GptType)
}
$cVol = Get-Volume -DriveLetter C
Write-Log ("C:: {0} GB total, {1} GB free" -f (Format-GB $cVol.Size), (Format-GB $cVol.SizeRemaining))
if (Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue) {
    Write-Log "$TargetLetter still present - unexpected." 'WARN'
}

Write-Log ''
Write-Log "Merge complete. Next: run 02-rebuild-winre.ps1 (optional) or 'reagentc /enable'."
Write-Log "Keep $BackupDir until you have confirmed recovery works."
