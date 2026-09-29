<#
.SYNOPSIS
    Recreate the Windows Recovery (WinRE) partition and move WinRE onto it,
    restoring the factory-style layout after a C:/D: merge.

.DESCRIPTION
    Pair this with 01-merge-partition-into-c.ps1, or run it standalone if you ever need
    to restore WinRE onto its own volume.

    Steps
      1. Make room at the end of the disk (shrink C:).
         NOTE: always subtract from the CURRENT size, never from
         Get-PartitionSupportedSize().SizeMax, or you will grow it instead.
      2. Create an NTFS partition of type "Microsoft Recovery" with no drive
         letter. The cmdlet parameter is -AssignDriveLetter:$false.
         32 MB of slack is required because GPT reserves ~1 MB at the end.
      3. Copy winre.wim into \Recovery\WindowsRE on that partition.
      4. reagentc /disable, then delete C:\Recovery\WindowsRE (it has a
         restrictive ACL, so take ownership first) - otherwise reagentc /enable
         will keep preferring the copy on C:.
      5. Point ReAgent.xml at the new partition.
      6. reagentc /enable, then verify. Falls back to C: if anything fails.

    NOTE ON ENCODING: ASCII only, on purpose. See 01-merge-partition-into-c.ps1.

.EXAMPLE
    .\02-rebuild-winre.ps1
    .\02-rebuild-winre.ps1 -DiskNumber 0 -RecoverySizeGB 2
#>

[CmdletBinding()]
param(
    [int]    $DiskNumber      = 0,
    [string] $BackupDir       = 'C:\WinREBackup',
    [double] $RecoverySizeGB  = 2,
    [string] $RecoveryGptType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'   # Microsoft Recovery
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

$HeadroomBytes = 32MB   # GPT secondary header + alignment slack
$recSize       = [int64]($RecoverySizeGB * 1GB)

# ---------------------------------------------------------------- helpers ---

$script:LogFile = Join-Path $PSScriptRoot ("rebuild-winre-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] {1,-5} {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Write-Host $line
    try { Add-Content -Path $script:LogFile -Value $line -ErrorAction Stop } catch { }
}

function Invoke-Native {
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
    param([string]$Path)
    $item = Get-ChildItem -LiteralPath (Split-Path -Parent $Path) -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ceq (Split-Path -Leaf $Path) } | Select-Object -First 1
    if ($item) { return [int64]$item.Length }
    return -1
}

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-GB { param([double]$Bytes) return [math]::Round($Bytes / 1GB, 3) }

function Get-FreeDriveLetter {
    $used = (Get-PSDrive -PSProvider FileSystem).Name
    return @('R', 'Q', 'S', 'T', 'U', 'V', 'W', 'X') | Where-Object { $used -notcontains $_ } | Select-Object -First 1
}

function Get-TailFreeSpace {
    $d = (Get-Disk -Number $DiskNumber).Size
    $u = (Get-Partition -DiskNumber $DiskNumber | Measure-Object -Property Size -Sum).Sum
    return $d - $u
}

# ------------------------------------------------------------------ start ---

Write-Log '=== rebuild WinRE partition ==='

if (-not (Test-Elevated)) {
    Write-Log 'This script MUST run from an elevated PowerShell (Run as administrator).' 'FATAL'
    exit 9
}
Write-Log "Running elevated. Log: $script:LogFile"

# ---- 0. locate the winre.wim backup ---------------------------------------

$wimFile = Get-ChildItem -LiteralPath $BackupDir -Force -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -ieq 'winre.wim' } | Select-Object -First 1
if (-not $wimFile) {
    Write-Log "No winre.wim backup in $BackupDir. Run 01-merge-partition-into-c.ps1 first." 'FATAL'
    exit 1
}
$wimPath = $wimFile.FullName
$wimSize = [int64]$wimFile.Length
Write-Log ("Using backup: {0} ({1} bytes)" -f $wimPath, $wimSize)
if ($wimSize -lt 100MB) {
    Write-Log 'Backup winre.wim is suspiciously small.' 'FATAL'
    exit 1
}

$reAgentPath = Join-Path $env:SystemRoot 'System32\Recovery\ReAgent.xml'
if (-not (Test-Path -LiteralPath $reAgentPath)) {
    Write-Log "ReAgent.xml not found at $reAgentPath" 'FATAL'
    exit 1
}

# remember the current BCD id of the WinRE object so we can restore it later
[xml]$xml = Get-Content -LiteralPath $reAgentPath
$winreBcdId = $xml.WindowsRE.WinreBCD.id
Write-Log "Current WinreBCD id: $winreBcdId"
Copy-Item -LiteralPath $reAgentPath (Join-Path $PSScriptRoot 'ReAgent.xml.before') -Force
Write-Log 'ReAgent.xml backed up next to this script.'

$cPart = Get-Partition -DiskNumber $DiskNumber | Where-Object { $_.DriveLetter -eq 'C' } | Select-Object -First 1
if (-not $cPart) { Write-Log 'C: not found.' 'FATAL'; exit 1 }
$recSize = [math]::Max($recSize, $wimSize + 256MB)   # never make it smaller than the image needs

# ---- 1. free up space at the end of the disk ------------------------------

$free = Get-TailFreeSpace
Write-Log ("Free space at end of disk: {0} MB" -f [math]::Round($free / 1MB, 1))

if ($free -lt ($recSize + $HeadroomBytes)) {
    $need = $recSize - $free + $HeadroomBytes
    Write-Log ("Shrinking C: by {0} MB" -f [math]::Round($need / 1MB, 1))
    $sup = Get-PartitionSupportedSize -DiskNumber $DiskNumber -PartitionNumber $cPart.PartitionNumber
    $curSize = (Get-Partition -DiskNumber $DiskNumber -PartitionNumber $cPart.PartitionNumber).Size
    $newSize = $curSize - $need
    if ($newSize -lt $sup.SizeMin) { $newSize = $sup.SizeMin }
    Write-Log ("  C:: {0} GB -> {1} GB" -f (Format-GB $curSize), (Format-GB $newSize))
    try {
        Get-Partition -DiskNumber $DiskNumber -PartitionNumber $cPart.PartitionNumber |
            Resize-Partition -Size $newSize -ErrorAction Stop
        Write-Log '  -> shrunk'
    } catch {
        Write-Log "  -> SHRINK FAILED: $($_.Exception.Message)" 'FATAL'
        Write-Log 'Run Disk Cleanup / defragmentation first, then retry.' 'FATAL'
        exit 2
    }
    Start-Sleep -Seconds 2
}

$free = Get-TailFreeSpace
if ($free -lt ($recSize + $HeadroomBytes)) {
    Write-Log ("Still not enough room ({0} MB free). Aborting." -f [math]::Round($free / 1MB, 1)) 'FATAL'
    exit 3
}

# ---- 2. create the recovery partition -------------------------------------

Write-Log ("Creating {0} GB Microsoft Recovery partition..." -f (Format-GB $recSize))
$newPart = $null
foreach ($gpt in @($RecoveryGptType, $null)) {
    try {
        if ($gpt) {
            $newPart = New-Partition -DiskNumber $DiskNumber -Size $recSize -GptType $gpt -AssignDriveLetter:$false -ErrorAction Stop
        } else {
            $newPart = New-Partition -DiskNumber $DiskNumber -Size $recSize -AssignDriveLetter:$false -ErrorAction Stop
        }
        Write-Log "  New-Partition succeeded (GptType = $gpt)"
        break
    } catch {
        Write-Log "  New-Partition failed (GptType = $gpt): $($_.Exception.Message)" 'WARN'
    }
}
if (-not $newPart -or -not $newPart.PartitionNumber) {
    Write-Log 'Could not create the recovery partition.' 'FATAL'
    exit 4
}
$recPartNo = $newPart.PartitionNumber

try {
    Format-Volume -Partition $newPart -FileSystem NTFS -NewFileSystemLabel 'WinRE' -Force -Confirm:$false -ErrorAction Stop | Out-Null
    Write-Log '  formatted NTFS'
} catch {
    Write-Log "  FORMAT FAILED: $($_.Exception.Message)" 'FATAL'
    exit 5
}

$rec = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $recPartNo
if ($rec.DriveLetter) {
    Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $recPartNo -AccessPath "$($rec.DriveLetter):\" -ErrorAction SilentlyContinue
    $rec = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $recPartNo
    Write-Log '  removed auto-assigned drive letter'
}
Write-Log ("  partition {0}: offset {1}, size {2} GB, type {3}" -f $recPartNo, $rec.Offset, (Format-GB $rec.Size), $rec.GptType)

# ---- 3. place the image on the new partition -----------------------------

$letter = Get-FreeDriveLetter
if (-not $letter) { Write-Log 'No free drive letter available.' 'FATAL'; exit 6 }
Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $recPartNo -AccessPath "${letter}:\" -ErrorAction Stop
Start-Sleep -Seconds 1
try {
    $targetDir = "${letter}:\Recovery\WindowsRE"
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    Copy-Item -LiteralPath $wimPath -Destination (Join-Path $targetDir 'winre.wim') -Force
    foreach ($extra in @('boot.sdi', 'SrSettings.ini', 'ReAgent.xml')) {
        $src = Join-Path $BackupDir $extra
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $targetDir $extra) -Force -ErrorAction SilentlyContinue
        }
    }
    $copied = Get-FileSizeBytes (Join-Path $targetDir 'winre.wim')
    Write-Log ("  copied winre.wim to ${letter}: ({0} bytes)" -f $copied)
    if ($copied -ne $wimSize) {
        Write-Log '  copy size mismatch!' 'FATAL'
        exit 7
    }
} finally {
    Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $recPartNo -AccessPath "${letter}:\" -ErrorAction SilentlyContinue
    Write-Log "  unmounted ${letter}:."
}

# ---- 4. disable WinRE and remove the C: copy ------------------------------

Write-Log ("reagentc /disable -> " + (Invoke-Native 'reagentc /disable'))

$cCopy = Join-Path $env:SystemDrive 'Recovery\WindowsRE'
if (Test-Path -LiteralPath $cCopy) {
    Write-Log "Removing $cCopy (restricted ACL - taking ownership first)"
    cmd /c "takeown /f `"$cCopy`" /r /d y" 2>&1 | Out-Null
    cmd /c "icacls `"$cCopy`" /grant *S-1-5-32-544:(OI)(CI)F /t /q" 2>&1 | Out-Null
    Remove-Item -LiteralPath $cCopy -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $cCopy) { cmd /c "rd /s /q `"$cCopy`"" 2>&1 | Out-Null }
}
Write-Log ("  C:\Recovery\WindowsRE still present: " + (Test-Path -LiteralPath $cCopy))

# ---- 5. point ReAgent.xml at the new partition ---------------------------

try {
    [xml]$x = Get-Content -LiteralPath $reAgentPath
    $loc = $x.WindowsRE.WinreLocation
    $loc.path   = '\Recovery\WindowsRE'
    $loc.id     = '0'
    $loc.offset = "$($rec.Offset)"
    $loc.guid   = "$($rec.Guid)"
    $x.WindowsRE.WinreBCD.id = $winreBcdId
    $x.WindowsRE.InstallState.state = '1'
    $x.Save($reAgentPath)
    Write-Log "ReAgent.xml patched: offset=$($rec.Offset) guid=$($rec.Guid)"
} catch {
    Write-Log "Could not patch ReAgent.xml: $($_.Exception.Message)" 'WARN'
}

# ---- 6. enable WinRE and verify ------------------------------------------

Write-Log ("reagentc /enable -> " + (Invoke-Native 'reagentc /enable'))
$info = Invoke-Native 'reagentc /info'
Write-Log "reagentc /info -> $info"

$onRecPart = $info -match ("harddisk0\\partition{0}\\" -f $recPartNo)
$enabled   = $info -match 'Enabled'

if ($enabled -and $onRecPart) {
    Write-Log "SUCCESS: WinRE is enabled on partition $recPartNo." 'OK'
} else {
    Write-Log "WinRE is not on partition $recPartNo (enabled=$enabled, onRecPart=$onRecPart)." 'WARN'
    Write-Log 'Falling back to hosting WinRE on C:. It works, but the OS partition' 'WARN'
    Write-Log 'is then a single point of failure. The empty recovery partition can' 'WARN'
    Write-Log 'be deleted afterwards to reclaim the space.' 'WARN'
    New-Item -ItemType Directory -Path $cCopy -Force | Out-Null
    Copy-Item -LiteralPath $wimPath -Destination (Join-Path $cCopy 'winre.wim') -Force
    Write-Log ("reagentc /enable -> " + (Invoke-Native 'reagentc /enable'))
    Write-Log ("reagentc /info -> " + (Invoke-Native 'reagentc /info'))
}

# ---- 7. report ------------------------------------------------------------

Write-Log '--- resulting layout ---'
foreach ($p in (Get-Partition -DiskNumber $DiskNumber | Sort-Object PartitionNumber)) {
    $l = if ($p.DriveLetter) { "$($p.DriveLetter):" } else { '(none)' }
    Write-Log ("  Part{0}  {1,-8} {2,-9} {3,9} GB  {4}" -f $p.PartitionNumber, $l, $p.Type, (Format-GB $p.Size), $p.GptType)
}
$cVol = Get-Volume -DriveLetter C
Write-Log ("C:: {0} GB total, {1} GB free" -f (Format-GB $cVol.Size), (Format-GB $cVol.SizeRemaining))
Write-Log 'Reboot once and confirm the recovery menu and "Reset this PC" work.'
