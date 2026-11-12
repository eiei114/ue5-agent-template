# Regression suite for run-owned process attribution (DOT-3225 / UE-PROCTREE-001).
#
# Every fixture is a self-made process tree; UE is never installed, started or compiled. The fixtures
# live in the system temp directory, so the checkout stays byte-identical.
#
# Required negative cases (issue completion conditions 3-6):
#   (a) writer -> child -> grandchild, lease records only the writer PID: the stop script lists and
#       stops the grandchild through the snapshot's parent chain
#   (b) a live process that no snapshot recorded is neither a target nor silently ignored
#   (c) a reused PID (creation time mismatch) is never stopped
#   (d) attribution that cannot be established answers `unknown`, never `free`
#   (e) the pre-change lease shape (single writer PID, no snapshot) cannot satisfy (a)
#
# Exit 0 only when every group passes; one PASS line per group is printed.

[CmdletBinding()]
param(
	[ValidateRange(30, 300)]
	[int]$FixtureTimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'
$script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:ownershipScript = Join-Path $PSScriptRoot 'UETemplateProcessOwnership.ps1'
$script:startScript = Join-Path $PSScriptRoot 'Start-UETemplateRunProcessSnapshot.ps1'
$script:stopScript = Join-Path $PSScriptRoot 'Stop-UETemplateRunProcesses.ps1'
$script:leaseScript = Join-Path $PSScriptRoot 'Test-UETemplateLease.ps1'
. $script:ownershipScript

$testId = [Guid]::NewGuid().ToString('N')
$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('.ue-proc-ownership-' + $testId)
$suiteError = $null
$spawnedProcessIds = New-Object 'System.Collections.Generic.List[int]'
$hostExe = (Get-Process -Id $PID).Path

function Assert-True([bool]$Condition, [string]$Message) {
	if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Write-FixtureFile([string]$Path, [string]$Text) {
	$parent = Split-Path -Parent $Path
	if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
	[System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Wait-Until([scriptblock]$Condition, [int]$TimeoutSeconds, [string]$FailureMessage) {
	$deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
	while ([datetime]::UtcNow -lt $deadline) {
		$value = & $Condition
		if ($null -ne $value -and $value -ne $false) { return $value }
		Start-Sleep -Milliseconds 200
	}
	throw ("ASSERT FAILED: timed out after {0}s: {1}" -f $TimeoutSeconds, $FailureMessage)
}

function Get-DescendantsOf([int]$RootProcessId) {
	$table = Get-UETemplateLiveProcessTable
	$index = Get-UETemplateProcessIndex -Table $table
	@(Get-UETemplateProcessDescendants -Index $index -RootProcessIds @($RootProcessId) | Where-Object { [int]$_.process_id -ne $RootProcessId })
}

function Get-LiveRecord([int]$ProcessId) {
	$live = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = {0}" -f $ProcessId) -ErrorAction SilentlyContinue
	if ($null -eq $live) { return $null }
	New-UETemplateProcessRecord -Source $live
}

function Start-ChainFixture {
	# writer -> child -> grandchild, each parent waiting on its child. The grandchild sleeps instead
	# of exiting so the tree stays observable; no external tool is invoked.
	$chainPath = Join-Path $fixtureRoot 'chain.ps1'
	if (-not (Test-Path -LiteralPath $chainPath)) {
		Write-FixtureFile $chainPath @'
param([int]$Depth = 0, [int]$LeafSeconds = 600)
$exe = (Get-Process -Id $PID).Path
if ($Depth -gt 0) {
	$child = Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-File', $PSCommandPath, '-Depth', ($Depth - 1), '-LeafSeconds', $LeafSeconds) -PassThru -WindowStyle Hidden
	$child.WaitForExit()
} else {
	Start-Sleep -Seconds $LeafSeconds
}
'@
	}
	$writer = Start-Process -FilePath $hostExe -ArgumentList @('-NoProfile', '-File', $chainPath, '-Depth', '2') -PassThru -WindowStyle Hidden
	$spawnedProcessIds.Add([int]$writer.Id)
	$writer
}

function Wait-ChainLeaf([int]$WriterId) {
	Wait-Until {
		$table = Get-UETemplateLiveProcessTable
		$index = Get-UETemplateProcessIndex -Table $table
		$descendants = @(Get-UETemplateProcessDescendants -Index $index -RootProcessIds @($WriterId) | Where-Object { [int]$_.process_id -ne $WriterId })
		$depths = Get-UETemplateProcessDepths -Index $index -RootProcessIds @($WriterId)
		$deep = @($descendants | Where-Object { $depths.ContainsKey([int]$_.process_id) -and [int]$depths[[int]$_.process_id] -ge 2 })
		if ($deep.Count -ge 1) { @($descendants) } else { $null }
	} $FixtureTimeoutSeconds 'the fixture tree did not produce a grandchild two levels below the writer'
}

function Invoke-ProcessScript([string]$ScriptPath, [string[]]$Arguments) {
	# System.Diagnostics is used directly because Windows PowerShell 5.1 leaves ExitCode empty when a
	# Start-Process -PassThru child is awaited with a timeout. Both output streams are drained
	# asynchronously so a chatty child cannot deadlock the pipe.
	$psi = New-Object System.Diagnostics.ProcessStartInfo
	$psi.FileName = $hostExe
	$quoted = @('-NoProfile', '-File', ('"' + $ScriptPath + '"')) + @($Arguments | ForEach-Object {
		if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
	})
	$psi.Arguments = ($quoted -join ' ')
	$psi.UseShellExecute = $false
	$psi.RedirectStandardOutput = $true
	$psi.RedirectStandardError = $true
	$psi.CreateNoWindow = $true
	$psi.WorkingDirectory = $script:repoRoot
	$process = New-Object System.Diagnostics.Process
	$process.StartInfo = $psi
	$null = $process.Start()
	$stdoutTask = $process.StandardOutput.ReadToEndAsync()
	$stderrTask = $process.StandardError.ReadToEndAsync()
	if (-not $process.WaitForExit(180000)) {
		try { $process.Kill() } catch { }
		throw ("ASSERT FAILED: script did not finish within 180s: {0} {1}" -f $ScriptPath, ($Arguments -join ' '))
	}
	$process.WaitForExit()
	[pscustomobject]@{ exit_code = [int]$process.ExitCode; stdout = [string]$stdoutTask.Result; stderr = [string]$stderrTask.Result }
}

function New-LeaseFile([string]$RunId, [int]$WriterPid, [string]$SnapshotPath) {
	$lease = [pscustomobject]@{
		run_id           = $RunId
		issue_id         = 'DOT-3225'
		host             = [System.Net.Dns]::GetHostName()
		project_realpath = (Join-Path $fixtureRoot ('Project_' + $RunId))
		acquired_at_utc  = [datetime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
		nonce            = $testId
		writer_phase     = 'active'
		writer_pid       = $WriterPid
	}
	if (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) {
		$lease | Add-Member -NotePropertyName 'process_snapshot' -NotePropertyValue ([pscustomobject]@{
			path   = $SnapshotPath
			sha256 = (Get-UETemplateFileSha256 -Path $SnapshotPath)
		})
	}
	$path = Join-Path $fixtureRoot ("LEASE_$RunId.json")
	Write-UETemplateJsonFile -Path $path -Value $lease
	$path
}

function Get-PlanTargetIds($Plan) { @($Plan.stop_targets | ForEach-Object { [int]$_.process_id }) }

function Stop-FixtureProcesses {
	# Only identities recorded in the suite's own snapshots are stopped, and only while their creation
	# time still matches, so a PID reused after the suite started is never touched.
	foreach ($file in @(Get-ChildItem -LiteralPath $fixtureRoot -Filter '*.json' -Recurse -ErrorAction SilentlyContinue)) {
		try { $snapshot = Read-UETemplateJsonFile -Path $file.FullName -Description 'fixture snapshot' } catch { continue }
		if ($null -eq $snapshot -or $null -eq $snapshot.processes -or $null -eq $snapshot.roots) { continue }
		$liveTable = Get-UETemplateLiveProcessTable
		$ownership = Resolve-UETemplateRunOwnership -Snapshots @($snapshot) -LiveTable $liveTable -PreserveProcessNames @()
		$plan = Get-UETemplateStopPlan -Ownership $ownership -LiveTable $liveTable -PreserveProcessNames @()
		foreach ($target in @($plan.targets)) {
			$null = Stop-UETemplateProcessByIdentity -PlanEntry $target -GraceMilliseconds 2000
		}
	}
}

$initialStatus = @(& git -C $script:repoRoot status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0) { throw 'Could not record the checkout status before testing.' }

try {
	[System.IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null

	# --- group 1: snapshot capture keeps writer_pid and adds the attribution evidence -------------
	$chain = Start-ChainFixture
	$writerId = [int]$chain.Id
	$tree = Wait-ChainLeaf -WriterId $writerId
	Assert-True (@($tree).Count -ge 3) 'the fixture tree has the writer plus at least a child and a grandchild'

	$runId = "run-$testId"
	$snapshotPath = Join-Path $fixtureRoot 'snapshot.json'
	$capture = Invoke-ProcessScript $script:startScript @(
		'-RunId', $runId, '-WriterProcessId', ([string]$writerId), '-SnapshotPath', $snapshotPath,
		'-ProjectRealPath', (Join-Path $fixtureRoot 'Project_run'), '-IssueId', 'DOT-3225'
	)
	Assert-True ($capture.exit_code -eq 0) ("snapshot capture exits 0, got {0}: {1}" -f $capture.exit_code, $capture.stderr)
	Assert-True (Test-Path -LiteralPath $snapshotPath -PathType Leaf) 'snapshot capture writes the snapshot'
	$snapshot = Read-UETemplateJsonFile -Path $snapshotPath -Description 'snapshot'
	Assert-True ([int]$snapshot.schema_version -eq 1) 'the snapshot records a schema version'
	Assert-True ([int]$snapshot.writer.process_id -eq $writerId) 'the snapshot records the writer PID'
	Assert-True ([long]$snapshot.writer.creation_utc_ticks -gt 0) 'the snapshot records the writer creation time'
	Assert-True (@($snapshot.roots) -contains $writerId) 'the snapshot records the writer as the run root'
	Assert-True (@($snapshot.boundary_ancestor_process_ids).Count -ge 1) 'the snapshot records the ancestry the run must not stop'
	Assert-True (-not (@($snapshot.boundary_ancestor_process_ids) -contains $writerId)) 'the writer is not recorded as its own boundary'
	Assert-True (@($snapshot.processes).Count -gt 0) 'the snapshot records the process table'
	$snapshotFields = @($snapshot.processes[0].PSObject.Properties.Name)
	foreach ($field in @('process_id', 'parent_process_id', 'creation_utc_ticks', 'executable_path')) {
		Assert-True ($snapshotFields -contains $field) ("snapshot process records carry {0}" -f $field)
	}
	$recordedWriter = @($snapshot.processes | Where-Object { [int]$_.process_id -eq $writerId })
	Assert-True ($recordedWriter.Count -eq 1) 'the writer appears once in the snapshot'
	Assert-True ([long]$recordedWriter[0].creation_utc_ticks -eq [long]$snapshot.writer.creation_utc_ticks) 'the writer record and the writer field agree on the creation time'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'snapshot.json.copy'))) 'capture does not scatter copies'

	$leasePath = New-LeaseFile $runId $writerId ''
	$leaseBefore = Read-UETemplateJsonFile -Path $leasePath -Description 'lease'
	$captureWithLease = Invoke-ProcessScript $script:startScript @(
		'-RunId', $runId, '-WriterProcessId', ([string]$writerId),
		'-SnapshotPath', (Join-Path $fixtureRoot 'snapshot-lease.json'), '-LeasePath', $leasePath
	)
	Assert-True ($captureWithLease.exit_code -eq 0) ("lease-attached capture exits 0, got {0}: {1}" -f $captureWithLease.exit_code, $captureWithLease.stderr)
	$leaseAfter = Read-UETemplateJsonFile -Path $leasePath -Description 'lease'
	Assert-True ($null -ne $leaseAfter.writer_pid -and [int]$leaseAfter.writer_pid -eq $writerId) 'the lease keeps writer_pid'
	foreach ($field in @('run_id', 'issue_id', 'host', 'project_realpath', 'acquired_at_utc', 'nonce', 'writer_phase')) {
		Assert-True ((ConvertTo-Json -InputObject @{ v = $leaseBefore.$field } -Depth 6 -Compress) -ceq (ConvertTo-Json -InputObject @{ v = $leaseAfter.$field } -Depth 6 -Compress)) ("recording the snapshot leaves lease field {0} unchanged" -f $field)
	}
	Assert-True ($null -ne $leaseAfter.process_snapshot) 'the lease gains a process_snapshot reference'
	Assert-True ([string]$leaseAfter.process_snapshot.path -eq (Join-Path $fixtureRoot 'snapshot-lease.json')) 'the snapshot reference points at the captured snapshot'
	Assert-True (([string]$leaseAfter.process_snapshot.sha256) -match '^[0-9A-Fa-f]{32,64}$') 'the snapshot reference carries its hash'
	Write-Output 'PASS: snapshot records writer/boundary/table; the lease keeps writer_pid and gains only a process_snapshot reference'

	# --- group 2: dry run lists the whole tree (a) ---------------------------------------------
	$planPath = Join-Path $fixtureRoot 'plan.json'
	$dryRun = Invoke-ProcessScript $script:stopScript @('-SnapshotPath', $snapshotPath, '-ReportPath', $planPath)
	Assert-True ($dryRun.exit_code -eq 0) ("the dry run exits 0 (ready), got {0}: {1}" -f $dryRun.exit_code, ($dryRun.stderr + $dryRun.stdout))
	Assert-True ($dryRun.stdout.Contains('TARGET:')) 'the dry run prints the stop targets'
	$plan = Read-UETemplateJsonFile -Path $planPath -Description 'plan'
	Assert-True (([string]$plan.mode) -ceq 'dry-run') 'the plan records that it is a dry run'
	Assert-True (([string]$plan.snapshot_sha256) -match '^[0-9A-Fa-f]{32,64}$') 'the plan records the snapshot hash it was built from'
	$targetIds = Get-PlanTargetIds $plan
	$recordedTreeIds = @(Get-UETemplateProcessDescendants -Index (Get-UETemplateProcessIndex -Table @(ConvertTo-UETemplateProcessTable -Records $snapshot.processes)) -RootProcessIds @($writerId) | Where-Object { $null -ne (Get-LiveRecord -ProcessId ([int]$_.process_id)) } | ForEach-Object { [int]$_.process_id })
	foreach ($leafId in $recordedTreeIds) {
		Assert-True ($targetIds -contains $leafId) ("the dry run lists the run-owned process {0} that the lease PID alone cannot reach" -f $leafId)
	}
	$deepest = @($plan.stop_targets | Measure-Object -Property depth -Maximum).Maximum
	Assert-True ([int]$deepest -ge 2) ("the listing reaches at least two levels below the writer, got depth {0}" -f $deepest)
	$depths = @($plan.stop_targets | ForEach-Object { [int]$_.depth })
	for ($i = 1; $i -lt $depths.Count; $i++) {
		Assert-True ($depths[$i] -le $depths[$i - 1]) 'the listing is ordered deepest first'
	}
	Assert-True (@(Get-DescendantsOf -RootProcessId $writerId).Count -gt 0) 'the dry run stopped nothing'
	Assert-True ((Get-LiveRecord -ProcessId $writerId) -ne $null) 'the writer survives the dry run'
	Write-Output 'PASS: the dry run writes and prints a deepest-first target list that reaches the grandchild (a)'

	# --- group 3: a live process outside the snapshot is not stopped and is reported (b) --------
	# Take the leaf out of the snapshot: the leaf still hangs off a recorded, run-owned child, so it
	# looks run-owned but cannot be attributed.
	$total = $fixtureRoot
	$snapshotIndex = Get-UETemplateProcessIndex -Table @(ConvertTo-UETemplateProcessTable -Records $snapshot.processes)
	$snapshotDepths = Get-UETemplateProcessDepths -Index $snapshotIndex -RootProcessIds @($writerId)
	$leafRecord = @($snapshot.processes | Where-Object { $snapshotDepths.ContainsKey([int]$_.process_id) -and [int]$snapshotDepths[[int]$_.process_id] -ge 2 }) | Select-Object -First 1
	Assert-True ($null -ne $leafRecord) 'the snapshot records a grandchild two levels below the writer'
	$prunedSnapshot = $snapshot | ConvertTo-Json -Depth 12 | ConvertFrom-Json
	$prunedSnapshot.processes = @(@($prunedSnapshot.processes) | Where-Object { [int]$_.process_id -ne [int]$leafRecord.process_id })
	$prunedPath = Join-Path $fixtureRoot 'snapshot-pruned.json'
	Write-UETemplateJsonFile -Path $prunedPath -Value $prunedSnapshot
	$prunedPlanPath = Join-Path $fixtureRoot 'plan-pruned.json'
	$prunedRun = Invoke-ProcessScript $script:stopScript @('-SnapshotPath', $prunedPath, '-ReportPath', $prunedPlanPath)
	Assert-True ($prunedRun.exit_code -eq 2) ("an unattributed live process keeps the dry-run verdict at unknown (exit 2), got {0}: {1}" -f $prunedRun.exit_code, $prunedRun.stdout)
	Assert-True ($prunedRun.stdout.Contains('live-process-not-in-snapshot')) 'the report names the unattributed process instead of ignoring it'
	$prunedPlan = Read-UETemplateJsonFile -Path $prunedPlanPath -Description 'plan-pruned'
	Assert-True (-not ((Get-PlanTargetIds $prunedPlan) -contains [int]$leafRecord.process_id)) 'the unattributed process is not a stop target'
	Assert-True (@($prunedPlan.stop_targets).Count -gt 0) 'the attributed processes are still listed'
	Assert-True ((Get-LiveRecord -ProcessId ([int]$leafRecord.process_id)) -ne $null) 'the unattributed process was not stopped'
	Write-Output 'PASS: a live process that no snapshot recorded is neither stopped nor ignored (unknown, listed as a gap) (b)'

	# --- group 4: a reused PID is never stopped (c) --------------------------------------------
	# Rewrite the leaf's recorded creation time; the live PID now "belongs to" a different process.
	$reusedSnapshot = $snapshot | ConvertTo-Json -Depth 12 | ConvertFrom-Json
	$reusedLeafTicks = [long]$leafRecord.creation_utc_ticks - 50000
	$reusedSnapshot.processes = @(@($reusedSnapshot.processes) | ForEach-Object {
		if ([int]$_.process_id -eq [int]$leafRecord.process_id) {
			[pscustomobject]@{
				process_id = [int]$_.process_id
				parent_process_id = [int]$_.parent_process_id
				creation_utc_ticks = $reusedLeafTicks
				executable_path = [string]$_.executable_path
				name = [string]$_.name
			}
		} else { $_ }
	})
	$reusedPath = Join-Path $fixtureRoot 'snapshot-pid-reuse.json'
	Write-UETemplateJsonFile -Path $reusedPath -Value $reusedSnapshot
	$reusePlanPath = Join-Path $fixtureRoot 'plan-pid-reuse.json'
	$reuseRun = Invoke-ProcessScript $script:stopScript @('-SnapshotPath', $reusedPath, '-ReportPath', $reusePlanPath)
	$reusePlan = Read-UETemplateJsonFile -Path $reusePlanPath -Description 'plan-pid-reuse'
	Assert-True (-not ((Get-PlanTargetIds $reusePlan) -contains [int]$leafRecord.process_id)) 'a PID whose creation time changed is not a stop target'
	$reuseGaps = @($reusePlan.gaps | Where-Object { [int]$_.process_id -eq [int]$leafRecord.process_id })
	Assert-True ($reuseGaps.Count -eq 1) 'the reused PID is reported as a gap instead of being silently dropped'
	Assert-True (([string]$reuseGaps[0].reason) -eq 'pid-reused-or-identity-mismatch') 'the reused PID is reported with the identity mismatch reason'
	Assert-True ($reuseRun.exit_code -eq 2) ("a stale snapshot identity keeps the verdict at unknown, got {0}: {1}" -f $reuseRun.exit_code, $reuseRun.stdout)
	Assert-True ((Get-LiveRecord -ProcessId ([int]$leafRecord.process_id)) -ne $null) 'the process behind the reused PID survives'
	Write-Output 'PASS: a PID recorded with a different creation time is excluded and survives (c)'

	# --- group 5: execute stops the whole tree and verifies free (a) ---------------------------
	$verificationPath = Join-Path $fixtureRoot 'verification.json'
	$executeRun = Invoke-ProcessScript $script:stopScript @('-SnapshotPath', $snapshotPath, '-ReportPath', $planPath, '-Execute', '-VerificationPath', $verificationPath, '-GraceMilliseconds', '5000')
	Assert-True ($executeRun.exit_code -eq 0) ("execute exits 0 (free), got {0}: {1}" -f $executeRun.exit_code, ($executeRun.stderr + $executeRun.stdout))
	Assert-True (Test-Path -LiteralPath $verificationPath -PathType Leaf) 'execute writes a verification record'
	$verification = Read-UETemplateJsonFile -Path $verificationPath -Description 'verification'
	Assert-True (([string]$verification.verdict) -ceq 'free') 'the verification verdict is free'
	Assert-True ($verification.ue_started -eq $false) 'the stop script records that it did not start UE'
	Assert-True ([int]$verification.residual_count -eq 0) 'no run-owned process remains after the stop'
	Assert-True ([int]$verification.gap_count -eq 0) ("the verification records no attribution gap, got {0}" -f (ConvertTo-Json -InputObject $verification.gaps -Depth 6 -Compress))
	# Only the run's own tree is checked: the rest of the snapshot is the machine's process table, which
	# the run never owned and must not touch.
	$runTreeRecords = @($snapshot.processes | Where-Object { $snapshotDepths.ContainsKey([int]$_.process_id) -and ([long]$_.creation_utc_ticks -gt 0) })
	foreach ($record in $runTreeRecords) {
		$sameIdentity = Test-UETemplateProcessIdentity -ExpectedRecord $record -LiveRecord (Get-LiveRecord -ProcessId ([int]$record.process_id))
		Assert-True (-not $sameIdentity) ("the snapshot process {0} ({1}) is gone" -f [int]$record.process_id, [string]$record.name)
	}
	Write-Output 'PASS: execute stops the writer, the child and the grandchild and reports free (a)'

	# --- group 6: execute without a dry run refuses -------------------------------------------
	$phaseChain = Start-ChainFixture
	$null = Wait-ChainLeaf -WriterId ([int]$phaseChain.Id)
	$phaseSnapshotPath = Join-Path $fixtureRoot 'snapshot-phase.json'
	$phaseCapture = Invoke-ProcessScript $script:startScript @('-RunId', ("run-phase-$testId"), '-WriterProcessId', ([string]$phaseChain.Id), '-SnapshotPath', $phaseSnapshotPath)
	Assert-True ($phaseCapture.exit_code -eq 0) 'the phase fixture snapshot is captured'
	$refusal = Invoke-ProcessScript $script:stopScript @('-SnapshotPath', $phaseSnapshotPath, '-ReportPath', (Join-Path $fixtureRoot 'no-dry-run.json'), '-Execute')
	Assert-True ($refusal.exit_code -ne 0) 'execute without a dry-run listing fails'
	Assert-True ($refusal.stderr.Contains('no dry-run listing')) 'the refusal names the missing dry run'
	Assert-True ((Get-LiveRecord -ProcessId ([int]$phaseChain.Id)) -ne $null) 'the refusal stopped nothing'
	Write-Output 'PASS: execute refuses to stop anything unless the dry-run listing for the same snapshot exists'

	# --- group 7: a dead writer PID alone is not free (d) --------------------------------------
	$deadWriter = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList @('/c', 'ping -n 1 127.0.0.1 >nul') -PassThru -WindowStyle Hidden
	$spawnedProcessIds.Add([int]$deadWriter.Id)
	$deadWriter.WaitForExit()
	$legacyLeasePath = New-LeaseFile ("run-legacy-$testId") ([int]$deadWriter.Id) ''
	$legacyCheck = Invoke-ProcessScript $script:leaseScript @('-LeasePath', $legacyLeasePath)
	Assert-True ($legacyCheck.exit_code -eq 2) ("a lease with a dead writer PID and no snapshot exits 2 (unknown), got {0}: {1}" -f $legacyCheck.exit_code, ($legacyCheck.stderr + $legacyCheck.stdout))
	Assert-True ($legacyCheck.stdout.Contains('VERDICT: unknown')) 'the legacy lease shape answers unknown'
	Assert-True (-not $legacyCheck.stdout.Contains('VERDICT: free')) 'a dead writer PID alone is never free'
	Assert-True ($legacyCheck.stdout.Contains('snapshot-not-recorded')) 'the report says the snapshot is not recorded'
	Write-Output 'PASS: a dead writer PID without a snapshot answers unknown, never free (d)'

	# --- group 7b: a live run-owned set answers held -------------------------------------------
	# The lease check must distinguish held from unknown: the snapshot verifies, and the run-owned
	# processes are still alive.
	$heldChain = Start-ChainFixture
	$null = Wait-ChainLeaf -WriterId ([int]$heldChain.Id)
	$heldSnapshotPath = Join-Path $fixtureRoot 'snapshot-held.json'
	$heldCapture = Invoke-ProcessScript $script:startScript @('-RunId', ("run-held-$testId"), '-WriterProcessId', ([string]$heldChain.Id), '-SnapshotPath', $heldSnapshotPath)
	Assert-True ($heldCapture.exit_code -eq 0) 'the held fixture snapshot is captured'
	$heldLeasePath = New-LeaseFile ("run-held-$testId") ([int]$heldChain.Id) $heldSnapshotPath
	$heldCheck = Invoke-ProcessScript $script:leaseScript @('-LeasePath', $heldLeasePath)
	Assert-True ($heldCheck.exit_code -eq 1) ("a verified snapshot with live run-owned processes exits 1 (held), got {0}: {1}" -f $heldCheck.exit_code, ($heldCheck.stderr + $heldCheck.stdout))
	Assert-True ($heldCheck.stdout.Contains('VERDICT: held')) 'the lease check answers held while the tree is alive'
	Assert-True ($heldCheck.stdout.Contains('OWNED-LIVE:')) 'the held report counts the live run-owned processes'
	# The same lease after the run's own stop must answer free.
	$heldPlanPath = Join-Path $fixtureRoot 'plan-held.json'
	$heldDryRun = Invoke-ProcessScript $script:stopScript @('-SnapshotPath', $heldSnapshotPath, '-ReportPath', $heldPlanPath)
	Assert-True ($heldDryRun.exit_code -eq 0) 'the held fixture dry run is ready'
	$heldExecute = Invoke-ProcessScript $script:stopScript @('-SnapshotPath', $heldSnapshotPath, '-ReportPath', $heldPlanPath, '-Execute', '-VerificationPath', (Join-Path $fixtureRoot 'verification-held.json'), '-GraceMilliseconds', '5000')
	Assert-True ($heldExecute.exit_code -eq 0) 'the held fixture is stopped'
	$heldCheckAfter = Invoke-ProcessScript $script:leaseScript @('-LeasePath', $heldLeasePath)
	Assert-True ($heldCheckAfter.exit_code -eq 0) ("after the run's own stop the lease answers free (0), got {0}: {1}" -f $heldCheckAfter.exit_code, ($heldCheckAfter.stderr + $heldCheckAfter.stdout))
	Assert-True ($heldCheckAfter.stdout.Contains('VERDICT: free')) 'the lease check answers free once the attributed tree is gone'
	Write-Output 'PASS: the lease check reports held while the tree is alive and free after the run stops it'

	# --- group 8: a snapshot that cannot reach its roots stops nothing -------------------------
	$gapSnapshot = $snapshot | ConvertTo-Json -Depth 12 | ConvertFrom-Json
	# Keep the writer as the root but drop its record: no process can be reached from it.
	$gapSnapshot.processes = @(@($gapSnapshot.processes) | Where-Object { [int]$_.process_id -ne $writerId })
	$gapPath = Join-Path $fixtureRoot 'snapshot-unreachable.json'
	Write-UETemplateJsonFile -Path $gapPath -Value $gapSnapshot
	$gapPlanPath = Join-Path $fixtureRoot 'plan-unreachable.json'
	$gapRun = Invoke-ProcessScript $script:stopScript @('-SnapshotPath', $gapPath, '-ReportPath', $gapPlanPath)
	Assert-True ($gapRun.exit_code -eq 2) ("an unreachable snapshot keeps the verdict at unknown (exit 2), got {0}: {1}" -f $gapRun.exit_code, $gapRun.stdout)
	$gapPlan = Read-UETemplateJsonFile -Path $gapPlanPath -Description 'plan-unreachable'
	Assert-True (@($gapPlan.gaps).Count -ge 1) 'the plan records the attribution gap'
	Assert-True (@($gapPlan.stop_targets).Count -eq 0) 'a snapshot that cannot reach its roots stops nothing'
	Write-Output 'PASS: an unverifiable snapshot produces a gap, lists no targets, and answers unknown'

	# --- group 9: another run's recorded processes are excluded -------------------------------
	$otherChain = Start-ChainFixture
	$null = Wait-ChainLeaf -WriterId ([int]$otherChain.Id)
	$otherSnapshotPath = Join-Path $fixtureRoot 'snapshot-other-run.json'
	$otherCapture = Invoke-ProcessScript $script:startScript @('-RunId', ("run-other-$testId"), '-WriterProcessId', ([string]$otherChain.Id), '-SnapshotPath', $otherSnapshotPath)
	Assert-True ($otherCapture.exit_code -eq 0) 'the other run snapshot is captured'
	$otherSnapshot = Read-UETemplateJsonFile -Path $otherSnapshotPath -Description 'snapshot-other-run'
	$otherLive = Get-UETemplateLiveProcessTable
	# The same run's lease is offered as "another run" here, so every process of its own tree must be
	# excluded from its stop set: the exclusion must win over the run's own attribution.
	$otherOwnership = Resolve-UETemplateRunOwnership -Snapshots @($otherSnapshot) -LiveTable $otherLive -OtherSnapshots @($otherSnapshot) -PreserveProcessNames @()
	$otherIndex = Get-UETemplateProcessIndex -Table @(ConvertTo-UETemplateProcessTable -Records $otherSnapshot.processes)
	$otherDepths = Get-UETemplateProcessDepths -Index $otherIndex -RootProcessIds @($otherSnapshot.roots | ForEach-Object { [int]$_ })
	$otherTreeIds = @($otherSnapshot.processes | Where-Object { $otherDepths.ContainsKey([int]$_.process_id) } | ForEach-Object { [int]$_.process_id })
	$excludedIds = @($otherOwnership.excluded | Where-Object { $_.reason -eq 'other-run-process' } | ForEach-Object { [int]$_.process_id })
	Assert-True ($otherTreeIds.Count -ge 3) 'the other run tree has the writer, a child and a grandchild'
	foreach ($id in $otherTreeIds) {
		Assert-True ($excludedIds -contains $id) ("another run's recorded process {0} is excluded from this run's stop set" -f $id)
	}
	Assert-True (@($otherOwnership.owned).Count -eq 0) 'a run whose tree is claimed by another lease owns nothing'
	Write-Output 'PASS: another run''s recorded processes are excluded from this run''s owned set'

	# --- group 10: shared Chrome is preserved -------------------------------------------------
	$chromeSnapshot = $snapshot | ConvertTo-Json -Depth 12 | ConvertFrom-Json
	$chromeRecord = @($chromeSnapshot.processes | Where-Object { [int]$_.process_id -eq $writerId })[0]
	$chromeSnapshot.processes = @(@([pscustomobject]@{
		process_id = [int]$chromeRecord.process_id
		parent_process_id = [int]$chromeRecord.parent_process_id
		creation_utc_ticks = [long]$chromeRecord.creation_utc_ticks
		executable_path = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
		name = 'chrome'
	}))
	$chromePath = Join-Path $fixtureRoot 'snapshot-chrome.json'
	Write-UETemplateJsonFile -Path $chromePath -Value $chromeSnapshot
	$chromePlanPath = Join-Path $fixtureRoot 'plan-chrome.json'
	$chromeRun = Invoke-ProcessScript $script:stopScript @('-SnapshotPath', $chromePath, '-ReportPath', $chromePlanPath)
	$chromePlan = Read-UETemplateJsonFile -Path $chromePlanPath -Description 'plan-chrome'
	Assert-True (@($chromePlan.stop_targets).Count -eq 0) 'shared Chrome is never a stop target'
	$chromeExcluded = @($chromePlan.excluded | Where-Object { $_.reason -eq 'shared-chrome' })
	Assert-True ($chromeExcluded.Count -eq 1) 'shared Chrome is reported as excluded'
	Write-Output 'PASS: shared Chrome is excluded from the stop set instead of being killed by name'

	# --- group 11: the checkout is unchanged --------------------------------------------------
	Assert-True (Test-Path -LiteralPath $script:ownershipScript -PathType Leaf) 'the shared ownership helper exists'
	Assert-True (Test-Path -LiteralPath $script:startScript -PathType Leaf) 'the snapshot capture script exists'
	Assert-True (Test-Path -LiteralPath $script:stopScript -PathType Leaf) 'the stop script exists'
	Assert-True (Test-Path -LiteralPath $script:leaseScript -PathType Leaf) 'the lease check exists'
	Write-Output 'PASS: the helper and the three scripts are present'
} catch {
	$suiteError = $_
} finally {
	Stop-FixtureProcesses
	Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
	$finalStatus = @(& git -C $script:repoRoot status --porcelain --untracked-files=all)
	if ($LASTEXITCODE -ne 0 -or (($finalStatus -join "`n") -cne ($initialStatus -join "`n"))) {
		if ($null -ne $suiteError) { Write-Output ("ASSERT FAILED: {0}" -f $suiteError.Exception.Message) }
		Write-Output 'ASSERT FAILED: the suite leaves the checkout unchanged'
		$suiteError = 'checkout changed'
	}
}

if ($null -ne $suiteError) {
	Write-Output ("ASSERT FAILED: {0}" -f $(if ($suiteError -is [string]) { $suiteError } else { $suiteError.Exception.Message }))
	exit 1
}
Write-Output 'SUITE: pass'
exit 0
