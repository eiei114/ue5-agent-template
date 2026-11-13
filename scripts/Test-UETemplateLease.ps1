[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$productionRoot = Join-Path $repoRoot 'Production'
$leaseScript = Join-Path $PSScriptRoot 'Lease-UETemplateProject.ps1'
$initialCheckoutStatus = @(& git -C $repoRoot status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0) { throw 'Could not record the developer checkout status before testing.' }
$testId = [Guid]::NewGuid().ToString('N')
$fixtureRoot = Join-Path $productionRoot ('.lease-test-' + $testId)
$shellHost = (Get-Process -Id $PID).Path
$concurrentDelayMs = 900

function Assert-True([bool]$Condition, [string]$Message) {
	if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Get-ProductionResidue {
	# .gitignore hides Production/* from `git status --untracked-files=all`, so a leftover fixture is
	# invisible to the checkout comparison. The directory is listed directly instead, and only
	# names this suite can own are reported so a developer's generated projects do not block it.
	$violations = New-Object System.Collections.Generic.List[string]
	$allowed = @('PLACEHOLDER.md') + @([System.IO.Path]::GetFileName($fixtureRoot))
	$suiteOwnedPattern = '^\.lease-test-[0-9a-f]{32}$'
	if (-not (Test-Path -LiteralPath $productionRoot -PathType Container)) {
		$violations.Add('Production/: the directory is missing')
		return $violations.ToArray()
	}
	if (-not (Test-Path -LiteralPath (Join-Path $productionRoot 'PLACEHOLDER.md') -PathType Leaf)) {
		$violations.Add('Production/PLACEHOLDER.md: the tracked placeholder is missing')
	}
	foreach ($entry in @(Get-ChildItem -LiteralPath $productionRoot -Force)) {
		if ($allowed -contains $entry.Name) { continue }
		if ($entry.Name -cnotmatch $suiteOwnedPattern) { continue }
		$violations.Add("Production/$($entry.Name): unexpected entry (ignored by .gitignore, so git status does not report it)")
	}
	return $violations.ToArray()
}

function ConvertTo-HostArguments([string[]]$Values) {
	# Native command arguments are quoted here so a space in the checkout path cannot split them.
	return @($Values | ForEach-Object { if ($_ -match '^[A-Za-z0-9_./\\:=-]+$') { $_ } else { '"' + ($_ -replace '"', '\"') + '"' } })
}

function Invoke-Lease([string]$Action, [string]$Directory, [string[]]$Extra = @()) {
	# The script exits with 0/1/2 for Test and throws for a refused write. Running it as a child
	# process keeps `exit` from terminating this suite and makes the exit code part of the assertion.
	# stdout and stderr are captured through redirected pipes: PowerShell 5.1 turns native stderr
	# into a terminating NativeCommandError under $ErrorActionPreference = 'Stop', and
	# Start-Process -PassThru does not reliably expose ExitCode here.
	$arguments = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $leaseScript, '-Action', $Action, '-ProjectDirectory', $Directory, '-ProductionRoot', $fixtureRoot) + $Extra)
	$startInfo = New-Object System.Diagnostics.ProcessStartInfo
	$startInfo.FileName = $shellHost
	$startInfo.Arguments = (ConvertTo-HostArguments $arguments) -join ' '
	$startInfo.UseShellExecute = $false
	$startInfo.RedirectStandardOutput = $true
	$startInfo.RedirectStandardError = $true
	$startInfo.CreateNoWindow = $true
	$process = [System.Diagnostics.Process]::Start($startInfo)
	$stdout = $process.StandardOutput.ReadToEnd()
	$stderr = $process.StandardError.ReadToEnd()
	if (-not $process.WaitForExit(180000)) {
		$process.Kill()
		throw "Lease $Action child process did not finish within 180s."
	}
	return [pscustomobject]@{
		ExitCode = $process.ExitCode
		Output   = (($stdout, $stderr) -join "`n").Trim()
	}
}

function Get-LeaseFiles([string]$Directory) {
	return @(Get-ChildItem -LiteralPath $Directory -File -Force | Sort-Object Name | ForEach-Object { $_.Name })
}

function Get-FileFingerprint([string]$Path) {
	# mtime plus SHA256: the read-only assertion has to catch a rewrite that preserves the content.
	$info = Get-Item -LiteralPath $Path -Force
	return [pscustomobject]@{
		Sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
		Length = $info.Length
		WrittenUtc = $info.LastWriteTimeUtc.Ticks
	}
}

function Get-RecordValue([string]$Output, [string]$Key) {
	foreach ($line in $Output -split "`n") {
		if ($line -match ('^{0}=(.+)$' -f [regex]::Escape($Key))) { return $Matches[1].Trim() }
	}
	return ''
}

try {
	Assert-True (Test-Path -LiteralPath $leaseScript -PathType Leaf) 'scripts/Lease-UETemplateProject.ps1 exists'
	[System.IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null

	# Contract: the documented order writes the lease to a directory that already exists (the run
	# ledger). Creating a directory and taking a lease are separate operations, so an existing
	# directory must not be reported as an acquisition failure.
	$leaseDirectory = Join-Path $fixtureRoot 'run_A'
	[System.IO.Directory]::CreateDirectory($leaseDirectory) | Out-Null
	$acquire = Invoke-Lease 'Acquire' $leaseDirectory @('-RunId', 'runA', '-IssueId', 'DOT-3042', '-WriterPhase', 'edit')
	Assert-True ($acquire.ExitCode -eq 0) ('acquiring a lease in an existing directory succeeds: ' + $acquire.Output)
	Assert-True ($acquire.Output.Contains('LEASE ACQUIRED')) 'a successful acquisition reports LEASE ACQUIRED'
	Assert-True ($acquire.Output.Contains('directory_existed=True')) 'the existing directory is reported instead of being mistaken for a new lease owner'
	$nonceA = Get-RecordValue $acquire.Output 'nonce'
	Assert-True ($nonceA -match '^[A-Za-z0-9_-]{16,64}$') 'the acquisition prints the nonce the release needs'
	$leasePath = Join-Path $leaseDirectory 'LEASE.json'
	Assert-True (Test-Path -LiteralPath $leasePath -PathType Leaf) 'Acquire writes LEASE.json into the lease directory'
	$bytesA = [System.IO.File]::ReadAllBytes($leasePath)
	$recordA = [System.IO.File]::ReadAllText($leasePath) | ConvertFrom-Json
	$documentedFields = @('run_id', 'issue_id', 'host', 'project_realpath', 'acquired_utc', 'nonce', 'writer_phase', 'pid')
	$actualFields = @($recordA.PSObject.Properties | ForEach-Object { $_.Name })
	Assert-True ((($actualFields | Sort-Object) -join ',') -eq (($documentedFields | Sort-Object) -join ',')) ('LEASE.json carries exactly the fields docs/01-start.md defines: ' + ($actualFields -join ','))
	Assert-True ([string]$recordA.run_id -ceq 'runA') 'LEASE.json records the acquiring run ID'
	Assert-True ([string]$recordA.nonce -ceq $nonceA) 'LEASE.json records the nonce printed by Acquire'
	Assert-True ([int]$recordA.pid -eq $PID -or [int]$recordA.pid -gt 0) 'LEASE.json records a writer PID'
	Write-Output 'PASS: Acquire creates LEASE.json exclusively in an existing directory and prints the nonce'

	# Re-acquisition into the same directory must fail and leave the active lease byte-for-byte
	# unchanged: the second writer must not be able to take over by "acquiring again".
	$reacquire = Invoke-Lease 'Acquire' $leaseDirectory @('-RunId', 'runB', '-IssueId', 'DOT-3042', '-WriterPhase', 'edit')
	Assert-True ($reacquire.ExitCode -ne 0) ('re-acquisition in a directory that already holds an active lease fails: ' + $reacquire.Output)
	Assert-True ($reacquire.Output.Contains('An active lease already exists')) 'the refusal names the existing lease instead of failing silently'
	Assert-True ((@([System.IO.File]::ReadAllBytes($leasePath)) -join ',') -ceq (@($bytesA) -join ',')) 'the refused re-acquisition keeps the matcher lease byte-identical'
	Write-Output 'PASS: re-acquisition is refused and the active lease is kept byte-identical'

	# A lease written by another run before this suite started (crash leftover or a live writer) is
	# the same negative case with unambiguous provenance: acquisition stops, nothing is rewritten.
	$foreignDirectory = Join-Path $fixtureRoot 'run_C'
	[System.IO.Directory]::CreateDirectory($foreignDirectory) | Out-Null
	$foreignRecord = '{"run_id":"foreignRun","issue_id":"DOT-0000","host":"other-host","project_realpath":"C:\\elsewhere","acquired_utc":"2026-11-02T00:00:00Z","nonce":"ffffffffffffffffffffffffffffffff","writer_phase":"edit","pid":4242}'
	$foreignPath = Join-Path $foreignDirectory 'LEASE.json'
	[System.IO.File]::WriteAllText($foreignPath, $foreignRecord, [System.Text.UTF8Encoding]::new($false))
	$foreignBytes = [System.IO.File]::ReadAllBytes($foreignPath)
	$foreignAcquire = Invoke-Lease 'Acquire' $foreignDirectory @('-RunId', 'runD', '-IssueId', 'DOT-3042', '-WriterPhase', 'edit')
	Assert-True ($foreignAcquire.ExitCode -ne 0) ('acquisition into a directory holding another run lease fails: ' + $foreignAcquire.Output)
	Assert-True ((@([System.IO.File]::ReadAllBytes($foreignPath)) -join ',') -ceq (@($foreignBytes) -join ',')) 'the other run lease is preserved byte-identical'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $foreignDirectory 'LEASE_RELEASED.foreignRun.json'))) 'a refused acquisition writes no release receipt'
	Write-Output 'PASS: a pre-existing foreign lease stops acquisition without touching the record'

	# Static check: the script body must not carry any write path that can replace a live lease.
	# A rename or a truncating write reaches the same file another writer holds, so the check covers
	# the whole family instead of only the command the doc happens to name.
	$scriptText = [System.IO.File]::ReadAllText($leaseScript)
	$forbiddenWrites = @('Set-Content', 'Add-Content', 'Out-File', 'WriteAllText', 'WriteAllBytes', 'New-Item', 'Move-Item', 'Rename-Item', 'Copy-Item', 'File.Replace', '.Replace(', 'FileMode.Append')
	$foundForbidden = @($forbiddenWrites | Where-Object { $scriptText.Contains($_) })
	Assert-True ($foundForbidden.Count -eq 0) ('the lease script uses no non-exclusive write path: ' + ($foundForbidden -join ','))
	Assert-True ($scriptText.Contains('[System.IO.FileMode]::CreateNew')) 'the record write goes through FileMode::CreateNew'
	Assert-True ($scriptText.Contains('[System.IO.FileShare]::None')) 'the record write holds FileShare::None'
	Assert-True ($scriptText.Contains('MulticaLeaseDirectory') ) 'the directory is created through the Win32 exclusive primitive'
	Write-Output 'PASS: the lease script has no non-exclusive write path (static inspection of the script body)'

	# 8 processes acquiring the same directory at once: exactly one wins, the seven losers fail,
	# and the record on disk belongs to the winner (not to whichever write landed last).
	$concurrentDirectory = Join-Path $fixtureRoot 'run_concurrent'
	[System.IO.Directory]::CreateDirectory($concurrentDirectory) | Out-Null
	$children = @()
	for ($index = 1; $index -le 8; $index++) {
		$childRunId = "conc$index"
		$quotedLeaseScript = $leaseScript.Replace("'", "''")
		$quotedDirectory = $concurrentDirectory.Replace("'", "''")
		$quotedRoot = $fixtureRoot.Replace("'", "''")
		$childCommand = "Start-Sleep -Milliseconds $concurrentDelayMs; & '$quotedLeaseScript' -Action Acquire -ProjectDirectory '$quotedDirectory' -ProductionRoot '$quotedRoot' -RunId $childRunId -IssueId DOT-3042 -WriterPhase edit; exit `$LASTEXITCODE"
		$childArguments = (ConvertTo-HostArguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $childCommand)) -join ' '
		$startInfo = New-Object System.Diagnostics.ProcessStartInfo
		$startInfo.FileName = $shellHost
		$startInfo.Arguments = $childArguments
		$startInfo.UseShellExecute = $false
		$startInfo.RedirectStandardOutput = $true
		$startInfo.RedirectStandardError = $true
		$startInfo.CreateNoWindow = $true
		$process = [System.Diagnostics.Process]::Start($startInfo)
		# Each child's pipes are drained after the barrier; 8 processes writing at once is too small
		# a payload to fill a pipe buffer, so the drain below cannot deadlock the children.
		$children += [pscustomobject]@{ RunId = $childRunId; Process = $process }
	}
	foreach ($child in $children) {
		$childOutput = $child.Process.StandardOutput.ReadToEnd()
		$childError = $child.Process.StandardError.ReadToEnd()
		if (-not $child.Process.WaitForExit(120000)) {
			$child.Process.Kill()
			throw "Concurrent acquire child $($child.RunId) did not finish within 120s."
		}
		$child | Add-Member -NotePropertyName Output -NotePropertyValue (($childOutput, $childError) -join "`n")
		$child | Add-Member -NotePropertyName ExitCode -NotePropertyValue $child.Process.ExitCode
	}
	$winners = @($children | Where-Object { $_.ExitCode -eq 0 })
	$losers = @($children | Where-Object { $_.ExitCode -ne 0 })
	Assert-True ($winners.Count -eq 1) ('exactly one concurrent acquisition succeeds (winners={0}, losers={1})' -f $winners.Count, $losers.Count)
	Assert-True ($losers.Count -eq 7) 'seven concurrent acquisitions fail'
	$concurrentLease = Join-Path $concurrentDirectory 'LEASE.json'
	$concurrentRecord = [System.IO.File]::ReadAllText($concurrentLease) | ConvertFrom-Json
	Assert-True ([string]$concurrentRecord.run_id -ceq $winners[0].RunId) ('the lease on disk belongs to the single winner (lease={0}, winner={1})' -f $concurrentRecord.run_id, $winners[0].RunId)
	foreach ($loser in $losers) {
		Assert-True ($loser.Output.Contains('An active lease already exists')) ("loser $($loser.RunId) stopped on the existing lease: $($loser.Output)")
	}
	Write-Output 'PASS: 8 concurrent acquisitions produce 1 winner / 7 losers and the record matches the winner'

	# Release: a mismatched nonce or run ID stops and keeps the lease. A matching release writes a
	# per-run LEASE_RELEASED receipt and only then removes LEASE.json.
	$wrongNonce = Invoke-Lease 'Release' $leaseDirectory @('-RunId', 'runA', '-Nonce', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
	Assert-True ($wrongNonce.ExitCode -ne 0) ('release with a mismatched nonce stops: ' + $wrongNonce.Output)
	Assert-True ($wrongNonce.Output.Contains('nonce does not match')) 'the stopped release names the nonce mismatch'
	Assert-True ((@([System.IO.File]::ReadAllBytes($leasePath)) -join ',') -ceq (@($bytesA) -join ',')) 'a mismatched release keeps LEASE.json byte-identical'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $leaseDirectory 'LEASE_RELEASED.runA.json'))) 'a mismatched release writes no receipt'
	$wrongRun = Invoke-Lease 'Release' $leaseDirectory @('-RunId', 'runOther', '-Nonce', $nonceA)
	Assert-True ($wrongRun.ExitCode -ne 0) ('release from another run ID stops: ' + $wrongRun.Output)
	Assert-True ((@([System.IO.File]::ReadAllBytes($leasePath)) -join ',') -ceq (@($bytesA) -join ',')) 'release from another run ID keeps LEASE.json byte-identical'
	Write-Output 'PASS: Release stops on a nonce or run mismatch and deletes nothing'

	$release = Invoke-Lease 'Release' $leaseDirectory @('-RunId', 'runA', '-Nonce', $nonceA)
	Assert-True ($release.ExitCode -eq 0) ('a matching release succeeds: ' + $release.Output)
	Assert-True ($release.Output.Contains('LEASE RELEASED')) 'a successful release reports LEASE RELEASED'
	$receiptPath = Join-Path $leaseDirectory 'LEASE_RELEASED.runA.json'
	Assert-True (Test-Path -LiteralPath $receiptPath -PathType Leaf) 'a successful release leaves the per-run LEASE_RELEASED receipt'
	Assert-True (-not (Test-Path -LiteralPath $leasePath)) 'a successful release removes LEASE.json'
	$receipt = [System.IO.File]::ReadAllText($receiptPath) | ConvertFrom-Json
	Assert-True ([string]$receipt.nonce -ceq $nonceA) 'the receipt carries the released nonce'
	Assert-True ([string]$receipt.run_id -ceq 'runA') 'the receipt carries the released run ID'
	Assert-True ($null -ne $receipt.PSObject.Properties['released_utc']) 'the receipt records when the lease was released'
	$doubleRelease = Invoke-Lease 'Release' $leaseDirectory @('-RunId', 'runA', '-Nonce', $nonceA)
	Assert-True ($doubleRelease.ExitCode -ne 0) ('releasing an already released lease stops: ' + $doubleRelease.Output)
	Write-Output 'PASS: a matching Release leaves LEASE_RELEASED, removes LEASE.json, and refuses a second release'

	# Test is read-only: the record and its directory must be identical before and after.
	$testDirectory = Join-Path $fixtureRoot 'run_T'
	[System.IO.Directory]::CreateDirectory($testDirectory) | Out-Null
	# The acquisition child process exits after writing the record, so a live-writer fixture has to
	# name this suite's own PID explicitly; otherwise the recorded PID is already gone and Test
	# correctly answers free.
	$testAcquire = Invoke-Lease 'Acquire' $testDirectory @('-RunId', 'runT', '-IssueId', 'DOT-3042', '-WriterPhase', 'edit', '-WriterProcessId', $PID)
	Assert-True ($testAcquire.ExitCode -eq 0) ('acquiring the read-only fixture lease succeeds: ' + $testAcquire.Output)
	$testNonce = Get-RecordValue $testAcquire.Output 'nonce'
	$testLease = Join-Path $testDirectory 'LEASE.json'
	$beforeFingerprint = Get-FileFingerprint $testLease
	$beforeFiles = Get-LeaseFiles $testDirectory
	$liveCheck = Invoke-Lease 'Test' $testDirectory @('-RunId', 'runT')
	Assert-True ($liveCheck.ExitCode -eq 0) ('Test reports an active lease for a live writer PID: ' + $liveCheck.Output)
	Assert-True ($liveCheck.Output.Contains('LEASE STATE: active')) 'Test names the active state'
	Assert-True ($liveCheck.Output.Contains('owns=true')) 'Test matches the recorded run ID'
	$strangerCheck = Invoke-Lease 'Test' $testDirectory @('-RunId', 'runOther')
	Assert-True ($strangerCheck.Output.Contains('owns=false')) 'Test reports owns=false for another run ID'
	$noRunCheck = Invoke-Lease 'Test' $testDirectory
	Assert-True ($noRunCheck.ExitCode -eq 0 -and $noRunCheck.Output.Contains('owns=false')) 'Test without a run ID reports a live lease without claiming ownership'
	$afterFingerprint = Get-FileFingerprint $testLease
	$afterFiles = Get-LeaseFiles $testDirectory
	Assert-True ($afterFingerprint.Sha256 -ceq $beforeFingerprint.Sha256) 'Test does not change the lease content'
	Assert-True ($afterFingerprint.Length -eq $beforeFingerprint.Length) 'Test does not change the lease size'
	Assert-True ($afterFingerprint.WrittenUtc -eq $beforeFingerprint.WrittenUtc) 'Test does not touch the lease mtime'
	Assert-True ((($afterFiles -join ',') -ceq ($beforeFiles -join ','))) 'Test adds no file to the lease directory'
	Write-Output 'PASS: Test reports active/ownership and writes nothing (content, size and mtime unchanged)'

	# A leftover lease whose writer PID is gone is "free", not "active" and not "unknown". The record
	# still has to be released by hand, so the state is distinct from an unreadable lease.
	$staleDirectory = Join-Path $fixtureRoot 'run_S'
	[System.IO.Directory]::CreateDirectory($staleDirectory) | Out-Null
	$staleAcquire = Invoke-Lease 'Acquire' $staleDirectory @('-RunId', 'runS', '-IssueId', 'DOT-3042', '-WriterPhase', 'edit', '-WriterProcessId', '999999')
	Assert-True ($staleAcquire.ExitCode -eq 0) ('acquiring a lease for an exited PID still records the lease: ' + $staleAcquire.Output)
	$staleCheck = Invoke-Lease 'Test' $staleDirectory @('-RunId', 'runS')
	Assert-True ($staleCheck.ExitCode -eq 1) ('Test exits 1 for a leftover lease whose writer is gone: ' + $staleCheck.Output)
	Assert-True ($staleCheck.Output.Contains('LEASE STATE: free')) 'a leftover lease is reported as free, not as active'
	Assert-True ($staleCheck.Output.Contains('still has to be released or reconciled by hand')) 'free says the leftover record is still blocking, so it is not an invitation to overwrite'
	Write-Output 'PASS: Test distinguishes a leftover lease (free) from an active one'

	# missing lease and unreadable lease both end in "unknown" and exit 2, never in "free".
	$emptyDirectory = Join-Path $fixtureRoot 'run_U'
	[System.IO.Directory]::CreateDirectory($emptyDirectory) | Out-Null
	$missingCheck = Invoke-Lease 'Test' $emptyDirectory @('-RunId', 'runU')
	Assert-True ($missingCheck.ExitCode -eq 2) ('Test exits 2 when there is no lease record: ' + $missingCheck.Output)
	Assert-True ($missingCheck.Output.Contains('LEASE STATE: unknown')) 'a missing lease is unknown, not free'
	Assert-True ((Get-LeaseFiles $emptyDirectory).Count -eq 0) 'Test does not create a lease record to answer'
	$brokenDirectory = Join-Path $fixtureRoot 'run_V'
	[System.IO.Directory]::CreateDirectory($brokenDirectory) | Out-Null
	[System.IO.File]::WriteAllText((Join-Path $brokenDirectory 'LEASE.json'), '{"run_id":"half', [System.Text.UTF8Encoding]::new($false))
	$brokenCheck = Invoke-Lease 'Test' $brokenDirectory
	Assert-True ($brokenCheck.ExitCode -eq 2) ('Test exits 2 for an unreadable lease: ' + $brokenCheck.Output)
	Assert-True ($brokenCheck.Output.Contains('owns=unknown')) 'an unreadable lease does not claim ownership'
	$foreignHostCheck = Invoke-Lease 'Test' $foreignDirectory
	Assert-True ($foreignHostCheck.ExitCode -eq 2) ('Test cannot judge another host lease and exits 2: ' + $foreignHostCheck.Output)
	Assert-True ($foreignHostCheck.Output.Contains('LEASE STATE: unknown')) 'another host lease is unknown instead of a guessed state'
	Write-Output 'PASS: Test answers unknown with exit 2 for a missing, unreadable or other-host lease'

	# The written contract: the docs must describe the shipped script instead of "未同梱".
	$startDoc = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'docs\01-start.md'))
	Assert-True (-not $startDoc.Contains('スクリプト未同梱')) 'docs/01-start.md no longer declares the lease script missing'
	Assert-True ($startDoc.Contains('scripts/Lease-UETemplateProject.ps1')) 'docs/01-start.md names the shipped lease script'
	Assert-True ($startDoc.Contains('-Action Acquire')) 'docs/01-start.md shows the real Acquire invocation'
	Assert-True ($startDoc.Contains('-Action Release')) 'docs/01-start.md shows the real Release invocation'
	Assert-True ($startDoc.Contains('-Action Test')) 'docs/01-start.md shows the read-only Test invocation'
	$agentsDoc = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'AGENTS.md'))
	Assert-True ($agentsDoc.Contains('Lease-UETemplateProject.ps1')) 'AGENTS.md references the lease script'
	$qaTemplate = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'templates\QA.md'))
	Assert-True ($qaTemplate.Contains('Lease-UETemplateProject.ps1')) 'templates/QA.md references the lease script for the nonce/release receipt row'
	$changeLog = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'CHANGELOG.md'))
	Assert-True ($changeLog.Contains('DOT-3042')) 'CHANGELOG.md records this change'
	Assert-True ($changeLog.Contains('Lease-UETemplateProject.ps1')) 'CHANGELOG.md names the script it documents'
	Write-Output 'PASS: the docs, AGENTS.md and QA template describe the shipped lease script'

	# The existing regression suite must stay untouched by this change.
	$scaffoldSuite = Join-Path $PSScriptRoot 'Test-UETemplateScaffold.ps1'
	$generatorText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'New-UETemplateScaffold.ps1'))
	Assert-True ($generatorText.Contains('[MulticaTemplateDirectory]::CreateDirectory')) 'the generator keeps its own exclusive mkdir; the lease script does not replace it'
	Write-Output 'PASS: the generator directory creation is unchanged (the lease script only leases)'
} catch {
	# `$_` is not the in-flight error inside a bare `finally`; capture it here so a cleanup failure
	# cannot hide the assertion that actually failed.
	$suiteError = $_
} finally {
	if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
		Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
	}
	$cleanupProblems = @(Get-ProductionResidue | ForEach-Object { "Production/ residual entry after cleanup: $_" })
	if (Test-Path -LiteralPath $fixtureRoot) { $cleanupProblems += "fixture root still exists: $fixtureRoot" }
	$finalCheckoutStatus = @(& git -C $repoRoot status --porcelain --untracked-files=all)
	if ($LASTEXITCODE -ne 0) { throw 'Could not verify the developer checkout status after testing.' }
	if (($finalCheckoutStatus -join "`n") -cne ($initialCheckoutStatus -join "`n")) {
		$cleanupProblems += 'lease suite leaves the developer checkout unchanged'
		$cleanupProblems += ('before: ' + ($initialCheckoutStatus -join ' | '))
		$cleanupProblems += ('after: ' + ($finalCheckoutStatus -join ' | '))
	}
	if ($cleanupProblems.Count -gt 0) {
		if ($null -ne $suiteError) { Write-Output "ASSERT FAILED: $($suiteError.Exception.Message)" }
		Assert-True $false ('lease suite did not leave a clean tree: ' + ($cleanupProblems -join '; '))
	}
	if ($null -ne $suiteError) { throw $suiteError }
}

Write-Output 'LEASE SUITE PASSED'
exit 0
