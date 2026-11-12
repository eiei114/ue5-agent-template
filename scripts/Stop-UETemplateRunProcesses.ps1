# Stops only the processes that the run's own snapshot attributes to that run.
#
# AGENTS.md forbids name-targeted kills (Stop-Process -Name, taskkill /IM, Get-Process <name> |
# Stop-Process). This script never resolves a process by name: every target is an exact
# (process_id, creation_utc_ticks) pair recorded in the run's snapshot, and a PID whose creation
# time no longer matches is left alone (PID reuse = somebody else's process).
#
#   # 1. dry run: prints and writes the target list, stops nothing
#   scripts\Stop-UETemplateRunProcesses.ps1 -SnapshotPath <snapshot.json> -ReportPath <plan.json>
#
#   # 2. stop the listed targets, then verify the run-owned set is empty
#   scripts\Stop-UETemplateRunProcesses.ps1 -SnapshotPath <snapshot.json> -ReportPath <plan.json> `
#     -Execute -VerificationPath <verification.json>
#
# -Execute refuses unless the dry run for this exact snapshot already produced the plan, so a
# target list always exists before anything is stopped.
#
# Processes that cannot be attributed (`gaps`) are never stopped. While a gap exists the verdict is
# `unknown`, never `free`. The script never starts or attaches to UE.
#
# Exit codes: free = 0, held = 1, unknown = 2. A check that cannot complete also answers `unknown`
# (2) instead of letting a PowerShell exception exit 1, which a caller would read as `held`.

[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)]
	[string]$SnapshotPath,

	[Parameter(Mandatory = $true)]
	[string]$ReportPath,

	[string]$VerificationPath = '',

	[string]$ExecutionReportPath = '',

	[string]$OtherSnapshotPath = '',

	[string[]]$PreserveProcessNames = @('chrome'),

	[int]$GraceMilliseconds = 3000,

	[switch]$Execute
)

$ErrorActionPreference = 'Stop'

# Exit code 1 means `held` (run-owned processes survived the stop). A script exception also exits 1,
# so a caller would read a failed check as "the run is held". Failures therefore answer `unknown`
# (2) explicitly. The detail goes to stderr; the verdict stays on stdout.
trap {
	$message = $_.Exception.Message
	[Console]::Error.WriteLine(('ERROR: ' + $message))
	Write-Output 'VERDICT: unknown'
	Write-Output ('REASON: the check could not complete: ' + $message)
	Write-Output 'UE: not started (the stop script never launches UE)'
	exit 2
}

. (Join-Path $PSScriptRoot 'UETemplateProcessOwnership.ps1')

$snapshotPathFull = [System.IO.Path]::GetFullPath($SnapshotPath)
$reportPathFull = [System.IO.Path]::GetFullPath($ReportPath)
$snapshot = Read-UETemplateJsonFile -Path $snapshotPathFull -Description 'process snapshot'
$snapshotSha = (Get-UETemplateFileSha256 -Path $snapshotPathFull)

$otherSnapshots = @()
if (-not [string]::IsNullOrWhiteSpace($OtherSnapshotPath)) {
	foreach ($path in @($OtherSnapshotPath -split ';' | Where-Object { $_.Trim() })) {
		$otherSnapshots += Read-UETemplateJsonFile -Path ([System.IO.Path]::GetFullPath($path.Trim())) -Description 'other run snapshot'
	}
}

$liveTable = Get-UETemplateLiveProcessTable
$ownership = Resolve-UETemplateRunOwnership -Snapshots @($snapshot) -LiveTable $liveTable -PreserveProcessNames $PreserveProcessNames -OtherSnapshots $otherSnapshots
$plan = Get-UETemplateStopPlan -Ownership $ownership -LiveTable $liveTable -PreserveProcessNames $PreserveProcessNames

function New-PlanRecord([string]$PlanMode) {
	[pscustomobject]@{
		schema_version   = 1
		generated_at_utc = [datetime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
		mode             = $PlanMode
		run_id           = [string]$snapshot.run_id
		snapshot_path    = $snapshotPathFull
		snapshot_sha256  = $snapshotSha
		writer           = $snapshot.writer
		owned_count      = @($ownership.owned).Count
		excluded_count   = @($ownership.excluded).Count
		gap_count        = @($ownership.gaps).Count
		stop_targets     = @($plan.targets | ForEach-Object {
			[pscustomobject]@{
				process_id         = [int]$_.process_id
				parent_process_id  = [int]$_.parent_process_id
				name               = [string]$_.name
				executable_path    = [string]$_.executable_path
				creation_utc_ticks = [long]$_.creation_utc_ticks
				depth              = [int]$_.depth
			}
		})
		already_exited   = @($plan.skipped | Where-Object { $_.reason -eq 'already-exited' } | ForEach-Object {
			[pscustomobject]@{ process_id = [int]$_.process_id; name = [string]$_.name; reason = [string]$_.reason }
		})
		not_stopped      = @($plan.skipped | Where-Object { $_.reason -ne 'already-exited' } | ForEach-Object {
			[pscustomobject]@{ process_id = [int]$_.process_id; name = [string]$_.name; reason = [string]$_.reason }
		})
		excluded         = @($ownership.excluded)
		gaps             = @($ownership.gaps)
		preserved_process_names = @($PreserveProcessNames)
		other_runs       = @($otherSnapshots | ForEach-Object { [string]$_.run_id })
		ue_started       = $false
	}
}

function Write-TargetListing($PlanRecord, [string]$Heading) {
	Write-Output ("--- {0} ---" -f $Heading)
	foreach ($target in @($PlanRecord.stop_targets)) {
		Write-Output ("TARGET: pid={0} creation_utc_ticks={1} name={2} depth={3}" -f $target.process_id, $target.creation_utc_ticks, $target.name, $target.depth)
	}
	foreach ($skip in @($PlanRecord.not_stopped)) {
		Write-Output ("SKIP: pid={0} name={1} reason={2}" -f $skip.process_id, $skip.name, $skip.reason)
	}
	foreach ($exclude in @($PlanRecord.excluded)) {
		Write-Output ("EXCLUDE: pid={0} name={1} reason={2}" -f $exclude.process_id, $exclude.name, $exclude.reason)
	}
	foreach ($gap in @($PlanRecord.gaps)) {
		Write-Output ("GAP: pid={0} name={1} reason={2}" -f $gap.process_id, $gap.name, $gap.reason)
	}
	Write-Output ("TARGETS: {0}" -f @($PlanRecord.stop_targets).Count)
	Write-Output ("EXCLUDED: {0}" -f @($PlanRecord.excluded).Count)
	Write-Output ("GAPS: {0}" -f @($PlanRecord.gaps).Count)
}

if (-not $Execute) {
	$dryRun = New-PlanRecord 'dry-run'
	# Written before printing so the list survives even if the console is lost.
	Write-UETemplateJsonFile -Path $reportPathFull -Value $dryRun
	Write-TargetListing $dryRun 'stop targets (dry run: nothing was stopped)'
	Write-Output ("PLAN: {0}" -f $reportPathFull)
	Write-Output 'UE: not started (the stop script never launches UE)'
	if (-not $ownership.ok) {
		Write-Output 'VERDICT: unknown'
		if ($ownership.snapshotMissing) {
			Write-Output 'REASON: the snapshot has no process table; a single writer PID cannot attribute descendants'
		} else {
			Write-Output 'REASON: the snapshot exists but ownership could not be resolved'
		}
		exit 2
	}
	if (@($dryRun.gaps).Count -gt 0) {
		Write-Output 'VERDICT: unknown'
		Write-Output 'REASON: attribution gaps remain; they are reported and never stopped'
		exit 2
	}
	Write-Output 'VERDICT: ready'
	Write-Output 'REASON: dry run completed; run again with -Execute to stop the listed targets'
	exit 0
}

# -Execute: require a dry-run plan for this exact snapshot, then stop what it listed.
if (-not (Test-Path -LiteralPath $reportPathFull -PathType Leaf)) {
	throw ('Refusing to stop processes: no dry-run listing exists at {0}. Run the script once without -Execute so the target list is printed and written before anything is stopped.' -f $reportPathFull)
}
$prior = Read-UETemplateJsonFile -Path $reportPathFull -Description 'dry-run plan'
if ([string]$prior.snapshot_sha256 -cne $snapshotSha) {
	throw ('Refusing to stop processes: the dry-run plan at {0} was made from snapshot {1}, not {2}.' -f $reportPathFull, ([string]$prior.snapshot_sha256), $snapshotSha)
}
if (([string]$prior.mode) -cne 'dry-run') {
	throw ('Refusing to stop processes: {0} is not a dry-run plan (mode={1}).' -f $reportPathFull, ([string]$prior.mode))
}
if (-not $ownership.ok) {
	throw ('Refusing to stop processes: the snapshot does not attribute processes to this run ({0}).' -f $(if ($ownership.snapshotMissing) { 'snapshotMissing' } else { 'not-ok' }))
}

$execution = New-PlanRecord 'execute'
$execution | Add-Member -NotePropertyName 'plan_path' -NotePropertyValue $reportPathFull
if ([string]::IsNullOrWhiteSpace($ExecutionReportPath)) {
	$base = $reportPathFull
	if ($base.EndsWith('.json', [System.StringComparison]::OrdinalIgnoreCase)) { $base = $base.Substring(0, $base.Length - 5) }
	$ExecutionReportPath = $base + '-execute.json'
}
$executionPathFull = [System.IO.Path]::GetFullPath($ExecutionReportPath)
if (Test-Path -LiteralPath $executionPathFull) {
	throw ('Refusing to stop processes: execution report already exists: {0}' -f $executionPathFull)
}
# The listing is written and flushed before the first stop so a crash still leaves the target list.
Write-UETemplateJsonFile -Path $executionPathFull -Value $execution -Exclusive
Write-TargetListing $execution 'stop targets (execute)'
Write-Output '--- stopping ---'

$results = New-Object 'System.Collections.Generic.List[psobject]'
foreach ($target in @($execution.stop_targets)) {
	$results.Add((Stop-UETemplateProcessByIdentity -PlanEntry $target -GraceMilliseconds $GraceMilliseconds))
}

$liveAfter = Get-UETemplateLiveProcessTable
$ownershipAfter = Resolve-UETemplateRunOwnership -Snapshots @($snapshot) -LiveTable $liveAfter -PreserveProcessNames $PreserveProcessNames -OtherSnapshots $otherSnapshots
$residual = @(Get-UETemplateResidualProcesses -Ownership $ownershipAfter -LiveTable $liveAfter -PreserveProcessNames $PreserveProcessNames)
$gapCount = @($ownershipAfter.gaps).Count

$verdict = 'free'
$reason = 'the run-owned process set is empty and no attribution gap remains'
if ($gapCount -gt 0) {
	$verdict = 'unknown'
	$reason = 'attribution gaps remain: some live processes could not be tied to, or cleared from, this run'
} elseif ($residual.Count -gt 0) {
	$verdict = 'held'
	$reason = 'run-owned processes are still alive after the stop'
}
$stoppedCount = @($results | Where-Object { $_.stopped }).Count

$verification = [pscustomobject]@{
	schema_version        = 1
	generated_at_utc      = [datetime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
	run_id                = [string]$snapshot.run_id
	snapshot_sha256       = $snapshotSha
	plan_path             = $reportPathFull
	execution_report_path = $executionPathFull
	target_count          = @($execution.stop_targets).Count
	stopped_count         = $stoppedCount
	residual_count        = $residual.Count
	gap_count             = $gapCount
	excluded_count        = @($ownershipAfter.excluded).Count
	results               = @($results)
	residual              = $residual
	gaps                  = @($ownershipAfter.gaps)
	verdict               = $verdict
	reason                = $reason
	ue_started            = $false
}
if (-not [string]::IsNullOrWhiteSpace($VerificationPath)) {
	Write-UETemplateJsonFile -Path ([System.IO.Path]::GetFullPath($VerificationPath)) -Value $verification
}

Write-Output ("STOPPED: {0}/{1}" -f $stoppedCount, @($execution.stop_targets).Count)
Write-Output ("RESIDUAL: {0}" -f $residual.Count)
Write-Output ("GAPS: {0}" -f $gapCount)
Write-Output 'UE: not started (the stop script never launches UE)'
Write-Output ("VERDICT: {0}" -f $verdict)
Write-Output ("REASON: {0}" -f $reason)
if ($verdict -eq 'free') { exit 0 }
if ($verdict -eq 'held') { exit 1 }
exit 2
