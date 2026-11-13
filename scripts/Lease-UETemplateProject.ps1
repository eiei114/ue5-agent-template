[CmdletBinding()]
param(
	# Acquire takes the lease, Release hands it back, Test only reads it.
	[Parameter(Mandatory = $true)]
	[ValidateSet('Acquire', 'Release', 'Test')]
	[string]$Action,

	# Directory that owns the lease record. The record is always <dir>\LEASE.json, so the same
	# script serves the generated project directory and a run ledger directory outside it.
	[Parameter(Mandatory = $true)]
	[string]$ProjectDirectory,

	[string]$RunId = '',

	[string]$IssueId = '',

	# 32 hex characters by default. Supply the value you recorded to Release it again.
	[string]$Nonce = '',

	[string]$WriterPhase = '',

	[ValidateRange(1, 2147483647)]
	[int]$WriterProcessId = $PID,

	[string]$HostName = '',

	# The lease directory must stay inside this root. Defaults to this checkout's Production/.
	[string]$ProductionRoot = ''
)

$ErrorActionPreference = 'Stop'

# The record contract (docs/01-start.md, "leaseプロトコル"): exactly these fields, in this order,
# plus the optional attribution reference `process_snapshot` that DOT-3225 appends after the run
# started. Acquire still writes the 8 required fields only, so a fresh record stays byte-comparable.
$leaseFileName = 'LEASE.json'
$leaseFields = @('run_id', 'issue_id', 'host', 'project_realpath', 'acquired_utc', 'nonce', 'writer_phase', 'pid')
$optionalLeaseFields = @('process_snapshot')
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Get-FullPath([string]$Path, [string]$Label) {
	$resolved = [System.IO.Path]::GetFullPath($Path)
	if ([string]::IsNullOrWhiteSpace($resolved)) { throw "Could not resolve the $Label path." }
	return $resolved.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

function Assert-RunId([string]$Value, [string]$ActionName) {
	if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') {
		throw "$ActionName needs a run ID that is letters, digits, '-' or '_' and does not start with punctuation."
	}
}

function Assert-Nonce([string]$Value) {
	if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{15,63}$') {
		throw 'The nonce must be 16 to 64 characters of letters, digits, "-" or "_".'
	}
}

function New-ExclusiveDirectory([string]$Path) {
	# Same primitive as scripts/New-UETemplateScaffold.ps1: Win32 CreateDirectoryW fails with
	# ERROR_ALREADY_EXISTS (183) instead of silently reusing an existing directory. A directory
	# that already exists is reported, not treated as an error: creating a directory and taking
	# a lease are separate operations, so an already generated project can still be leased.
	if (-not ('MulticaLeaseDirectory' -as [type])) {
		Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class MulticaLeaseDirectory {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CreateDirectory(string path, IntPtr securityAttributes);
}
'@
	}
	if ([MulticaLeaseDirectory]::CreateDirectory($Path, [IntPtr]::Zero)) { return $false }
	$win32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
	if ($win32Error -eq 183) { return $true }
	throw "Could not create the lease directory exclusively (Win32 $win32Error): $Path"
}

function Read-LeaseRecord([string]$Path) {
	# Reads only. The file is never opened for writing here, so Test cannot mutate a lease.
	$text = [System.IO.File]::ReadAllText($Path)
	if ([string]::IsNullOrWhiteSpace($text)) { throw "The lease record is empty: $Path" }
	$record = $text | ConvertFrom-Json
	foreach ($field in $leaseFields) {
		if ($null -eq $record.PSObject.Properties[$field]) {
			throw "The lease record is missing the '$field' field: $Path"
		}
	}
	$extraFields = @($record.PSObject.Properties | Where-Object { ($leaseFields -notcontains $_.Name) -and ($optionalLeaseFields -notcontains $_.Name) } | ForEach-Object { $_.Name })
	if ($extraFields.Count -gt 0) {
		throw ("The lease record has fields that docs/01-start.md does not define ({0}): update the doc contract together with the script: {1}" -f ($extraFields -join ', '), $Path)
	}
	# process_snapshot is optional (a lease taken before the run captured its process table has none),
	# but when it is present it must still point at a snapshot and carry its hash, otherwise the
	# attribution evidence the process-cleanup scripts rely on would be unusable.
	if ($null -ne $record.PSObject.Properties['process_snapshot']) {
		$snapshot = $record.process_snapshot
		if ($null -eq $snapshot -or [string]::IsNullOrWhiteSpace([string]$snapshot.path) -or [string]::IsNullOrWhiteSpace([string]$snapshot.sha256)) {
			throw "The lease record's process_snapshot needs a path and a sha256: $Path"
		}
	}
	foreach ($field in @('run_id', 'issue_id', 'host', 'project_realpath', 'acquired_utc', 'nonce', 'writer_phase')) {
		if ([string]::IsNullOrWhiteSpace([string]$record.$field)) { throw "The lease record has an empty '$field' field: $Path" }
	}
	$pidValue = 0
	if (-not [int]::TryParse([string]$record.pid, [ref]$pidValue) -or $pidValue -le 0) {
		throw "The lease record has no usable pid field: $Path"
	}
	return $record
}

function Write-ExclusiveRecord([string]$Path, [object]$Record, [string]$ConflictMessage) {
	# CreateNew + FileShare.None is the only write path: a second writer cannot open, append to,
	# replace or rename over a live record, and a losing writer leaves the winner's bytes alone.
	$json = ConvertTo-Json -InputObject $Record
	$bytes = $utf8NoBom.GetBytes($json + [Environment]::NewLine)
	try {
		$stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
	} catch [System.IO.IOException] {
		throw $ConflictMessage
	}
	try {
		$stream.Write($bytes, 0, $bytes.Length)
		$stream.Flush($true)
	} finally {
		$stream.Dispose()
	}
}

if ([string]::IsNullOrWhiteSpace($HostName)) { $HostName = [Environment]::MachineName }
$leaseDirectory = Get-FullPath $ProjectDirectory 'lease directory'
$productionRootPath = if ([string]::IsNullOrWhiteSpace($ProductionRoot)) {
	Get-FullPath (Join-Path $PSScriptRoot '..\Production') 'Production root'
} else {
	Get-FullPath $ProductionRoot 'Production root'
}
$separator = [System.IO.Path]::DirectorySeparatorChar
$productionPrefix = $productionRootPath + $separator
if (-not $leaseDirectory.StartsWith($productionPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
	throw "The lease directory escapes Production: $leaseDirectory"
}
$leasePath = Join-Path $leaseDirectory $leaseFileName

switch ($Action) {
	'Acquire' {
		Assert-RunId $RunId 'Acquire'
		if ([string]::IsNullOrWhiteSpace($Nonce)) { $Nonce = [Guid]::NewGuid().ToString('N') }
		Assert-Nonce $Nonce
		if ([string]::IsNullOrWhiteSpace($IssueId)) { throw 'Acquire needs the issue ID this run works on.' }
		if ([string]::IsNullOrWhiteSpace($WriterPhase)) { throw 'Acquire needs the writer phase this run is in.' }

		$directoryExisted = New-ExclusiveDirectory $leaseDirectory
		if (Test-Path -LiteralPath $leasePath -PathType Leaf) {
			throw "An active lease already exists; acquisition stopped without modifying it: $leasePath"
		}
		$record = [ordered]@{
			run_id           = $RunId
			issue_id         = $IssueId
			host             = $HostName
			project_realpath = $leaseDirectory
			acquired_utc     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
			nonce            = $Nonce
			writer_phase     = $WriterPhase
			pid              = $WriterProcessId
		}
		Write-ExclusiveRecord -Path $leasePath -Record $record -ConflictMessage "An active lease already exists; acquisition stopped without modifying it: $leasePath"
		Write-Output 'LEASE ACQUIRED'
		Write-Output ("directory_existed={0}" -f $directoryExisted)
		Write-Output ("run_id={0}" -f $RunId)
		Write-Output ("nonce={0}" -f $Nonce)
		Write-Output ("pid={0}" -f $WriterProcessId)
		Write-Output ("lease={0}" -f $leasePath)
		break
	}
	'Release' {
		Assert-RunId $RunId 'Release'
		Assert-Nonce $Nonce
		if (-not (Test-Path -LiteralPath $leasePath -PathType Leaf)) {
			throw "There is no lease record to release: $leasePath"
		}
		$record = Read-LeaseRecord $leasePath
		if ([string]$record.run_id -cne $RunId) {
			throw ("The lease belongs to another run; release stopped without deleting it: {0} (lease run_id={1}, requested run_id={2})" -f $leasePath, $record.run_id, $RunId)
		}
		if ([string]$record.nonce -cne $Nonce) {
			throw ("The lease nonce does not match this run; release stopped without deleting it: {0} (pass the nonce printed by Acquire)" -f $leasePath)
		}
		$releasePath = Join-Path $leaseDirectory ('LEASE_RELEASED.{0}.json' -f $RunId)
		$releaseRecord = [ordered]@{
			run_id           = [string]$record.run_id
			issue_id         = [string]$record.issue_id
			host             = [string]$record.host
			project_realpath = [string]$record.project_realpath
			acquired_utc     = [string]$record.acquired_utc
			nonce            = [string]$record.nonce
			writer_phase     = [string]$record.writer_phase
			pid              = [int]$record.pid
			released_utc     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
		}
		# The release receipt is created before the lease is removed, so a crash between the two
		# leaves a receipt and a lease instead of losing the record. An existing receipt means this
		# run already released: stop rather than overwrite evidence.
		Write-ExclusiveRecord -Path $releasePath -Record $releaseRecord -ConflictMessage ("A release receipt for this run already exists; release stopped without overwriting it: {0}" -f $releasePath)
		[System.IO.File]::Delete($leasePath)
		Write-Output 'LEASE RELEASED'
		Write-Output ("run_id={0}" -f $RunId)
		Write-Output ("receipt={0}" -f $releasePath)
		Write-Output ("lease={0}" -f $leasePath)
		break
	}
	'Test' {
		# Read-only by contract: no directory creation, no record write, no timestamp touch.
		$state = 'unknown'
		$reason = ''
		$owns = 'false'
		if (-not (Test-Path -LiteralPath $leasePath -PathType Leaf)) {
			$reason = 'no lease record in this directory'
		} else {
			try {
				$record = Read-LeaseRecord $leasePath
			} catch {
				$record = $null
				$reason = $_.Exception.Message
			}
			if ($null -ne $record) {
				if ($RunId -ne '' -or $Nonce -ne '') {
					$matchesRun = ($RunId -eq '') -or ([string]$record.run_id -ceq $RunId)
					$matchesNonce = ($Nonce -eq '') -or ([string]$record.nonce -ceq $Nonce)
					$owns = if ($matchesRun -and $matchesNonce) { 'true' } else { 'false' }
				}
				if ([string]$record.host -ne $HostName) {
					$reason = ("the lease host is '{0}', not this host '{1}'; process liveness cannot be checked from here" -f $record.host, $HostName)
				} else {
					$pidValue = [int]$record.pid
					try {
						Get-Process -Id $pidValue -ErrorAction Stop | Out-Null
						$state = 'active'
						$reason = ("pid {0} is running" -f $pidValue)
					} catch [Microsoft.PowerShell.Commands.ProcessCommandException] {
						# A leftover lease whose writer is gone still blocks Acquire. Free means no
						# live writer claimed it, not that the record may be overwritten.
						$state = 'free'
						$reason = ("pid {0} is not running; the leftover record still has to be released or reconciled by hand" -f $pidValue)
					} catch {
						$reason = $_.Exception.Message
					}
				}
			}
		}
		Write-Output ("LEASE STATE: {0}" -f $state)
		Write-Output ("reason={0}" -f $reason)
		Write-Output ("lease={0}" -f $leasePath)
		if ($state -eq 'unknown') {
			Write-Output 'owns=unknown'
			# 2 follows the render inspector: an unverifiable answer is not a pass and not a pass
			# that means "free".
			exit 2
		}
		Write-Output ("owns={0}" -f $owns)
		Write-Output ("run_id={0}" -f $record.run_id)
		Write-Output ("nonce={0}" -f $record.nonce)
		Write-Output ("pid={0}" -f $record.pid)
		if ($state -eq 'active') { exit 0 } else { exit 1 }
	}
}
