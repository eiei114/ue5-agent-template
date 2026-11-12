# Read-only lease verdict: free / held / unknown.
#
# docs/01-start.md requires the lease to carry process attribution evidence. A lease whose writer
# PID is dead is NOT proof that the run's descendants are gone (scout measurement M3/M4 in
# DOT-3225: the writer died while Editor and ShaderCompileWorker kept a project handle, and a
# "free" lease then blocked the next run). This check therefore returns three values:
#
#   free    - the snapshot is verified and no run-owned process is alive
#   held    - at least one run-owned process (snapshot identity) is still alive
#   unknown - attribution cannot be established: no snapshot on the lease, snapshot file missing,
#             snapshot hash mismatch, writer PID/creation mismatch, or live processes that look run
#             owned but cannot be tied to it
#
# `unknown` is never folded into `free`, and a dead writer PID alone never yields `free`.
#
#   scripts\Test-UETemplateLease.ps1 -LeasePath <project>\LEASE.json
#   scripts\Test-UETemplateLease.ps1 -LeasePath <project>\LEASE.json -ReportPath <evidence>\lease-check.json
#
# Exit codes: free = 0, held = 1, unknown = 2. The script reads the process table and the lease
# only; it never starts, stops or writes to a UE process, and it never edits the lease.

[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)]
	[string]$LeasePath,

	[string]$SnapshotPath = '',

	[string]$ReportPath = '',

	[string]$OtherLeasePath = '',

	[string[]]$PreserveProcessNames = @('chrome'),

	[switch]$Quiet
)

$ErrorActionPreference = 'Stop'

# A check that cannot finish must answer `unknown` (exit 2). A PowerShell exception exits 1, and a
# caller would read 1 as `held`. The error text goes to stderr; the verdict stays on stdout so the
# output remains parseable and reportable.
trap {
	$message = $_.Exception.Message
	[Console]::Error.WriteLine(('ERROR: ' + $message))
	Write-Output 'VERDICT: unknown'
	Write-Output ('REASON: the check could not complete: ' + $message)
	Write-Output 'UE: not started (lease check only reads the process table and the lease)'
	try {
		if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
			Write-UETemplateJsonFile -Path ([System.IO.Path]::GetFullPath($ReportPath)) -Value ([pscustomobject]@{
				schema_version = 1
				checked_at_utc = [datetime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
				lease_path     = [string]$LeasePath
				verdict        = 'unknown'
				reason         = ('the check could not complete: ' + $message)
				problem        = 'check-failed'
				ue_started     = $false
			})
		}
	} catch {
	}
	exit 2
}

. (Join-Path $PSScriptRoot 'UETemplateProcessOwnership.ps1')

$leasePathFull = [System.IO.Path]::GetFullPath($LeasePath)
$lease = Read-UETemplateJsonFile -Path $leasePathFull -Description 'lease'
$leaseSha = (Get-UETemplateFileSha256 -Path $leasePathFull)

$problems = New-Object 'System.Collections.Generic.List[psobject]'
$writerPid = [int]0
if ($null -ne $lease.writer_pid) { $writerPid = [int]$lease.writer_pid }
$runId = ''
if ($null -ne $lease.run_id) { $runId = [string]$lease.run_id }
if ($writerPid -le 0) {
	$problems.Add([pscustomobject]@{ reason = 'lease-writer-pid-missing'; detail = 'the lease has no writer_pid, so no process can be attributed to it' })
}

$snapshotReference = $null
if ($null -ne $lease.process_snapshot) { $snapshotReference = $lease.process_snapshot }

$snapshotFilePath = ''
$snapshot = $null
if (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) {
	$snapshotFilePath = [System.IO.Path]::GetFullPath($SnapshotPath)
} elseif ($null -ne $snapshotReference -and -not [string]::IsNullOrWhiteSpace([string]$snapshotReference.path)) {
	# A relative path in the lease is resolved against the lease's own directory, not the cwd.
	$rawPath = [string]$snapshotReference.path
	if ([System.IO.Path]::IsPathRooted($rawPath)) {
		$snapshotFilePath = [System.IO.Path]::GetFullPath($rawPath)
	} else {
		$snapshotFilePath = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $leasePathFull) $rawPath))
	}
}

if ([string]::IsNullOrWhiteSpace($snapshotFilePath)) {
	$problems.Add([pscustomobject]@{ reason = 'snapshot-not-recorded'; detail = 'the lease records no process snapshot; a single writer PID cannot attribute descendants' })
} elseif (-not (Test-Path -LiteralPath $snapshotFilePath -PathType Leaf)) {
	$problems.Add([pscustomobject]@{ reason = 'snapshot-file-missing'; detail = ('the recorded snapshot does not exist: ' + $snapshotFilePath) })
} else {
	try {
		$snapshot = Read-UETemplateJsonFile -Path $snapshotFilePath -Description 'process snapshot'
	} catch {
		$problems.Add([pscustomobject]@{ reason = 'snapshot-unreadable'; detail = $_.Exception.Message })
	}
	if ($null -ne $snapshot) {
		$snapshotSha = (Get-UETemplateFileSha256 -Path $snapshotFilePath)
		if ($null -ne $snapshotReference -and -not [string]::IsNullOrWhiteSpace([string]$snapshotReference.sha256)) {
			if ([string]$snapshotReference.sha256 -cne $snapshotSha) {
				$problems.Add([pscustomobject]@{ reason = 'snapshot-hash-mismatch'; detail = ('lease records {0}, the file is {1}' -f [string]$snapshotReference.sha256, $snapshotSha) })
			}
		}
		if ($null -ne $snapshot.writer) {
			$snapshotWriterId = [int]$snapshot.writer.process_id
			$snapshotWriterTicks = [long]$snapshot.writer.creation_utc_ticks
			if ($writerPid -gt 0 -and $snapshotWriterId -ne $writerPid) {
				$problems.Add([pscustomobject]@{ reason = 'snapshot-writer-mismatch'; detail = ('lease writer_pid {0} but snapshot writer {1}' -f $writerPid, $snapshotWriterId) })
			}
			if ($snapshotWriterTicks -le 0) {
				$problems.Add([pscustomobject]@{ reason = 'snapshot-writer-creation-unknown'; detail = 'the snapshot has no writer creation time, so PID reuse cannot be excluded' })
			}
		} else {
			$problems.Add([pscustomobject]@{ reason = 'snapshot-writer-missing'; detail = 'the snapshot has no writer record' })
		}
		if ($null -ne $snapshot.run_id -and $runId -ne '' -and [string]$snapshot.run_id -cne $runId) {
			$problems.Add([pscustomobject]@{ reason = 'snapshot-run-mismatch'; detail = ('lease run_id {0} but snapshot run_id {1}' -f $runId, [string]$snapshot.run_id) })
		}
	}
}

$liveTable = $null
$liveTableError = ''
try {
	$liveTable = Get-UETemplateLiveProcessTable
} catch {
	$liveTableError = $_.Exception.Message
	$problems.Add([pscustomobject]@{ reason = 'process-table-unreadable'; detail = $liveTableError })
}

$otherSnapshots = @()
if (-not [string]::IsNullOrWhiteSpace($OtherLeasePath)) {
	foreach ($path in @($OtherLeasePath -split ';' | Where-Object { $_.Trim() })) {
		$otherLease = Read-UETemplateJsonFile -Path ([System.IO.Path]::GetFullPath($path.Trim())) -Description 'other lease'
		if ($null -ne $otherLease.process_snapshot -and -not [string]::IsNullOrWhiteSpace([string]$otherLease.process_snapshot.path)) {
			$otherSnapshotPath = [string]$otherLease.process_snapshot.path
			if (-not [System.IO.Path]::IsPathRooted($otherSnapshotPath)) {
				$otherSnapshotPath = Join-Path (Split-Path -Parent ([System.IO.Path]::GetFullPath($path.Trim()))) $otherSnapshotPath
			}
			if (Test-Path -LiteralPath $otherSnapshotPath -PathType Leaf) {
				try {
					$otherSnapshots += Read-UETemplateJsonFile -Path $otherSnapshotPath -Description 'other run snapshot'
				} catch {
					$problems.Add([pscustomobject]@{ reason = 'other-snapshot-unreadable'; detail = $_.Exception.Message })
				}
			} else {
				$problems.Add([pscustomobject]@{ reason = 'other-snapshot-missing'; detail = $otherSnapshotPath })
			}
		}
	}
}

$ownership = $null
if ($null -ne $snapshot -and $null -ne $liveTable) {
	$ownership = Resolve-UETemplateRunOwnership -Snapshots @($snapshot) -LiveTable $liveTable -PreserveProcessNames $PreserveProcessNames -OtherSnapshots $otherSnapshots
	foreach ($gap in @($ownership.gaps)) {
		$problems.Add([pscustomobject]@{ reason = 'attribution-gap'; detail = ('pid {0} ({1}): {2}' -f [int]$gap.process_id, [string]$gap.name, [string]$gap.reason) })
	}
}

$liveOwned = @()
if ($null -ne $ownership -and $ownership.ok -and $null -ne $liveTable) {
	$liveOwned = @($ownership.owned | Where-Object { $_.live })
}

# writer_alive must not be a PID-existence answer. A live PID whose creation time no longer matches
# the snapshot is a reused PID, i.e. somebody else's process, so it cannot be reported as this run's
# writer. When the snapshot carries no writer creation time the identity cannot be checked at all,
# which is already recorded as an `unknown` problem above.
$writerPresent = $false
$writerAlive = $false
$writerIdentityVerified = $false
if ($writerPid -gt 0 -and $null -ne $liveTable) {
	$liveIndex = Get-UETemplateProcessIndex -Table @(ConvertTo-UETemplateProcessTable -Records $liveTable)
	$liveWriter = $liveIndex.byId[$writerPid]
	$writerPresent = ($null -ne $liveWriter)
	if ($writerPresent -and $null -ne $snapshot -and $null -ne $snapshot.writer) {
		$expectedWriterTicks = [long]$snapshot.writer.creation_utc_ticks
		if ($expectedWriterTicks -gt 0) {
			$writerIdentityVerified = Test-UETemplateProcessIdentity -ExpectedRecord ([pscustomobject]@{ process_id = $writerPid; creation_utc_ticks = $expectedWriterTicks }) -LiveRecord $liveWriter
		}
	}
	$writerAlive = $writerIdentityVerified
}

$verdict = 'free'
$reason = 'no run-owned process is alive and the snapshot verifies the attribution'
if ($problems.Count -gt 0) {
	$verdict = 'unknown'
	$reason = 'attribution cannot be established: ' + (@($problems | ForEach-Object { $_.reason }) -join ', ')
} elseif ($liveOwned.Count -gt 0) {
	$verdict = 'held'
	$reason = ('{0} run-owned process(es) are still alive' -f $liveOwned.Count)
}

$record = [pscustomobject]@{
	schema_version        = 1
	checked_at_utc        = [datetime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
	lease_path            = $leasePathFull
	lease_sha256          = $leaseSha
	run_id                = $runId
	writer_pid            = $writerPid
	writer_alive          = $writerAlive
	writer_pid_present    = $writerPresent
	writer_identity_verified = $writerIdentityVerified
	snapshot_path         = $snapshotFilePath
	snapshot_present      = ($null -ne $snapshot)
	snapshot_verified     = ($problems.Count -eq 0 -and $null -ne $snapshot)
	owned_live_count      = $liveOwned.Count
	owned_live            = @($liveOwned | ForEach-Object { [pscustomobject]@{ process_id = [int]$_.process_id; name = [string]$_.name; executable_path = [string]$_.executable_path } })
	excluded_count        = $(if ($null -ne $ownership) { @($ownership.excluded).Count } else { 0 })
	gap_count             = $(if ($null -ne $ownership) { @($ownership.gaps).Count } else { 0 })
	problems              = @($problems)
	verdict               = $verdict
	reason                = $reason
	preserved_process_names = @($PreserveProcessNames)
	ue_started            = $false
}

if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
	Write-UETemplateJsonFile -Path ([System.IO.Path]::GetFullPath($ReportPath)) -Value $record
}

if (-not $Quiet) {
	Write-Output ("VERDICT: {0}" -f $verdict)
	Write-Output ("REASON: {0}" -f $reason)
	Write-Output ("WRITER: pid={0} alive={1} pid-present={2} identity-verified={3} (a live PID with a different creation time is a reused PID, not this run's writer)" -f $writerPid, $writerAlive, $writerPresent, $writerIdentityVerified)
	Write-Output ("SNAPSHOT: present={0} verified={1} path={2}" -f $record.snapshot_present, $record.snapshot_verified, $(if ($snapshotFilePath) { $snapshotFilePath } else { '(none)' }))
	Write-Output ("OWNED-LIVE: {0}" -f $liveOwned.Count)
	foreach ($liveProcess in @($liveOwned)) {
		Write-Output ("  LIVE: pid={0} name={1}" -f $liveProcess.process_id, $liveProcess.name)
	}
	foreach ($problem in @($problems)) {
		Write-Output ("PROBLEM: {0} - {1}" -f $problem.reason, $problem.detail)
	}
	if (-not [string]::IsNullOrWhiteSpace($ReportPath)) { Write-Output ("REPORT: {0}" -f ([System.IO.Path]::GetFullPath($ReportPath))) }
	Write-Output 'UE: not started (lease check only reads the process table and the lease)'
}

if ($verdict -eq 'free') { exit 0 }
if ($verdict -eq 'held') { exit 1 }
exit 2
