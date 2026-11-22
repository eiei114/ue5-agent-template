[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$productionRoot = Join-Path $repoRoot 'Production'
$measureScript = Join-Path $PSScriptRoot 'Measure-UERenderArtifacts.ps1'
$initialCheckoutStatus = @(& git -C $repoRoot status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0) { throw 'Could not record the developer checkout status before testing.' }

$testId = [Guid]::NewGuid().ToString('N')
$fixtureRoot = Join-Path $productionRoot ('.render-artifacts-test-' + $testId)
$reportRoot = Join-Path $fixtureRoot 'reports'
$reportCounter = 0

function Assert-True([bool]$Condition, [string]$Message) {
	if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

# ---------------------------------------------------------------- assertion-group ledger
# The one declaration of the assertion groups this suite must run. Every group ends in
# Register-Group with the same identifier, and the end of the run compares the two. A group that
# is deleted, skipped or renamed no longer registers, so the run fails and names it instead of
# finishing with fewer PASS lines. Keys are words, never positions, so reordering cannot break them.
$expectedGroups = @(
	'clean-zero-based-240-frame',
	'report-creation-exclusive-cannot-write',
	'240-file-sequence-one-missing',
	'leading-middle-trailing-gaps-all',
	'241st-frame-against-240-frame',
	'unpadded-indices-extension-case-differences',
	'nested-layouts-unrelated-files-fail',
	'0-byte-truncated-payload-corrupt',
	'resolution-mismatches-fail-unconfigured-half',
	'non-zero-starts-need-explicit',
	'missing-failing-slow-decoders-stay',
	'decode-failure-outranks-timeout-timeouts',
	'untouched-input-gate-names-removed',
	'junction-alias-framesdirectory-refused-guard',
	'declared-step-2-lattice-passes',
	'declared-step-offset-lattices-pass',
	'per-frame-digests-equal-real',
	'mrq-legacy-movie-graph-names',
	'extension-carries-codec-contract-jpg',
	'render-exit-code-judged-not-only-recorded',
	'same-run-reinspection-numbered-report-rule',
	'frame-variety-declared-identical-frames',
	'run-source-revision-provenance-required',
	'all-fixture-directories-report-directory',
	'group-ledger-drift-fails'
)
$registeredGroups = New-Object 'System.Collections.Generic.List[string]'

function Register-Group([string]$Id, [string]$Message) {
	$script:registeredGroups.Add($Id)
	Write-Output "PASS: $Message"
}

function Get-GroupLedgerProblems([string[]]$Expected, [string[]]$Registered) {
	$Expected = @($Expected)
	$Registered = @($Registered)
	$problems = @()
	if ($Expected.Count -eq 0) { $problems += 'the ledger declares no groups' }
	$missing = @($Expected | Where-Object { $Registered -notcontains $_ })
	$undeclared = @($Registered | Where-Object { $Expected -notcontains $_ } | Select-Object -Unique)
	$duplicated = @($Registered | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
	$declaredTwice = @($Expected | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
	if ($missing.Count -gt 0) { $problems += ('missing groups: ' + ($missing -join ', ')) }
	if ($undeclared.Count -gt 0) { $problems += ('undeclared groups: ' + ($undeclared -join ', ')) }
	if ($duplicated.Count -gt 0) { $problems += ('groups registered twice: ' + ($duplicated -join ', ')) }
	if ($declaredTwice.Count -gt 0) { $problems += ('groups declared twice: ' + ($declaredTwice -join ', ')) }
	return $problems
}

function Assert-GroupLedger([string[]]$Expected, [string[]]$Registered) {
	$problems = @(Get-GroupLedgerProblems $Expected $Registered)
	Assert-True ($problems.Count -eq 0) ('every declared assertion group ran: expected {0}, got {1}; {2}' -f @($Expected).Count, @($Registered).Count, ($problems -join '; '))
}


function New-ReportPath([string]$Label) {
	$script:reportCounter++
	$path = Join-Path $reportRoot ("{0:D3}-{1}.json" -f $script:reportCounter, $Label)
	return $path
}

# ---------------------------------------------------------------- PNG fixture writer
# The fixture PNGs are generated here so the test never depends on an external image tool and
# never reads licensed assets. A solid-colour truecolour PNG is enough to exercise decode,
# codec and resolution checks; it is not a render result.

$script:Crc32Polynomial = [Convert]::ToUInt32('EDB88320', 16)
$script:Crc32Table = $null

function Initialize-Crc32Table {
	$table = New-Object 'uint32[]' 256
	for ($n = 0; $n -lt 256; $n++) {
		$c = [uint32]$n
		for ($k = 0; $k -lt 8; $k++) {
			if (($c -band 1) -ne 0) { $c = [uint32]($script:Crc32Polynomial -bxor ($c -shr 1)) } else { $c = [uint32]($c -shr 1) }
		}
		$table[$n] = $c
	}
	$script:Crc32Table = $table
}

function Get-Crc32([byte[]]$Bytes) {
	$crc = [uint32]::MaxValue
	foreach ($b in $Bytes) {
		$crc = [uint32]($script:Crc32Table[(($crc -bxor $b) -band 0xFF)] -bxor ($crc -shr 8))
	}
	return [uint32]($crc -bxor [uint32]::MaxValue)
}

function Get-Adler32([byte[]]$Bytes) {
	$a = [uint32]1
	$b = [uint32]0
	foreach ($byte in $Bytes) {
		$a = [uint32](($a + $byte) % 65521)
		$b = [uint32](($b + $a) % 65521)
	}
	return [uint32](($b -shl 16) -bor $a)
}

function New-PngChunk([string]$Type, [byte[]]$Data) {
	$ms = New-Object System.IO.MemoryStream
	$w = New-Object System.IO.BinaryWriter($ms)
	$length = [uint32]$Data.Length
	$w.Write([byte](($length -shr 24) -band 0xFF))
	$w.Write([byte](($length -shr 16) -band 0xFF))
	$w.Write([byte](($length -shr 8) -band 0xFF))
	$w.Write([byte]($length -band 0xFF))
	$typeBytes = [System.Text.Encoding]::ASCII.GetBytes($Type)
	$w.Write($typeBytes)
	$w.Write($Data)
	$crcInput = New-Object 'byte[]' ($typeBytes.Length + $Data.Length)
	[Array]::Copy($typeBytes, 0, $crcInput, 0, $typeBytes.Length)
	if ($Data.Length -gt 0) { [Array]::Copy($Data, 0, $crcInput, $typeBytes.Length, $Data.Length) }
	$crc = [uint32](Get-Crc32 $crcInput)
	$w.Write([byte](($crc -shr 24) -band 0xFF))
	$w.Write([byte](($crc -shr 16) -band 0xFF))
	$w.Write([byte](($crc -shr 8) -band 0xFF))
	$w.Write([byte]($crc -band 0xFF))
	$w.Flush()
	$bytes = $ms.ToArray()
	$w.Dispose()
	$ms.Dispose()
	return , $bytes
}

function New-FixturePng([int]$Width, [int]$Height, [int]$Shade) {
	$rowLength = 1 + ($Width * 3)
	$raw = New-Object 'byte[]' ($rowLength * $Height)
	for ($y = 0; $y -lt $Height; $y++) {
		$offset = $y * $rowLength
		$raw[$offset] = 0
		for ($x = 0; $x -lt $Width; $x++) {
			$p = $offset + 1 + ($x * 3)
			$value = [byte](($Shade + $x + $y) % 256)
			$raw[$p] = $value
			$raw[$p + 1] = $value
			$raw[$p + 2] = $value
		}
	}
	$compressed = New-Object System.IO.MemoryStream
	$deflate = New-Object System.IO.Compression.DeflateStream($compressed, [System.IO.Compression.CompressionLevel]::Optimal, $true)
	$deflate.Write($raw, 0, $raw.Length)
	$deflate.Dispose()
	$deflateBytes = $compressed.ToArray()
	$compressed.Dispose()

	$zlib = New-Object System.IO.MemoryStream
	$zlib.WriteByte(0x78)
	$zlib.WriteByte(0x9C)
	$zlib.Write($deflateBytes, 0, $deflateBytes.Length)
	$adler = Get-Adler32 $raw
	$zlib.WriteByte([byte](($adler -shr 24) -band 0xFF))
	$zlib.WriteByte([byte](($adler -shr 16) -band 0xFF))
	$zlib.WriteByte([byte](($adler -shr 8) -band 0xFF))
	$zlib.WriteByte([byte]($adler -band 0xFF))
	$zlibBytes = $zlib.ToArray()
	$zlib.Dispose()

	$ihdr = New-Object 'byte[]' 13
	$ihdr[0] = [byte](($Width -shr 24) -band 0xFF)
	$ihdr[1] = [byte](($Width -shr 16) -band 0xFF)
	$ihdr[2] = [byte](($Width -shr 8) -band 0xFF)
	$ihdr[3] = [byte]($Width -band 0xFF)
	$ihdr[4] = [byte](($Height -shr 24) -band 0xFF)
	$ihdr[5] = [byte](($Height -shr 16) -band 0xFF)
	$ihdr[6] = [byte](($Height -shr 8) -band 0xFF)
	$ihdr[7] = [byte]($Height -band 0xFF)
	$ihdr[8] = 8
	$ihdr[9] = 2
	$ihdr[10] = 0
	$ihdr[11] = 0
	$ihdr[12] = 0

	$out = New-Object System.IO.MemoryStream
	$signature = [byte[]](137, 80, 78, 71, 13, 10, 26, 10)
	$out.Write($signature, 0, $signature.Length)
	$chunk = New-PngChunk 'IHDR' $ihdr
	$out.Write($chunk, 0, $chunk.Length)
	$chunk = New-PngChunk 'IDAT' $zlibBytes
	$out.Write($chunk, 0, $chunk.Length)
	$chunk = New-PngChunk 'IEND' ([byte[]]@())
	$out.Write($chunk, 0, $chunk.Length)
	$bytes = $out.ToArray()
	$out.Dispose()
	return , $bytes
}

function New-FrameSequence {
	param(
		[string]$Directory,
		[int]$Start,
		[int]$EndExclusive,
		[int]$Width = 64,
		[int]$Height = 48,
		[int[]]$Skip = @(),
		# MRQ writes `<File Name Format>` with `Zero Pad Frame Numbers` digits, for example
		# `Shot0001.0000.png`. The defaults keep the bare six-digit fixture the older groups use.
		[string]$Prefix = '',
		[int]$DigitCount = 6
	)
	[System.IO.Directory]::CreateDirectory($Directory) | Out-Null
	for ($index = $Start; $index -lt $EndExclusive; $index++) {
		if ($Skip -contains $index) { continue }
		$name = $Prefix + $index.ToString('D' + $DigitCount) + '.png'
		[System.IO.File]::WriteAllBytes((Join-Path $Directory $name), (New-FixturePng -Width $Width -Height $Height -Shade (($index * 11) % 220)))
	}
}

function New-FrameLattice {
	# A lattice fixture: `Count` frames starting at `First`, advancing by `Step`. Step 1 is the
	# contiguous sequence; a larger step is the shape MRQ writes with `Output Frame Step` > 1.
	param(
		[string]$Directory,
		[int]$First,
		[int]$Count,
		[int]$Step = 1,
		[int]$Width = 64,
		[int]$Height = 48
	)
	[System.IO.Directory]::CreateDirectory($Directory) | Out-Null
	for ($k = 0; $k -lt $Count; $k++) {
		$index = $First + ($k * $Step)
		$name = '{0:D6}.png' -f $index
		[System.IO.File]::WriteAllBytes((Join-Path $Directory $name), (New-FixturePng -Width $Width -Height $Height -Shade (($index * 11) % 220)))
	}
}

function Add-Frame {
	param([string]$Directory, [int]$Index, [int]$Width = 64, [int]$Height = 48)
	$name = '{0:D6}.png' -f $Index
	[System.IO.File]::WriteAllBytes((Join-Path $Directory $name), (New-FixturePng -Width $Width -Height $Height -Shade (($Index * 11) % 220)))
}

function Get-DirectorySnapshot([string]$Directory) {
	$entries = @(Get-ChildItem -LiteralPath $Directory -Force -Recurse | Sort-Object -Property FullName)
	return (@($entries | ForEach-Object {
		$relative = $_.FullName.Substring($Directory.Length)
		if ($_.PSIsContainer) { "D:$relative" } else { "F:{0}:{1}" -f $relative, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
	}) -join "`n")
}

# ---------------------------------------------------------------- fixture input registry
# The suite builds every fixture itself, so "the inspector never changed its input" is only worth
# asserting if each fixture is compared with the state it had when the suite finished building it.
# A group-local before/after pair is not enough: a later group can still corrupt an earlier fixture
# and nothing looks at it again. Every fixture therefore registers its snapshot as soon as it is
# built, and one gate at the end compares all of them and names the paths that moved.
$script:fixtureBaselines = [ordered]@{}
$script:declaredFixtureRootFiles = New-Object System.Collections.Generic.List[string]
$script:refusedReportCounter = 0

function Register-FixtureSnapshot([string]$RelativePath) {
	$full = Join-Path $fixtureRoot $RelativePath
	Assert-True (Test-Path -LiteralPath $full -PathType Container) "fixture '$RelativePath' exists before its baseline is recorded"
	$script:fixtureBaselines[$RelativePath] = Get-DirectorySnapshot $full
}

function Register-FixtureRootFile([string]$Name) {
	if (-not $script:declaredFixtureRootFiles.Contains($Name)) { $script:declaredFixtureRootFiles.Add($Name) }
}

function ConvertTo-SnapshotPath([string]$Line) {
	# Snapshot lines are "D:<path>" or "F:<path>:<sha256>". The gate has to name a path a human can
	# open, not a hash line.
	if ($Line.StartsWith('D:')) { return (($Line.Substring(2).TrimStart('\') -replace '\\', '/') + '/') }
	if ($Line.StartsWith('F:')) {
		$rest = $Line.Substring(2)
		$lastColon = $rest.LastIndexOf(':')
		if ($lastColon -gt 0) { $rest = $rest.Substring(0, $lastColon) }
		return ($rest.TrimStart('\') -replace '\\', '/')
	}
	return $Line
}

function ConvertTo-SnapshotMap([string]$Snapshot) {
	$map = @{}
	foreach ($line in @($Snapshot -split "`n")) {
		if ([string]::IsNullOrEmpty($line)) { continue }
		$map[(ConvertTo-SnapshotPath $line)] = $line
	}
	return $map
}

function Get-FixtureInputDrift {
	$violations = New-Object System.Collections.Generic.List[string]
	foreach ($relative in @($script:fixtureBaselines.Keys)) {
		$full = Join-Path $fixtureRoot $relative
		if (-not (Test-Path -LiteralPath $full -PathType Container)) {
			$violations.Add("$relative/: the fixture directory is gone")
			continue
		}
		$before = ConvertTo-SnapshotMap $script:fixtureBaselines[$relative]
		$after = ConvertTo-SnapshotMap (Get-DirectorySnapshot $full)
		foreach ($path in @($before.Keys)) {
			if (-not $after.ContainsKey($path)) { $violations.Add("$relative/$path : removed") }
			elseif ($before[$path] -cne $after[$path]) { $violations.Add("$relative/$path : content changed") }
		}
		foreach ($path in @($after.Keys)) {
			if (-not $before.ContainsKey($path)) { $violations.Add("$relative/$path : added") }
		}
	}
	return $violations.ToArray()
}

function Get-FixtureRootDrift {
	$violations = New-Object System.Collections.Generic.List[string]
	if (-not (Test-Path -LiteralPath $fixtureRoot -PathType Container)) {
		$violations.Add('the fixture root is gone')
		return $violations.ToArray()
	}
	$known = @('reports') + @($script:fixtureBaselines.Keys) + @($script:declaredFixtureRootFiles)
	foreach ($entry in @(Get-ChildItem -LiteralPath $fixtureRoot -Force)) {
		if ($known -notcontains $entry.Name) { $violations.Add("$($entry.Name): unexpected entry in the fixture root") }
	}
	return $violations.ToArray()
}

function Get-ReportDrift {
	# reports/ is the only subtree the suite writes on purpose, so it is excluded from the fixture
	# snapshots above and accounted for separately: one non-empty .json file per report path the suite
	# allocated, minus the paths it deliberately had refused.
	$violations = New-Object System.Collections.Generic.List[string]
	if (-not (Test-Path -LiteralPath $reportRoot -PathType Container)) {
		$violations.Add('reports/: the report directory is gone')
		return $violations.ToArray()
	}
	$reports = @(Get-ChildItem -LiteralPath $reportRoot -Force)
	foreach ($report in $reports) {
		if ($report.PSIsContainer) { $violations.Add("reports/$($report.Name): unexpected directory") }
		elseif ([System.IO.Path]::GetExtension($report.Name) -ne '.json') { $violations.Add("reports/$($report.Name): unexpected report name") }
		elseif ($report.Length -le 0) { $violations.Add("reports/$($report.Name): empty report") }
	}
	$expectedReports = $script:reportCounter - $script:refusedReportCounter
	$reportFiles = @($reports | Where-Object { -not $_.PSIsContainer }).Count
	if ($reportFiles -ne $expectedReports) {
		$violations.Add("reports/: expected $expectedReports report(s) for the allocated paths, found $reportFiles")
	}
	return $violations.ToArray()
}

function Assert-FixtureInputsUnchanged {
	$drift = @(Get-FixtureInputDrift) + @(Get-FixtureRootDrift) + @(Get-ReportDrift)
	Assert-True ($drift.Count -eq 0) ("fixture inputs changed during the suite: " + ($drift -join '; '))
}

function Get-ProductionResidue {
	# .gitignore excludes Production/* from `git status --untracked-files=all`, so an ignored leftover
	# from a crashed or interrupted run is invisible to the checkout comparison at the end of the
	# suite. The repository ships exactly one file under Production/, so the directory is compared
	# directly instead of trusting git to report what it ignores. This run's own fixture root is the
	# single transient entry allowed here; it is created after the pre-flight check and removed before
	# the post-flight one. Only .render-artifacts-test-* names (this suite's own, for any run) are
	# reported, so a developer's generated Production/<Name>_<runid>/ projects and another suite's
	# transient entries do not block the run.
	$violations = New-Object System.Collections.Generic.List[string]
	$ownFixtureName = [System.IO.Path]::GetFileName($fixtureRoot)
	if (-not (Test-Path -LiteralPath $productionRoot -PathType Container)) {
		$violations.Add('Production/: the directory is missing')
		return $violations.ToArray()
	}
	if (-not (Test-Path -LiteralPath (Join-Path $productionRoot 'PLACEHOLDER.md') -PathType Leaf)) {
		$violations.Add('Production/PLACEHOLDER.md: the tracked placeholder is missing')
	}
	foreach ($entry in @(Get-ChildItem -LiteralPath $productionRoot -Force)) {
		if ($entry.Name -eq 'PLACEHOLDER.md') { continue }
		if ($entry.PSIsContainer -and $entry.Name -eq $ownFixtureName) { continue }
		if (-not $entry.Name.StartsWith('.render-artifacts-test-', [System.StringComparison]::Ordinal)) { continue }
		$violations.Add("Production/$($entry.Name): unexpected entry (ignored by .gitignore, so git status does not report it)")
	}
	return $violations.ToArray()
}

function Invoke-Measure {
	# Groups written before render_exit existed test the image sequence checks, so they declare a
	# passing render exit code here and keep their original expectations. A call that supplies its own
	# RenderExitCode, or sets NoDefaultRenderExit, is passed through untouched; the render-exit group
	# below uses that to test the unverified, fail and rejected cases.
	param([hashtable]$Bound, [string]$Script = $measureScript, [switch]$NoDefaultRenderExit, [switch]$KeepProvenanceAsGiven)
	# The script refuses a missing or blank RunId / SourceRevision, so every case that is not about
	# provenance gets fixed fixture values. The provenance group passes the switch to control them.
	if (-not $KeepProvenanceAsGiven) {
		$Bound = $Bound.Clone()
		if (-not $Bound.ContainsKey('RunId')) { $Bound['RunId'] = "fixture-$testId" }
		if (-not $Bound.ContainsKey('SourceRevision')) { $Bound['SourceRevision'] = 'fixture' }
	}
	if (-not $NoDefaultRenderExit -and -not $Bound.ContainsKey('RenderExitCode')) {
		$Bound = $Bound.Clone()
		$Bound['RenderExitCode'] = '0'
	}
	$captured = New-Object System.Collections.Generic.List[string]
	$exitCode = $null
	$threw = $false
	$errorMessage = ''
	$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
	try {
		& $Script @Bound 2>&1 | ForEach-Object { $captured.Add([string]$_) }
		$exitCode = $LASTEXITCODE
	} catch {
		$threw = $true
		$errorMessage = $_.Exception.Message
	}
	$stopwatch.Stop()
	return [pscustomobject]@{
		ExitCode = $exitCode
		Threw = $threw
		Error = $errorMessage
		Output = ($captured -join "`n")
		ElapsedSeconds = $stopwatch.Elapsed.TotalSeconds
	}
}

function Read-Report([string]$Path) {
	Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "report was created: $Path"
	return [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
}

function Get-DigestViolations($Report, [string]$Directory) {
	# The per-frame digest contract: every frames[] entry says whether its digest was computed. A
	# 'computed' sha256 must equal the SHA-256 of the real file on disk; a 'not_computed' one must be
	# null, never an empty or placeholder string. Each violation names the file and its index, so a
	# regression that writes a constant or empty digest is reported by path instead of as a bare count.
	$violations = New-Object System.Collections.Generic.List[string]
	foreach ($frame in @($Report.frames)) {
		$label = "$($frame.file) (index $($frame.index))"
		$state = [string]$frame.digest_state
		if ($state -ceq 'computed') {
			$expected = (Get-FileHash -LiteralPath (Join-Path $Directory ([string]$frame.file)) -Algorithm SHA256).Hash.ToLowerInvariant()
			if ($frame.sha256 -isnot [string] -or $frame.sha256 -cne $expected) {
				$violations.Add("$label : sha256 '$($frame.sha256)' is not the SHA-256 of the file ($expected)")
			}
		} elseif ($state -ceq 'not_computed') {
			if ($null -ne $frame.sha256) { $violations.Add("$label : digest_state is not_computed but sha256 is '$($frame.sha256)', not null") }
		} else {
			$violations.Add("$label : digest_state is '$state', expected computed or not_computed")
		}
	}
	return $violations.ToArray()
}

function Get-FailureCategories($Report) {
	return (@($Report.failures | ForEach-Object { [string]$_.category }))
}

Initialize-Crc32Table

# Reported before the fixture root exists, so an ignored leftover from an earlier interrupted run is
# surfaced instead of silently sharing the directory with this suite's fixtures.
$initialProductionResidue = @(Get-ProductionResidue)
Assert-True ($initialProductionResidue.Count -eq 0) ("Production/ holds only the tracked placeholder before testing: " + ($initialProductionResidue -join '; '))

$suiteError = $null
$script:cleanupFailures = New-Object System.Collections.Generic.List[string]
try {
	[System.IO.Directory]::CreateDirectory($reportRoot) | Out-Null

	# ============================================================ group 1: clean 240-frame sequence
	# 240 frames is the vertical-loop baseline (8s at 30fps), so the clean case matches the shape a
	# real MRQ run produces: zero-based, six-digit, end-exclusive.
	$cleanDir = Join-Path $fixtureRoot 'clean240'
	New-FrameSequence -Directory $cleanDir -Start 0 -EndExclusive 240
	Register-FixtureSnapshot 'clean240'
	$cleanBefore = Get-DirectorySnapshot $cleanDir
	$cleanReport = New-ReportPath 'clean240'
	$cleanResult = Invoke-Measure @{
		FramesDirectory        = $cleanDir
		StartNumber            = 0
		EndNumberExclusive     = 240
		ReportPath             = $cleanReport
		ExpectedWidth          = 64
		ExpectedHeight         = 48
		RunId                  = "fixture-$testId"
		SourceRevision         = 'fixture'
	}
	Assert-True (-not $cleanResult.Threw) "clean sequence inspection did not throw: $($cleanResult.Error)"
	Assert-True ($cleanResult.ExitCode -eq 0) "clean sequence exits 0, got $($cleanResult.ExitCode): $($cleanResult.Output)"
	$cleanData = Read-Report $cleanReport
	Assert-True ($cleanData.artifact_verdict -eq 'pass') 'clean sequence verdict is pass'
	foreach ($check in @('composition', 'naming', 'completeness', 'range', 'file_size', 'decode', 'resolution')) {
		Assert-True ($cleanData.checks.$check -eq 'pass') "clean sequence check '$check' is pass, got '$($cleanData.checks.$check)'"
	}
	Assert-True ($cleanData.expectations.frame_count -eq 240) 'report records the 240-frame expectation'
	Assert-True ($cleanData.observed.contract_file_count -eq 240) 'report records 240 observed contract frames'
	Assert-True ($cleanData.observed.first_index -eq 0 -and $cleanData.observed.last_index -eq 239) 'report records the observed index span'
	Assert-True (@($cleanData.failures).Count -eq 0) 'clean sequence records no failure'
	Assert-True ($cleanData.decoder.resolution -eq 'path_lookup' -or $cleanData.decoder.resolution -eq 'explicit') 'report records the decoder resolution route'
	Assert-True ($cleanData.decoder.install_attempted -eq $false) 'the inspector did not install a decoder'
	Assert-True ($cleanData.render_evidence.conclusion -eq 'evaluated_from_exit_code') 'the render conclusion says it came from the declared exit code'
	Assert-True ($cleanData.render_evidence.render_artifacts_cannot_prove_render_success -eq $true) 'the report still says artifacts cannot prove render success'
	Assert-True ($cleanData.checks.render_exit -eq 'pass') 'a declared exit code 0 passes render_exit'
	Assert-True ($cleanData.overall_qa_verdict -eq 'not_assessed') 'a clean artifact list is not an overall QA pass'
	$cleanAfter = Get-DirectorySnapshot $cleanDir
	Assert-True ($cleanBefore -ceq $cleanAfter) 'inspection left every inspected file and name unchanged'
	$cleanDigestViolations = @(Get-DigestViolations $cleanData $cleanDir)
	Assert-True ($cleanDigestViolations.Count -eq 0) ("every clean-sequence frame digest is the real file SHA-256: " + ($cleanDigestViolations -join '; '))
	Assert-True (@($cleanData.frames | Where-Object { $_.digest_state -ceq 'computed' }).Count -eq 240) 'all 240 clean-sequence frames report digest_state computed'
	Register-Group 'clean-zero-based-240-frame' 'clean zero-based 240-frame sequence passes and the inspected directory is untouched'

	# ============================================================ group 2: report exclusivity
	$beforeHash = (Get-FileHash -LiteralPath $cleanReport -Algorithm SHA256).Hash
	$reuseResult = Invoke-Measure @{
		FramesDirectory    = $cleanDir
		StartNumber        = 0
		EndNumberExclusive = 240
		ReportPath         = $cleanReport
	}
	Assert-True ($reuseResult.ExitCode -eq 3 -and -not $reuseResult.Threw) 'an existing report path is refused instead of overwritten'
	Assert-True ($reuseResult.Output.Contains('already exists')) 'the refusal names the existing report path'
	Assert-True ((Get-FileHash -LiteralPath $cleanReport -Algorithm SHA256).Hash -ceq $beforeHash) 'the existing report content is preserved byte for byte'

	$insideResult = Invoke-Measure @{
		FramesDirectory    = $cleanDir
		StartNumber        = 0
		EndNumberExclusive = 240
		ReportPath         = (Join-Path $cleanDir 'report.json')
	}
	Assert-True ($insideResult.ExitCode -eq 3 -and -not $insideResult.Threw) 'a report inside the inspected directory is refused'
	Assert-True ($insideResult.Output.Contains('outside the inspected frame directory')) 'the refusal names the write-boundary rule'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $cleanDir 'report.json'))) 'the refused report wrote nothing into the inspected directory'
	Assert-True ((Get-DirectorySnapshot $cleanDir) -ceq $cleanBefore) 'refused report attempts left the frame directory unchanged'

	$junctionPath = Join-Path $fixtureRoot 'clean240-junction'
	$junctionReport = Join-Path $junctionPath 'junction-report.json'
	$junctionBefore = Get-DirectorySnapshot $cleanDir
	try {
		New-Item -ItemType Junction -Path $junctionPath -Target $cleanDir -ErrorAction Stop | Out-Null
		$junctionResult = Invoke-Measure @{
			FramesDirectory    = $cleanDir
			StartNumber        = 0
			EndNumberExclusive = 240
			ReportPath         = $junctionReport
		}
		Assert-True ($junctionResult.ExitCode -eq 3 -and -not $junctionResult.Threw) 'a report parent junction into the inspected directory is refused'
		Assert-True ($junctionResult.Output.Contains('reparse point')) 'the junction refusal identifies the unsafe path component'
		Assert-True (-not (Test-Path -LiteralPath $junctionReport)) 'the refused junction report was not created through the alias'
		Assert-True (-not (Test-Path -LiteralPath (Join-Path $cleanDir 'junction-report.json'))) 'the refused junction report did not appear in the inspected directory'
		Assert-True ((Get-DirectorySnapshot $cleanDir) -ceq $junctionBefore) 'the junction refusal left every inspected frame name and hash unchanged'
	} finally {
		# Keep the test safe even when run against a regression that writes through this junction.
		$escapedReport = Join-Path $cleanDir 'junction-report.json'
		if (Test-Path -LiteralPath $escapedReport) { Remove-Item -LiteralPath $escapedReport -Force }
		if (Test-Path -LiteralPath $junctionPath) { [System.IO.Directory]::Delete($junctionPath, $false) }
	}
	Register-Group 'report-creation-exclusive-cannot-write' 'report creation is exclusive and cannot write inside the inspected sequence'

	# ============================================================ group 3: baseline blind spot
	# The documented baseline only counts 240 output frames. A sequence that lost frame 120 and
	# gained frame 240 still holds exactly 240 files, so a count-only check passes while ffmpeg
	# would encode a shifted sequence. The index-set comparison must fail this fixture.
	$swapDir = Join-Path $fixtureRoot 'swap240'
	Copy-Item -LiteralPath $cleanDir -Destination $swapDir -Recurse
	Remove-Item -LiteralPath (Join-Path $swapDir '000120.png') -Force
	Add-Frame -Directory $swapDir -Index 240
	Register-FixtureSnapshot 'swap240'
	$swapFileCount = @(Get-ChildItem -LiteralPath $swapDir -File).Count
	Assert-True ($swapFileCount -eq 240) 'the swap fixture holds exactly 240 image files, like the baseline expects'
	$swapReport = New-ReportPath 'swap240'
	$swapResult = Invoke-Measure @{
		FramesDirectory      = $swapDir
		StartNumber          = 0
		EndNumberExclusive   = 240
		ReportPath           = $swapReport
		ExpectedWidth        = 64
		ExpectedHeight       = 48
		RenderExitCode       = '0'
		RenderNotification   = 'MRQ finished with exit 0'
	}
	Assert-True (-not $swapResult.Threw) "swap fixture inspection did not throw: $($swapResult.Error)"
	Assert-True ($swapResult.ExitCode -eq 1) "a same-count swapped sequence exits 1, got $($swapResult.ExitCode): $($swapResult.Output)"
	$swapData = Read-Report $swapReport
	Assert-True ($swapData.artifact_verdict -eq 'fail') 'the same-count swapped sequence fails the artifact verdict'
	Assert-True ($swapData.observed.contract_file_count -eq 240) 'the fixture still contains 240 contract files'
	Assert-True ($swapData.checks.completeness -eq 'fail') 'the missing middle frame fails the completeness check'
	Assert-True ($swapData.checks.range -eq 'fail') 'the extra trailing frame fails the range check'
	$swapCategories = Get-FailureCategories $swapData
	Assert-True ($swapCategories -contains 'missing_frames') 'the failure list names the missing frames'
	Assert-True ($swapCategories -contains 'out_of_range_frames') 'the failure list names the out-of-range frames'
	Assert-True ((@($swapData.failures | Where-Object { $_.category -eq 'missing_frames' })[0].sample) -eq '120') 'the missing-frame sample names index 120'
	Assert-True ((@($swapData.failures | Where-Object { $_.category -eq 'out_of_range_frames' })[0].sample) -eq '240') 'the out-of-range sample names index 240'
	Assert-True (@($swapData.violations.missing_indices) -join ',' -eq '120') 'the violations block lists the raw missing index'
	Assert-True (@($swapData.violations.out_of_range_indices) -join ',' -eq '240') 'the violations block lists the raw out-of-range index'
	Assert-True (@($swapData.violations.decode_failures).Count -eq 0) 'the same-count fixture has no decode failure, so only the index set catches it'
	Assert-True ($swapData.render_evidence.exit_code -eq '0') 'the supplied render exit code is recorded, not hidden'
	Assert-True ($swapData.render_evidence.conclusion -eq 'evaluated_from_exit_code') 'render success is not inferred from or overridden by the artifact check'
	Assert-True ($swapData.checks.render_exit -eq 'pass') 'a declared exit code 0 stays pass while the artifact checks fail'
	Assert-True ($swapData.overall_qa_verdict -eq 'not_assessed') 'a negative artifact list does not become an overall QA verdict'
	Register-Group '240-file-sequence-one-missing' 'a 240-file sequence with one missing and one trailing frame fails where a frame count alone passes'

	# ============================================================ group 4: first / middle / last gaps
	foreach ($gapIndex in @(0, 3, 5)) {
		$gapDir = Join-Path $fixtureRoot ("gap-$gapIndex")
		New-FrameSequence -Directory $gapDir -Start 0 -EndExclusive 6 -Skip @($gapIndex)
		Register-FixtureSnapshot "gap-$gapIndex"
		$gapReport = New-ReportPath "gap-$gapIndex"
		$gapResult = Invoke-Measure @{
			FramesDirectory    = $gapDir
			StartNumber        = 0
			EndNumberExclusive = 6
			ReportPath         = $gapReport
			ExpectedWidth      = 64
			ExpectedHeight     = 48
		}
		Assert-True ($gapResult.ExitCode -eq 1) "gap at $gapIndex exits 1, got $($gapResult.ExitCode): $($gapResult.Output)"
		$gapData = Read-Report $gapReport
		$gapFailure = @($gapData.failures | Where-Object { $_.category -eq 'missing_frames' })
		Assert-True ($gapFailure.Count -eq 1) "gap at $gapIndex reports exactly one missing-frames failure"
		Assert-True ($gapFailure[0].sample -eq [string]$gapIndex) "gap at $gapIndex names the missing index"
		Assert-True ($gapData.checks.completeness -eq 'fail') "gap at $gapIndex fails the completeness check"
		Assert-True ($gapData.artifact_verdict -eq 'fail') "gap at $gapIndex fails the artifact verdict"
	}
	Register-Group 'leading-middle-trailing-gaps-all' 'leading, middle and trailing gaps are all detected by index rather than by count'

	# ============================================================ group 5: one extra frame beyond 240
	$extraDir = Join-Path $fixtureRoot 'extra241'
	New-FrameSequence -Directory $extraDir -Start 0 -EndExclusive 241
	Register-FixtureSnapshot 'extra241'
	$extraReport = New-ReportPath 'extra241'
	$extraResult = Invoke-Measure @{
		FramesDirectory    = $extraDir
		StartNumber        = 0
		EndNumberExclusive = 240
		ReportPath         = $extraReport
		ExpectedWidth      = 64
		ExpectedHeight     = 48
	}
	Assert-True ($extraResult.ExitCode -eq 1) "a 241st frame exits 1, got $($extraResult.ExitCode): $($extraResult.Output)"
	$extraData = Read-Report $extraReport
	Assert-True ($extraData.observed.contract_file_count -eq 241) 'the report counts all 241 files'
	Assert-True ($extraData.checks.range -eq 'fail') 'the extra frame fails the range check'
	Assert-True ($extraData.checks.completeness -eq 'pass') 'the extra frame alone does not fail completeness'
	Assert-True ((Get-FailureCategories $extraData) -contains 'out_of_range_frames') 'the extra frame is reported as out of range'
	Register-Group '241st-frame-against-240-frame' 'a 241st frame against a 240-frame end-exclusive range fails the range check'

	# ============================================================ group 6: ambiguous naming
	$paddingDir = Join-Path $fixtureRoot 'padding'
	New-FrameSequence -Directory $paddingDir -Start 0 -EndExclusive 6 -Skip @(2)
	Add-Frame -Directory $paddingDir -Index 2
	Move-Item -LiteralPath (Join-Path $paddingDir '000002.png') -Destination (Join-Path $paddingDir '2.png')
	Register-FixtureSnapshot 'padding'
	$paddingReport = New-ReportPath 'padding'
	$paddingResult = Invoke-Measure @{
		FramesDirectory    = $paddingDir
		StartNumber        = 0
		EndNumberExclusive = 6
		ReportPath         = $paddingReport
	}
	Assert-True ($paddingResult.ExitCode -eq 1) "an unpadded name exits 1, got $($paddingResult.ExitCode): $($paddingResult.Output)"
	$paddingData = Read-Report $paddingReport
	Assert-True ($paddingData.checks.naming -eq 'fail') 'an unpadded index fails the naming check'
	Assert-True ((Get-FailureCategories $paddingData) -contains 'ambiguous_name') 'the unpadded index is reported as an ambiguous name'
	Assert-True ((Get-FailureCategories $paddingData) -contains 'missing_frames') 'the contract index it replaced is reported missing'

	$caseDir = Join-Path $fixtureRoot 'case'
	New-FrameSequence -Directory $caseDir -Start 0 -EndExclusive 6
	Move-Item -LiteralPath (Join-Path $caseDir '000003.png') -Destination (Join-Path $caseDir '000003.PNG')
	Register-FixtureSnapshot 'case'
	$caseReport = New-ReportPath 'case'
	$caseResult = Invoke-Measure @{
		FramesDirectory    = $caseDir
		StartNumber        = 0
		EndNumberExclusive = 6
		ReportPath         = $caseReport
	}
	Assert-True ($caseResult.ExitCode -eq 1) "an extension-case difference exits 1, got $($caseResult.ExitCode): $($caseResult.Output)"
	$caseData = Read-Report $caseReport
	Assert-True ($caseData.checks.naming -eq 'fail') 'an extension-case difference fails the naming check'
	Assert-True ((Get-FailureCategories $caseData) -contains 'ambiguous_name') 'the case difference is reported as an ambiguous name'
	Register-Group 'unpadded-indices-extension-case-differences' 'unpadded indices and extension-case differences are rejected as ambiguous, not silently accepted'

	# ============================================================ group 7: unexpected entries and layout
	$nestedDir = Join-Path $fixtureRoot 'nested'
	New-FrameSequence -Directory $nestedDir -Start 0 -EndExclusive 6
	[System.IO.Directory]::CreateDirectory((Join-Path $nestedDir 'Shot0001')) | Out-Null
	Register-FixtureSnapshot 'nested'
	$nestedReport = New-ReportPath 'nested'
	$nestedResult = Invoke-Measure @{
		FramesDirectory    = $nestedDir
		StartNumber        = 0
		EndNumberExclusive = 6
		ReportPath         = $nestedReport
	}
	Assert-True ($nestedResult.ExitCode -eq 1) "a nested subdirectory exits 1, got $($nestedResult.ExitCode): $($nestedResult.Output)"
	$nestedData = Read-Report $nestedReport
	Assert-True ($nestedData.checks.composition -eq 'fail') 'a nested subdirectory fails the composition check'
	Assert-True ($nestedData.checks.naming -eq 'pass') 'every flat frame name is still valid'
	Assert-True ((Get-FailureCategories $nestedData) -contains 'unsupported_composition') 'the unsupported layout is named instead of being treated as a pass'
	Assert-True (@($nestedData.observed.nested_entries) -contains 'Shot0001') 'the report names the unsupported subdirectory'

	$strayDir = Join-Path $fixtureRoot 'stray'
	New-FrameSequence -Directory $strayDir -Start 0 -EndExclusive 6
	[System.IO.File]::WriteAllText((Join-Path $strayDir 'notes.txt'), 'fixture note', [System.Text.UTF8Encoding]::new($false))
	Register-FixtureSnapshot 'stray'
	$strayReport = New-ReportPath 'stray'
	$strayResult = Invoke-Measure @{
		FramesDirectory    = $strayDir
		StartNumber        = 0
		EndNumberExclusive = 6
		ReportPath         = $strayReport
	}
	Assert-True ($strayResult.ExitCode -eq 1) "an unrelated file exits 1, got $($strayResult.ExitCode): $($strayResult.Output)"
	$strayData = Read-Report $strayReport
	Assert-True ((Get-FailureCategories $strayData) -contains 'unexpected_name') 'a non-frame file is reported instead of being ignored'
	Register-Group 'nested-layouts-unrelated-files-fail' 'nested layouts and unrelated files fail instead of being skipped'

	# ============================================================ group 8: empty and corrupt frames
	$emptyDir = Join-Path $fixtureRoot 'empty'
	New-FrameSequence -Directory $emptyDir -Start 0 -EndExclusive 6 -Skip @(2)
	[System.IO.File]::WriteAllBytes((Join-Path $emptyDir '000002.png'), [byte[]]@())
	Register-FixtureSnapshot 'empty'
	$emptyReport = New-ReportPath 'empty'
	$emptyResult = Invoke-Measure @{
		FramesDirectory    = $emptyDir
		StartNumber        = 0
		EndNumberExclusive = 6
		ReportPath         = $emptyReport
		ExpectedWidth      = 64
		ExpectedHeight     = 48
	}
	Assert-True ($emptyResult.ExitCode -eq 1) "a 0-byte frame exits 1, got $($emptyResult.ExitCode): $($emptyResult.Output)"
	$emptyData = Read-Report $emptyReport
	Assert-True ($emptyData.checks.file_size -eq 'fail') 'a 0-byte frame fails the file-size check'
	Assert-True ((Get-FailureCategories $emptyData) -contains 'empty_file') 'the 0-byte frame is reported'
	Assert-True ($emptyData.artifact_verdict -eq 'fail') 'the 0-byte frame cannot pass the artifact verdict'
	# A 0-byte file follows the same digest rule as every other frame: it is hashed (SHA-256 of zero
	# bytes), reported as computed, and never left as an empty string that reads like a missing digest.
	$emptyEntry = @($emptyData.frames | Where-Object { $_.index -eq 2 })[0]
	Assert-True ($emptyEntry.size_bytes -eq 0) 'the 0-byte frame is recorded with size_bytes 0'
	Assert-True ($emptyEntry.digest_state -ceq 'computed') "the 0-byte frame digest_state is computed, got '$($emptyEntry.digest_state)'"
	Assert-True ($emptyEntry.sha256 -ceq 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855') "the 0-byte frame carries the SHA-256 of zero bytes, got '$($emptyEntry.sha256)'"
	$emptyDigestViolations = @(Get-DigestViolations $emptyData $emptyDir)
	Assert-True ($emptyDigestViolations.Count -eq 0) ("the 0-byte fixture follows the digest contract: " + ($emptyDigestViolations -join '; '))

	$corruptDir = Join-Path $fixtureRoot 'corrupt'
	New-FrameSequence -Directory $corruptDir -Start 0 -EndExclusive 6
	$truncated = New-FixturePng -Width 64 -Height 48 -Shade 90
	$truncatedBytes = New-Object 'byte[]' 40
	[Array]::Copy($truncated, 0, $truncatedBytes, 0, 40)
	[System.IO.File]::WriteAllBytes((Join-Path $corruptDir '000002.png'), $truncatedBytes)
	# A second corruption shape: a complete-sized file whose IDAT payload was rewritten. ffprobe
	# still reports the declared dimensions here, so a dimensions-only check would pass it.
	$corruptHeader = New-FixturePng -Width 64 -Height 48 -Shade 40
	$corruptHeader[60] = [byte]($corruptHeader[60] -bxor 0xFF)
	$corruptHeader[61] = [byte]($corruptHeader[61] -bxor 0xFF)
	$corruptHeader[62] = [byte]($corruptHeader[62] -bxor 0xFF)
	[System.IO.File]::WriteAllBytes((Join-Path $corruptDir '000004.png'), $corruptHeader)
	Register-FixtureSnapshot 'corrupt'
	$corruptReport = New-ReportPath 'corrupt'
	$corruptResult = Invoke-Measure @{
		FramesDirectory    = $corruptDir
		StartNumber        = 0
		EndNumberExclusive = 6
		ReportPath         = $corruptReport
		ExpectedWidth      = 64
		ExpectedHeight     = 48
	}
	Assert-True ($corruptResult.ExitCode -eq 1) "truncated/corrupt frames exit 1, got $($corruptResult.ExitCode): $($corruptResult.Output)"
	$corruptData = Read-Report $corruptReport
	Assert-True ($corruptData.checks.decode -eq 'fail') 'truncated/corrupt frames fail the decode check'
	Assert-True ((Get-FailureCategories $corruptData) -contains 'decode_failed') 'the corrupt frames are reported as decode failures'
	Assert-True ($corruptData.checks.file_size -eq 'pass') 'the corrupt frames are non-empty, so only decode catches them'
	$truncatedEntry = @($corruptData.frames | Where-Object { $_.index -eq 2 })[0]
	Assert-True ($truncatedEntry.decode -eq 'failed') 'the truncated frame is recorded as failed even though the decoder exited 0'
	Assert-True ($truncatedEntry.detail.Contains('no decoded frame')) 'the truncated frame records that no picture decoded'
	$corruptPayloadEntry = @($corruptData.frames | Where-Object { $_.index -eq 4 })[0]
	Assert-True ($corruptPayloadEntry.decode -eq 'failed') 'the payload-corrupt frame is recorded as failed although ffprobe exited 0 and reported dimensions'
	Register-Group '0-byte-truncated-payload-corrupt' '0-byte, truncated and payload-corrupt frames fail; a parseable header without a decoded frame never passes'

	# ============================================================ group 9: resolution mismatch
	$resolutionDir = Join-Path $fixtureRoot 'resolution'
	New-FrameSequence -Directory $resolutionDir -Start 0 -EndExclusive 6 -Skip @(4)
	Add-Frame -Directory $resolutionDir -Index 4 -Width 32 -Height 24
	Register-FixtureSnapshot 'resolution'
	$resolutionReport = New-ReportPath 'resolution'
	$resolutionResult = Invoke-Measure @{
		FramesDirectory    = $resolutionDir
		StartNumber        = 0
		EndNumberExclusive = 6
		ReportPath         = $resolutionReport
		ExpectedWidth      = 64
		ExpectedHeight     = 48
	}
	Assert-True ($resolutionResult.ExitCode -eq 1) "a resolution mismatch exits 1, got $($resolutionResult.ExitCode): $($resolutionResult.Output)"
	$resolutionData = Read-Report $resolutionReport
	Assert-True ($resolutionData.checks.resolution -eq 'fail') 'a differing frame resolution fails the resolution check'
	Assert-True ((Get-FailureCategories $resolutionData) -contains 'resolution_mismatch') 'the differing frame is reported'
	Assert-True ($resolutionData.checks.decode -eq 'pass') 'the differing frame still decodes, so only resolution flags it'

	$unconfiguredDir = Join-Path $fixtureRoot 'unconfigured'
	New-FrameSequence -Directory $unconfiguredDir -Start 0 -EndExclusive 6
	Register-FixtureSnapshot 'unconfigured'
	$unconfiguredReport = New-ReportPath 'unconfigured'
	$unconfiguredResult = Invoke-Measure @{
		FramesDirectory    = $unconfiguredDir
		StartNumber        = 0
		EndNumberExclusive = 6
		ReportPath         = $unconfiguredReport
	}
	Assert-True ($unconfiguredResult.ExitCode -eq 2) "a missing expected resolution exits 2 (unverified), got $($unconfiguredResult.ExitCode): $($unconfiguredResult.Output)"
	$unconfiguredData = Read-Report $unconfiguredReport
	Assert-True ($unconfiguredData.checks.resolution -eq 'unverified') 'an unconfigured resolution stays unverified'
	Assert-True ($unconfiguredData.artifact_verdict -eq 'unverified') 'an unconfigured resolution cannot produce a pass'
	Assert-True ((Get-FailureCategories $unconfiguredData) -contains 'resolution_not_configured') 'the missing input is reported'

	$halfResult = Invoke-Measure @{
		FramesDirectory    = $unconfiguredDir
		StartNumber        = 0
		EndNumberExclusive = 6
		ReportPath         = (New-ReportPath 'half-resolution')
		ExpectedWidth      = 64
	}
	Assert-True ($halfResult.ExitCode -eq 3 -and -not $halfResult.Threw) 'a half-configured resolution is refused instead of guessed'
	$script:refusedReportCounter++
	Assert-True ($halfResult.Output.Contains('must be given together')) 'the refusal explains the paired requirement'
	Register-Group 'resolution-mismatches-fail-unconfigured-half' 'resolution mismatches fail and unconfigured or half-configured resolution stays unverified'

	# ============================================================ group 10: range inputs
	$offsetDir = Join-Path $fixtureRoot 'offset'
	New-FrameSequence -Directory $offsetDir -Start 10 -EndExclusive 16
	Register-FixtureSnapshot 'offset'
	$offsetReport = New-ReportPath 'offset'
	$offsetResult = Invoke-Measure @{
		FramesDirectory    = $offsetDir
		StartNumber        = 10
		EndNumberExclusive = 16
		ReportPath         = $offsetReport
		ExpectedWidth      = 64
		ExpectedHeight     = 48
	}
	Assert-True ($offsetResult.ExitCode -eq 0) "an explicitly declared non-zero start exits 0, got $($offsetResult.ExitCode): $($offsetResult.Output)"
	$offsetData = Read-Report $offsetReport
	Assert-True ($offsetData.observed.first_index -eq 10) 'the report records the observed non-zero start'
	Assert-True ($offsetData.checks.range -eq 'pass') 'the declared non-zero range contains every frame'

	$wrongOffsetReport = New-ReportPath 'offset-wrong'
	$wrongOffsetResult = Invoke-Measure @{
		FramesDirectory    = $offsetDir
		StartNumber        = 0
		EndNumberExclusive = 6
		ReportPath         = $wrongOffsetReport
		ExpectedWidth      = 64
		ExpectedHeight     = 48
	}
	Assert-True ($wrongOffsetResult.ExitCode -eq 1) "an unstated offset exits 1, got $($wrongOffsetResult.ExitCode): $($wrongOffsetResult.Output)"
	$wrongOffsetData = Read-Report $wrongOffsetReport
	Assert-True ((Get-FailureCategories $wrongOffsetData) -contains 'missing_frames') 'the offset is reported as missing frames'
	Assert-True ((Get-FailureCategories $wrongOffsetData) -contains 'out_of_range_frames') 'the actual frames are reported as out of range'

	$equalRangeResult = Invoke-Measure @{
		FramesDirectory    = $offsetDir
		StartNumber        = 4
		EndNumberExclusive = 4
		ReportPath         = (New-ReportPath 'equal-range')
	}
	Assert-True ($equalRangeResult.ExitCode -eq 3 -and -not $equalRangeResult.Threw) 'an empty end-exclusive range is refused instead of passing trivially'
	$script:refusedReportCounter++
	Assert-True ($equalRangeResult.Output.Contains('greater than StartNumber')) 'the refusal explains the end-exclusive range rule'
	Register-Group 'non-zero-starts-need-explicit' 'non-zero starts need an explicit declaration and an empty range cannot pass'

	# ============================================================ group 11: decoder absence, failure, timeout
	$decoderDir = Join-Path $fixtureRoot 'decoder'
	New-FrameSequence -Directory $decoderDir -Start 0 -EndExclusive 6
	Register-FixtureSnapshot 'decoder'
	$missingDecoderReport = New-ReportPath 'decoder-missing'
	$missingDecoderResult = Invoke-Measure @{
		FramesDirectory    = $decoderDir
		StartNumber        = 0
		EndNumberExclusive = 6
		ReportPath         = $missingDecoderReport
		ExpectedWidth      = 64
		ExpectedHeight     = 48
		DecoderPath        = (Join-Path $fixtureRoot 'no-such-decoder.exe')
	}
	Assert-True ($missingDecoderResult.ExitCode -eq 2) "a missing decoder exits 2 (unverified), got $($missingDecoderResult.ExitCode): $($missingDecoderResult.Output)"
	$missingDecoderData = Read-Report $missingDecoderReport
	Assert-True ($missingDecoderData.checks.decode -eq 'unverified') 'a missing decoder leaves decode unverified'
	Assert-True ($missingDecoderData.artifact_verdict -eq 'unverified') 'a missing decoder cannot produce a pass'
	Assert-True ($missingDecoderData.decoder.resolution -eq 'explicit_path_missing') 'the report names the missing decoder path'
	Assert-True ($missingDecoderData.decoder.install_attempted -eq $false) 'no decoder is installed to fill the gap'
	Assert-True ($missingDecoderData.checks.file_size -eq 'pass') 'name and size checks still run without a decoder'

	$failingDecoder = Join-Path $fixtureRoot 'failing-decoder.cmd'
	[System.IO.File]::WriteAllText($failingDecoder, "@echo off`r`nexit /b 3", [System.Text.UTF8Encoding]::new($false))
	Register-FixtureRootFile 'failing-decoder.cmd'
	$failingDecoderReport = New-ReportPath 'decoder-failing'
	$failingDecoderResult = Invoke-Measure @{
		FramesDirectory    = $decoderDir
		StartNumber        = 0
		EndNumberExclusive = 6
		ReportPath         = $failingDecoderReport
		ExpectedWidth      = 64
		ExpectedHeight     = 48
		DecoderPath        = $failingDecoder
	}
	Assert-True ($failingDecoderResult.ExitCode -eq 1) "a non-zero decoder exits 1, got $($failingDecoderResult.ExitCode): $($failingDecoderResult.Output)"
	$failingDecoderData = Read-Report $failingDecoderReport
	Assert-True ($failingDecoderData.checks.decode -eq 'fail') 'a non-zero decoder result fails the decode check'
	Assert-True ((Get-FailureCategories $failingDecoderData) -contains 'decode_failed') 'the decoder failure is reported instead of rounded up'

	$slowDecoder = Join-Path $fixtureRoot 'slow-decoder.cmd'
	[System.IO.File]::WriteAllText($slowDecoder, "@echo off`r`nping -n 20 127.0.0.1 >nul`r`nexit /b 0", [System.Text.UTF8Encoding]::new($false))
	Register-FixtureRootFile 'slow-decoder.cmd'
	$timeoutReport = New-ReportPath 'decoder-timeout'
	$timeoutResult = Invoke-Measure @{
		FramesDirectory             = $decoderDir
		StartNumber                 = 0
		EndNumberExclusive          = 6
		ReportPath                  = $timeoutReport
		ExpectedWidth               = 64
		ExpectedHeight              = 48
		DecoderPath                 = $slowDecoder
		DecoderTimeoutMilliseconds  = 600
	}
	Assert-True ($timeoutResult.ExitCode -eq 2) "a decoder timeout exits 2 (unverified), got $($timeoutResult.ExitCode): $($timeoutResult.Output)"
	Assert-True ($timeoutResult.ElapsedSeconds -lt 25) "the timeout path returns inside its deadline plus cleanup grace, took $([Math]::Round($timeoutResult.ElapsedSeconds, 1))s"
	$timeoutData = Read-Report $timeoutReport
	Assert-True ($timeoutData.checks.decode -eq 'unverified') 'a decode timeout leaves decode unverified, not failed or passed'
	Assert-True ((Get-FailureCategories $timeoutData) -contains 'decode_timeout') 'the timeout is recorded as an explicit timeout'
	Assert-True ($timeoutData.artifact_verdict -eq 'unverified') 'a decode timeout cannot produce a pass'
	Register-Group 'missing-failing-slow-decoders-stay' 'missing, failing and slow decoders stay unverified or fail, and the timeout is bounded'

	# ============================================================ group 11b: fail outranks timeout, retry, total budget
	# One stub decoder stands in for ffprobe. It answers by the file name it is given, so a single
	# sequence can hold frames that decode, frames that exit 0 without a decoded picture (a real decode
	# failure) and frames that run past the deadline.
	#   000002.png : exit 0, stream header but no decoded frame  -> decode failure
	#   000001.png / 000003.png : never finish                   -> timeout on every attempt
	#   000004.png : slow on the first attempt only (flag file)  -> transient slowness when flaky is on
	$stubDecoder = Join-Path $fixtureRoot 'stub-decoder.cmd'
	$stubLines = @(
		'@echo off',
		'setlocal',
		'if "%~1"=="-version" goto version',
		'set "LAST="',
		'for %%a in (%*) do set "LAST=%%~nxa"',
		'if "%LAST%"=="000002.png" goto nopicture',
		'if "%LAST%"=="000001.png" goto slow',
		'if "%LAST%"=="000003.png" goto slow',
		'if "%LAST%"=="000004.png" if defined STUB_FLAKY_FLAG goto flaky',
		':good',
		'echo {"streams":[{"codec_name":"png"}],"frames":[{"width":64,"height":48,"pix_fmt":"rgb24"}]}',
		'exit /b 0',
		':nopicture',
		'echo {"streams":[{"codec_name":"png"}],"frames":[]}',
		'exit /b 0',
		':flaky',
		'if exist "%STUB_FLAKY_FLAG%" goto good',
		'echo x>"%STUB_FLAKY_FLAG%"',
		':slow',
		'ping -n 20 127.0.0.1 >nul',
		'exit /b 0',
		':version',
		'echo stub-decoder 1.0',
		'exit /b 0'
	)
	[System.IO.File]::WriteAllText($stubDecoder, (($stubLines -join "`r`n") + "`r`n"), [System.Text.UTF8Encoding]::new($false))
	Register-FixtureRootFile 'stub-decoder.cmd'
	$stubDir = Join-Path $fixtureRoot 'stub-sequence'
	New-FrameSequence -Directory $stubDir -Start 0 -EndExclusive 6
	Register-FixtureSnapshot 'stub-sequence'

	# (a) A real decode failure and timeouts together: the failure must win, the timeout must not
	# demote it to unverified, and both facts stay in the report.
	$mixedReport = New-ReportPath 'decode-fail-and-timeout'
	$mixedResult = Invoke-Measure @{
		FramesDirectory             = $stubDir
		StartNumber                 = 0
		EndNumberExclusive          = 6
		ReportPath                  = $mixedReport
		ExpectedWidth               = 64
		ExpectedHeight              = 48
		DecoderPath                 = $stubDecoder
		DecoderTimeoutMilliseconds  = 3000
	}
	Assert-True ($mixedResult.ExitCode -eq 1) "a decode failure plus a timeout exits 1 (fail), got $($mixedResult.ExitCode): $($mixedResult.Output)"
	$mixedData = Read-Report $mixedReport
	Assert-True ($mixedData.artifact_verdict -eq 'fail') "a decode failure plus a timeout is a fail, got $($mixedData.artifact_verdict)"
	Assert-True ($mixedData.checks.decode -eq 'fail') 'the decode check is fail, not unverified, when a frame really failed to decode'
	$mixedCategories = Get-FailureCategories $mixedData
	Assert-True ($mixedCategories -contains 'decode_failed') 'the real decode failure stays in failures[]'
	Assert-True ($mixedCategories -contains 'decode_timeout') 'the timeouts stay in failures[] next to the failure'
	$mixedFrames = @($mixedData.frames)
	Assert-True ($mixedFrames[2].decode -eq 'failed') 'the undecodable frame is recorded as failed'
	Assert-True ($mixedFrames[1].decode -eq 'timeout' -and $mixedFrames[1].attempts -eq 2) 'a timed-out frame was retried once and both attempts are recorded'
	Assert-True ($mixedFrames[0].decode -eq 'ok' -and $mixedFrames[0].attempts -eq 1) 'a frame that decoded first time records a single attempt'

	# Timeouts alone, without any decode failure, remain unverified: the fail priority must not turn a
	# slow decoder into a failure.
	$timeoutOnlyDir = Join-Path $fixtureRoot 'stub-timeout-only'
	New-FrameSequence -Directory $timeoutOnlyDir -Start 3 -EndExclusive 4
	Register-FixtureSnapshot 'stub-timeout-only'
	$timeoutOnlyReport = New-ReportPath 'decode-timeout-only'
	$timeoutOnlyResult = Invoke-Measure @{
		FramesDirectory             = $timeoutOnlyDir
		StartNumber                 = 3
		EndNumberExclusive          = 4
		ReportPath                  = $timeoutOnlyReport
		ExpectedWidth               = 64
		ExpectedHeight              = 48
		DecoderPath                 = $stubDecoder
		DecoderTimeoutMilliseconds  = 3000
	}
	Assert-True ($timeoutOnlyResult.ExitCode -eq 2) "timeouts alone exit 2 (unverified), got $($timeoutOnlyResult.ExitCode): $($timeoutOnlyResult.Output)"
	$timeoutOnlyData = Read-Report $timeoutOnlyReport
	Assert-True ($timeoutOnlyData.artifact_verdict -eq 'unverified') 'a persistent timeout without a decode failure stays unverified'
	Assert-True ($timeoutOnlyData.frames[0].attempts -eq 2) 'the persistent timeout shows two attempts'

	# Transient slowness: the frame is slow once, succeeds on the retry, and is recorded as ok with
	# attempts=2 rather than being hidden or failing the sequence.
	$flakyFlag = Join-Path $fixtureRoot 'flaky.flag'
	Register-FixtureRootFile 'flaky.flag'
	$flakyDir = Join-Path $fixtureRoot 'stub-flaky'
	New-FrameSequence -Directory $flakyDir -Start 4 -EndExclusive 6
	Register-FixtureSnapshot 'stub-flaky'
	$flakyReport = New-ReportPath 'decode-flaky-retry'
	$env:STUB_FLAKY_FLAG = $flakyFlag
	try {
		$flakyResult = Invoke-Measure @{
			FramesDirectory             = $flakyDir
			StartNumber                 = 4
			EndNumberExclusive          = 6
			ReportPath                  = $flakyReport
			ExpectedWidth               = 64
			ExpectedHeight              = 48
			DecoderPath                 = $stubDecoder
			DecoderTimeoutMilliseconds  = 3000
		}
	} finally {
		Remove-Item Env:\STUB_FLAKY_FLAG -ErrorAction SilentlyContinue
	}
	Assert-True ($flakyResult.ExitCode -eq 0) "a frame that is slow once and decodes on retry still passes, got $($flakyResult.ExitCode): $($flakyResult.Output)"
	$flakyData = Read-Report $flakyReport
	Assert-True ($flakyData.checks.decode -eq 'pass') 'the retried frame leaves decode at pass'
	Assert-True ($flakyData.frames[0].decode -eq 'ok' -and $flakyData.frames[0].attempts -eq 2) 'the retry is recorded as attempts=2, not hidden'
	Assert-True ($flakyData.frames[1].attempts -eq 1) 'a neighbouring frame stays at one attempt'

	# (c) A total budget that cannot cover the sequence: never a pass, and the report names the budget
	# and says how many frames were and were not evaluated.
	$budgetDir = Join-Path $fixtureRoot 'budget-sequence'
	New-FrameSequence -Directory $budgetDir -Start 0 -EndExclusive 6
	Register-FixtureSnapshot 'budget-sequence'
	$budgetReport = New-ReportPath 'decode-budget-exhausted'
	$budgetResult = Invoke-Measure @{
		FramesDirectory                = $budgetDir
		StartNumber                    = 0
		EndNumberExclusive             = 6
		ReportPath                     = $budgetReport
		ExpectedWidth                  = 64
		ExpectedHeight                 = 48
		DecoderPath                    = $stubDecoder
		DecoderTimeoutMilliseconds     = 3000
		TotalDecodeBudgetMilliseconds  = 1
	}
	Assert-True ($budgetResult.ExitCode -eq 2) "an exhausted budget exits 2 (unverified), got $($budgetResult.ExitCode): $($budgetResult.Output)"
	$budgetData = Read-Report $budgetReport
	Assert-True ($budgetData.artifact_verdict -ne 'pass') 'an exhausted budget can never produce a pass'
	Assert-True ($budgetData.artifact_verdict -eq 'unverified' -and $budgetData.checks.decode -eq 'unverified') 'an exhausted budget is unverified'
	Assert-True ((Get-FailureCategories $budgetData) -contains 'decode_budget_exhausted') 'decode_budget_exhausted is named in failures[]'
	Assert-True ($budgetData.decode_summary.budget_exhausted -eq $true) 'the summary states the budget ran out'
	Assert-True ($budgetData.decode_summary.frames_in_range -eq 6) 'the summary counts the frames in range'
	Assert-True (($budgetData.decode_summary.frames_evaluated + $budgetData.decode_summary.frames_not_evaluated) -eq 6) 'evaluated and not-evaluated frames add up to the frames in range'
	Assert-True ($budgetData.decode_summary.frames_not_evaluated -ge 1) 'at least one frame is reported as not evaluated'

	# A generous budget changes nothing: a clean sequence still passes and nothing is exhausted.
	$roomyDir = Join-Path $fixtureRoot 'budget-roomy'
	New-FrameSequence -Directory $roomyDir -Start 5 -EndExclusive 6
	Register-FixtureSnapshot 'budget-roomy'
	$roomyReport = New-ReportPath 'decode-budget-roomy'
	$roomyResult = Invoke-Measure @{
		FramesDirectory                = $roomyDir
		StartNumber                    = 5
		EndNumberExclusive             = 6
		ReportPath                     = $roomyReport
		ExpectedWidth                  = 64
		ExpectedHeight                 = 48
		DecoderPath                    = $stubDecoder
		TotalDecodeBudgetMilliseconds  = 120000
	}
	Assert-True ($roomyResult.ExitCode -eq 0) "a clean sequence inside a generous budget passes, got $($roomyResult.ExitCode): $($roomyResult.Output)"
	$roomyData = Read-Report $roomyReport
	Assert-True ($roomyData.decode_summary.budget_exhausted -eq $false -and $roomyData.decode_summary.frames_not_evaluated -eq 0) 'a generous budget is not exhausted'
	Register-Group 'decode-failure-outranks-timeout-timeouts' 'a decode failure outranks a timeout, timeouts are retried once with attempts recorded, and a total budget is explicit'

	# ============================================================ group 11c: input stability while the decoder runs (DOT-3403)
	# The helper hashes each frame, then decodes it. Something else writing into the directory in
	# between used to leave a report whose sha256 named the old bytes while decode/size described the
	# new ones, and whose verdict was still pass. A stub decoder stands in for that other writer: the
	# first time it is asked about 000001.png it replaces, adds or deletes a file that was already
	# hashed. These fixtures are mutated on purpose, so they live under one declared root entry and are
	# not registered with the untouched-input gate.
	$unstableRoot = Join-Path $fixtureRoot 'unstable-inputs'
	[System.IO.Directory]::CreateDirectory($unstableRoot) | Out-Null
	Register-FixtureRootFile 'unstable-inputs'
	$mutatingDecoder = Join-Path $unstableRoot 'mutating-decoder.cmd'
	$mutatingLines = @(
		'@echo off',
		'setlocal',
		'if "%~1"=="-version" goto version',
		'set "LAST="',
		'for %%a in (%*) do set "LAST=%%~nxa"',
		'if "%LAST%"=="000001.png" if defined STUB_MUTATE if not exist "%STUB_MUTATE_FLAG%" goto mutate',
		':good',
		'echo {"streams":[{"codec_name":"png"}],"frames":[{"width":64,"height":48,"pix_fmt":"rgb24"}]}',
		'exit /b 0',
		':mutate',
		'echo x>"%STUB_MUTATE_FLAG%"',
		'if "%STUB_MUTATE%"=="replace" copy /y "%STUB_MUTATE_SOURCE%" "%STUB_MUTATE_DIR%\000000.png" >nul',
		'if "%STUB_MUTATE%"=="add" copy /y "%STUB_MUTATE_SOURCE%" "%STUB_MUTATE_DIR%\000099.png" >nul',
		'if "%STUB_MUTATE%"=="delete" del /q "%STUB_MUTATE_DIR%\000000.png"',
		'goto good',
		':version',
		'echo mutating-stub 1.0',
		'exit /b 0'
	)
	[System.IO.File]::WriteAllText($mutatingDecoder, (($mutatingLines -join "`r`n") + "`r`n"), [System.Text.UTF8Encoding]::new($false))
	$mutationSource = Join-Path $unstableRoot 'replacement-source.png'
	[System.IO.File]::WriteAllBytes($mutationSource, (New-FixturePng -Width 64 -Height 48 -Shade 199))

	function Invoke-StabilityCase([string]$Label, [string]$Mutation) {
		$caseDir = Join-Path $unstableRoot ('seq-' + $Label)
		New-FrameSequence -Directory $caseDir -Start 0 -EndExclusive 3
		$beforeSnapshot = Get-DirectorySnapshot $caseDir
		$originalHash = (Get-FileHash -LiteralPath (Join-Path $caseDir '000000.png') -Algorithm SHA256).Hash.ToLowerInvariant()
		$reportPath = New-ReportPath ('stability-' + $Label)
		if ($Mutation -ne '') {
			$env:STUB_MUTATE = $Mutation
			$env:STUB_MUTATE_DIR = $caseDir
			$env:STUB_MUTATE_SOURCE = $mutationSource
			$env:STUB_MUTATE_FLAG = Join-Path $unstableRoot ('flag-' + $Label)
		}
		try {
			$result = Invoke-Measure @{
				FramesDirectory    = $caseDir
				StartNumber        = 0
				EndNumberExclusive = 3
				ReportPath         = $reportPath
				ExpectedWidth      = 64
				ExpectedHeight     = 48
				DecoderPath        = $mutatingDecoder
			}
		} finally {
			Remove-Item Env:\STUB_MUTATE, Env:\STUB_MUTATE_DIR, Env:\STUB_MUTATE_SOURCE, Env:\STUB_MUTATE_FLAG -ErrorAction SilentlyContinue
		}
		return [pscustomobject]@{
			Result = $result
			Data = (Read-Report $reportPath)
			Dir = $caseDir
			OriginalHash = $originalHash
			UnchangedByHelper = ($beforeSnapshot -ceq (Get-DirectorySnapshot $caseDir))
		}
	}

	$stableCase = Invoke-StabilityCase 'stable' ''
	Assert-True ($stableCase.Result.ExitCode -eq 0) "an input that does not change during the check still passes, got $($stableCase.Result.ExitCode): $($stableCase.Result.Output)"
	Assert-True ($stableCase.Data.checks.input_stability -eq 'pass') 'an unchanged input records input_stability=pass'
	Assert-True ($stableCase.Data.input_stability.state -eq 'pass' -and $stableCase.Data.input_stability.rescanned -eq $true) 'the report says the directory was re-checked after decoding'
	Assert-True ($stableCase.Data.input_stability.frames_rehashed -eq 3) 'every in-range frame was hashed again after decoding'
	Assert-True ($stableCase.UnchangedByHelper) 'the helper did not modify an unchanged input'

	$replaceCase = Invoke-StabilityCase 'replace' 'replace'
	Assert-True ($replaceCase.Result.ExitCode -eq 1) "a frame replaced during the check exits 1 (fail), got $($replaceCase.Result.ExitCode): $($replaceCase.Result.Output)"
	Assert-True ($replaceCase.Data.artifact_verdict -eq 'fail') 'a replaced frame can never produce a pass'
	Assert-True ($replaceCase.Data.checks.input_stability -eq 'fail') 'a replaced frame fails input_stability'
	Assert-True ((Get-FailureCategories $replaceCase.Data) -contains 'input_changed_during_check') 'the change is named in failures[]'
	$replacedEntry = @($replaceCase.Data.input_stability.changed | Where-Object { $_.file -eq '000000.png' })
	Assert-True ($replacedEntry.Count -eq 1) 'the replaced file is named in input_stability.changed'
	Assert-True ($replacedEntry[0].sha256_before -eq $replaceCase.OriginalHash -and $replacedEntry[0].sha256_after -ne $replaceCase.OriginalHash) 'the sample carries the digest from before and after the check'
	Assert-True ($replaceCase.Data.frames[0].sha256 -eq $replaceCase.OriginalHash) 'frames[].sha256 stays the digest read at inspection time, so the report shows what it describes'

	$addCase = Invoke-StabilityCase 'add' 'add'
	Assert-True ($addCase.Result.ExitCode -eq 1) "a file added during the check exits 1 (fail), got $($addCase.Result.ExitCode): $($addCase.Result.Output)"
	Assert-True ($addCase.Data.checks.input_stability -eq 'fail' -and $addCase.Data.artifact_verdict -eq 'fail') 'an added file fails input_stability'
	Assert-True (@($addCase.Data.input_stability.added) -contains '000099.png') 'the added file is named in input_stability.added'

	$deleteCase = Invoke-StabilityCase 'delete' 'delete'
	Assert-True ($deleteCase.Result.ExitCode -eq 1) "a file deleted during the check exits 1 (fail), got $($deleteCase.Result.ExitCode): $($deleteCase.Result.Output)"
	Assert-True ($deleteCase.Data.checks.input_stability -eq 'fail' -and $deleteCase.Data.artifact_verdict -eq 'fail') 'a deleted file fails input_stability'
	Assert-True (@($deleteCase.Data.input_stability.removed) -contains '000000.png') 'the removed file is named in input_stability.removed'
	Write-Output 'PASS: an input that is replaced, added to or deleted from while the decoder runs is recorded and never passes'

	# ============================================================ group 12: the untouched-input gate can actually fail
	# A gate that has never been observed to fail is the same defect one level up. This group corrupts a
	# throwaway fixture in each of the three ways a suite regression would - a removed file, a rewritten
	# file, an added file - and requires the gate to name every path. It then restores the fixture and
	# requires the gate to fall silent, so a fixed-but-vacuous gate cannot pass this group either.
	# It also corrupts an ignored Production/ path, because `git status --untracked-files=all` never
	# reports an entry under Production/* and the checkout comparison at the end of the suite cannot.
	$probeDir = Join-Path $fixtureRoot 'gate-probe'
	New-FrameSequence -Directory $probeDir -Start 0 -EndExclusive 3
	Register-FixtureSnapshot 'gate-probe'
	$probeFile = Join-Path $probeDir '000001.png'
	$probeOriginal = [System.IO.File]::ReadAllBytes($probeFile)
	$residueProbe = Join-Path $productionRoot '.render-artifacts-test-residue-probe'
	try {
		Remove-Item -LiteralPath (Join-Path $probeDir '000000.png') -Force
		[System.IO.File]::WriteAllBytes($probeFile, [byte[]](1, 2, 3, 4))
		[System.IO.File]::WriteAllText((Join-Path $probeDir 'MUTATED.txt'), 'injected', [System.Text.UTF8Encoding]::new($false))
		[System.IO.File]::WriteAllText((Join-Path $fixtureRoot 'STRAY-ROOT.txt'), 'injected', [System.Text.UTF8Encoding]::new($false))
		[System.IO.Directory]::CreateDirectory((Join-Path $residueProbe 'reports')) | Out-Null
		[System.IO.File]::WriteAllText((Join-Path $residueProbe 'reports\001-clean240.json'), '{}', [System.Text.UTF8Encoding]::new($false))

		$probeDrift = @(Get-FixtureInputDrift | Where-Object { $_.StartsWith('gate-probe/') })
		$probeText = $probeDrift -join '; '
		Assert-True ($probeDrift.Count -eq 3) "the gate reports each corruption exactly once, got $($probeDrift.Count): $probeText"
		Assert-True ($probeText.Contains('gate-probe/000000.png : removed')) "the gate names the removed file, got: $probeText"
		Assert-True ($probeText.Contains('gate-probe/000001.png : content changed')) "the gate names the rewritten file, got: $probeText"
		Assert-True ($probeText.Contains('gate-probe/MUTATED.txt : added')) "the gate names the added file, got: $probeText"
		$rootDrift = @(Get-FixtureRootDrift)
		Assert-True (($rootDrift -join '; ').Contains('STRAY-ROOT.txt')) "the gate names an unexpected fixture-root entry, got: $($rootDrift -join '; ')"
		$residueDrift = @(Get-ProductionResidue)
		Assert-True (($residueDrift -join '; ').Contains('.render-artifacts-test-residue-probe')) "the residue check names an ignored Production/ leftover that git status does not report, got: $($residueDrift -join '; ')"

		$gateFailed = $false
		$gateMessage = ''
		try { Assert-FixtureInputsUnchanged } catch { $gateFailed = $true; $gateMessage = $_.Exception.Message }
		Assert-True $gateFailed 'the aggregate gate throws instead of reporting success while an input changed'
		Assert-True ($gateMessage.Contains('gate-probe/000000.png') -and $gateMessage.Contains('STRAY-ROOT.txt')) "the aggregate gate failure names both the fixture and the root entry, got: $gateMessage"
	} finally {
		if (Test-Path -LiteralPath $residueProbe) { Remove-Item -LiteralPath $residueProbe -Recurse -Force }
		if (Test-Path -LiteralPath (Join-Path $fixtureRoot 'STRAY-ROOT.txt')) { Remove-Item -LiteralPath (Join-Path $fixtureRoot 'STRAY-ROOT.txt') -Force }
		if (Test-Path -LiteralPath (Join-Path $probeDir 'MUTATED.txt')) { Remove-Item -LiteralPath (Join-Path $probeDir 'MUTATED.txt') -Force }
		if (-not (Test-Path -LiteralPath (Join-Path $probeDir '000000.png'))) { Add-Frame -Directory $probeDir -Index 0 }
		[System.IO.File]::WriteAllBytes($probeFile, $probeOriginal)
	}
	$restoredDrift = @(Get-FixtureInputDrift)
	Assert-True ($restoredDrift.Count -eq 0) ("the gate is silent again once the corrupted fixture is restored, got: " + ($restoredDrift -join '; '))
	$restoredRootDrift = @(Get-FixtureRootDrift)
	Assert-True ($restoredRootDrift.Count -eq 0) ("the gate reports no unexpected fixture-root entry once it is removed, got: " + ($restoredRootDrift -join '; '))
	Assert-True (@(Get-ProductionResidue).Count -eq 0) 'the residue check is silent again once the ignored leftover is removed'
	Register-Group 'untouched-input-gate-names-removed' 'the untouched-input gate names removed, rewritten and added files and the ignored Production/ leftover, and is silent when they are restored'

	# ============================================================ group 13: the FramesDirectory guard alone is load-bearing
	# The junction case above isolates the report-parent guard: the sequence is a plain directory and the
	# report path is aliased into it. This group isolates the other half of that pair. The sequence is
	# reached through a junction alias while the report parent is the real, plain directory, so the
	# report-parent guard only ever sees a normal path and the refusal can come from
	# Assert-NoReparsePointInPath on FramesDirectory alone. Without that guard the inspector resolves the
	# alias, finds the report outside the alias string prefix, and writes it into the inspected sequence -
	# the exact single-guard mutation the acceptance criteria inject. A refusal that names the
	# "ReportPath parent" role instead means the guard under test is gone and the other one answered.
	$guardProbeRoot = Join-Path $fixtureRoot 'guard-probe'
	$guardRealFrames = Join-Path $guardProbeRoot 'real-frames'
	New-FrameSequence -Directory $guardRealFrames -Start 0 -EndExclusive 6
	Register-FixtureSnapshot 'guard-probe/real-frames'
	Register-FixtureRootFile 'guard-probe'
	$guardAlias = Join-Path $guardProbeRoot 'alias'
	$escapedReport = Join-Path $guardRealFrames 'escaped-report.json'
	$guardFramesBefore = Get-DirectorySnapshot $guardRealFrames
	try {
		New-Item -ItemType Junction -Path $guardAlias -Target $guardRealFrames -ErrorAction Stop | Out-Null

		$plainReport = New-ReportPath 'guard-probe-plain'
		$plainResult = Invoke-Measure @{
			FramesDirectory    = $guardRealFrames
			StartNumber        = 0
			EndNumberExclusive = 6
			ReportPath         = $plainReport
			ExpectedWidth      = 64
			ExpectedHeight     = 48
		}
		Assert-True (-not $plainResult.Threw) "a plain sequence with a plain report parent passes the guards: $($plainResult.Error)"
		Assert-True ($plainResult.ExitCode -eq 0) "the guarded plain case exits 0, got $($plainResult.ExitCode): $($plainResult.Output)"
		Assert-True (-not (Test-Path -LiteralPath $escapedReport)) 'the guarded plain case wrote nothing into the inspected directory'
		Assert-True ((Get-DirectorySnapshot $guardRealFrames) -ceq $guardFramesBefore) 'the guarded plain case left the inspected directory unchanged'

		$aliasResult = Invoke-Measure @{
			FramesDirectory    = $guardAlias
			StartNumber        = 0
			EndNumberExclusive = 6
			ReportPath         = $escapedReport
			ExpectedWidth      = 64
			ExpectedHeight     = 48
		}
		Assert-True ($aliasResult.ExitCode -eq 3 -and -not $aliasResult.Threw) 'a junction alias as FramesDirectory is refused before the sequence is inspected'
		Assert-True ($aliasResult.Output.Contains('FramesDirectory path contains a reparse point')) "the refusal comes from the FramesDirectory guard, not the report-parent guard, got: $($aliasResult.Output)"
		Assert-True (-not (Test-Path -LiteralPath $escapedReport)) 'the refused alias wrote no report through the junction into the inspected directory'
		Assert-True ((Get-DirectorySnapshot $guardRealFrames) -ceq $guardFramesBefore) 'the refused alias left every inspected frame name and hash unchanged'
	} finally {
		# Keep the test safe and self-cleaning even when run against a mutation that writes through this alias.
		if (Test-Path -LiteralPath $escapedReport) { Remove-Item -LiteralPath $escapedReport -Force }
		if (Test-Path -LiteralPath $guardAlias) { [System.IO.Directory]::Delete($guardAlias, $false) }
	}
	Register-Group 'junction-alias-framesdirectory-refused-guard' 'a junction alias as FramesDirectory is refused by that guard alone, and the plain guarded case stays silent'

	# ============================================================ group 13: declared index lattice
	# MRQ's `Output Frame Step` writes every N-th frame, so a legitimate step render has a gap after
	# every frame. The helper has to be able to declare that lattice and pass it, and it has to name a
	# mismatch as a lattice mismatch instead of reporting hundreds of "missing" frames.
	$stepDir = Join-Path $fixtureRoot 'lattice-step2'
	New-FrameLattice -Directory $stepDir -First 0 -Count 120 -Step 2
	Register-FixtureSnapshot 'lattice-step2'
	$stepBefore = Get-DirectorySnapshot $stepDir
	$stepReport = New-ReportPath 'lattice-step2'
	$stepResult = Invoke-Measure @{
		FramesDirectory    = $stepDir
		StartNumber        = 0
		EndNumberExclusive = 240
		FrameStep          = 2
		ReportPath         = $stepReport
		ExpectedWidth      = 64
		ExpectedHeight     = 48
	}
	Assert-True (-not $stepResult.Threw) "step lattice inspection did not throw: $($stepResult.Error)"
	Assert-True ($stepResult.ExitCode -eq 0) "a declared step-2 lattice exits 0, got $($stepResult.ExitCode): $($stepResult.Output)"
	$stepData = Read-Report $stepReport
	Assert-True ($stepData.artifact_verdict -eq 'pass') 'a declared step-2 lattice passes the artifact verdict'
	foreach ($check in @('composition', 'naming', 'completeness', 'range', 'file_size', 'decode', 'resolution')) {
		Assert-True ($stepData.checks.$check -eq 'pass') "step lattice check '$check' is pass, got '$($stepData.checks.$check)'"
	}
	Assert-True ($stepData.expectations.frame_count -eq 120) 'the report expects the 120 lattice indices, not the 240 contiguous ones'
	Assert-True ($stepData.expectations.first_index -eq 0) 'the report records the first lattice index'
	Assert-True ($stepData.expectations.last_index -eq 238) 'the report records the last lattice index'
	Assert-True ($stepData.expectations.frame_step -eq 2) 'the report records the declared frame step'
	Assert-True ($stepData.input.frame_step -eq 2 -and $stepData.input.frame_number_offset -eq 0) 'the report input records the declared step and offset'
	Assert-True ($stepData.index_lattice.declared_step -eq 2) 'the report records the declared stride'
	Assert-True ($stepData.index_lattice.observed_stride -eq 2) 'the report records the observed stride'
	Assert-True ($stepData.index_lattice.mismatch -eq $false) 'a matching lattice is not reported as a mismatch'
	Assert-True (@($stepData.failures).Count -eq 0) 'a declared step-2 lattice records no failure'
	Assert-True (@($stepData.frames).Count -eq 120) 'every lattice frame is inspected'
	Assert-True ($stepData.observed.contract_file_count -eq 120) 'the report counts the 120 lattice frames'
	Assert-True ((Get-DirectorySnapshot $stepDir) -ceq $stepBefore) 'the step lattice inspection left every file unchanged'

	# The same fixture inspected without the declaration must not be called 120 missing frames.
	$stepUndeclaredReport = New-ReportPath 'lattice-step2-undeclared'
	$stepUndeclaredResult = Invoke-Measure @{
		FramesDirectory    = $stepDir
		StartNumber        = 0
		EndNumberExclusive = 240
		ReportPath         = $stepUndeclaredReport
		ExpectedWidth      = 64
		ExpectedHeight     = 48
	}
	Assert-True ($stepUndeclaredResult.ExitCode -eq 1) "an undeclared step-2 lattice exits 1, got $($stepUndeclaredResult.ExitCode): $($stepUndeclaredResult.Output)"
	$stepUndeclaredData = Read-Report $stepUndeclaredReport
	Assert-True ($stepUndeclaredData.artifact_verdict -eq 'fail') 'an undeclared step-2 lattice fails'
	Assert-True ($stepUndeclaredData.index_lattice.mismatch -eq $true) 'the report records the lattice mismatch'
	Assert-True ($stepUndeclaredData.index_lattice.observed_stride -eq 2) 'the report names the observed stride'
	$undeclaredCategories = Get-FailureCategories $stepUndeclaredData
	Assert-True ($undeclaredCategories -contains 'index_lattice_mismatch') 'the undeclared lattice is reported as a lattice mismatch'
	Assert-True (-not ($undeclaredCategories -contains 'missing_frames')) 'the undeclared lattice is not reported as missing frames'
	Assert-True (-not ($undeclaredCategories -contains 'out_of_range_frames')) 'the undeclared lattice has no out-of-range frames'
	$undeclaredFailure = @($stepUndeclaredData.failures | Where-Object { $_.category -eq 'index_lattice_mismatch' })[0]
	Assert-True ($undeclaredFailure.detail.Contains('advance by 2')) 'the mismatch names the observed stride'
	Assert-True ($undeclaredFailure.detail.Contains('declared frame step is 1')) 'the mismatch names the declared step'
	Assert-True ($undeclaredFailure.detail.Contains('-FrameStep 2')) 'the mismatch names the declaration that would match'
	Assert-True ($stepUndeclaredData.checks.completeness -eq 'fail') 'the absent declared indices still fail completeness'
	Assert-True ($stepUndeclaredData.checks.range -eq 'pass') 'a lattice inside the declared range has no excess frames'
	Register-Group 'declared-step-2-lattice-passes' 'a declared step-2 lattice passes and the same lattice undeclared is named as a lattice mismatch'

	# A frame-number offset shifts the lattice. MRQ's `Frame Number Offset` produces this shape.
	$offsetLatticeDir = Join-Path $fixtureRoot 'lattice-offset10'
	New-FrameLattice -Directory $offsetLatticeDir -First 10 -Count 120 -Step 2
	Register-FixtureSnapshot 'lattice-offset10'
	$offsetLatticeReport = New-ReportPath 'lattice-offset10'
	$offsetLatticeResult = Invoke-Measure @{
		FramesDirectory    = $offsetLatticeDir
		StartNumber        = 0
		EndNumberExclusive = 240
		FrameStep          = 2
		FrameNumberOffset  = 10
		ReportPath         = $offsetLatticeReport
		ExpectedWidth      = 64
		ExpectedHeight     = 48
	}
	Assert-True ($offsetLatticeResult.ExitCode -eq 0) "a declared offset lattice exits 0, got $($offsetLatticeResult.ExitCode): $($offsetLatticeResult.Output)"
	$offsetLatticeData = Read-Report $offsetLatticeReport
	Assert-True ($offsetLatticeData.artifact_verdict -eq 'pass') 'the offset lattice passes the artifact verdict'
	Assert-True ($offsetLatticeData.expectations.first_index -eq 10) 'the report expects the offset first index'
	Assert-True ($offsetLatticeData.expectations.last_index -eq 248) 'the report expects the offset last index'
	Assert-True ($offsetLatticeData.input.frame_number_offset -eq 10) 'the report records the declared offset'
	Assert-True (@($offsetLatticeData.failures).Count -eq 0) 'the offset lattice records no failure'

	# The reverse direction: a contiguous run declared as a step lattice is also a mismatch. Without
	# this, the check would only be proven in the direction the defect was found.
	$contiguousDir = Join-Path $fixtureRoot 'lattice-contiguous-declared-step2'
	New-FrameLattice -Directory $contiguousDir -First 0 -Count 120 -Step 1
	Register-FixtureSnapshot 'lattice-contiguous-declared-step2'
	$contiguousReport = New-ReportPath 'lattice-contiguous-declared-step2'
	$contiguousResult = Invoke-Measure @{
		FramesDirectory    = $contiguousDir
		StartNumber        = 0
		EndNumberExclusive = 240
		FrameStep          = 2
		ReportPath         = $contiguousReport
		ExpectedWidth      = 64
		ExpectedHeight     = 48
	}
	Assert-True ($contiguousResult.ExitCode -eq 1) "a contiguous run against a declared step-2 lattice exits 1, got $($contiguousResult.ExitCode): $($contiguousResult.Output)"
	$contiguousData = Read-Report $contiguousReport
	Assert-True ((Get-FailureCategories $contiguousData) -contains 'index_lattice_mismatch') 'a contiguous run against a step declaration is a lattice mismatch'
	Assert-True (-not ((Get-FailureCategories $contiguousData) -contains 'missing_frames')) 'the contiguous run is not reported as missing frames'
	Assert-True ($contiguousData.index_lattice.observed_stride -eq 1) 'the report names the observed contiguous stride'

	# Handle frames extend a shot by a few frames on both sides. They are contiguous, so they are
	# reported as frames outside the declared range rather than as a lattice mismatch; the documented
	# handling is to widen the declared range when the handles belong to the deliverable.
	$handleDir = Join-Path $fixtureRoot 'lattice-handles'
	New-FrameLattice -Directory $handleDir -First 5 -Count 250 -Step 1
	Register-FixtureSnapshot 'lattice-handles'
	$handleReport = New-ReportPath 'lattice-handles'
	$handleResult = Invoke-Measure @{
		FramesDirectory    = $handleDir
		StartNumber        = 10
		EndNumberExclusive = 250
		ReportPath         = $handleReport
		ExpectedWidth      = 64
		ExpectedHeight     = 48
	}
	Assert-True ($handleResult.ExitCode -eq 1) "handle frames outside the declared range exit 1, got $($handleResult.ExitCode): $($handleResult.Output)"
	$handleData = Read-Report $handleReport
	$handleCategories = Get-FailureCategories $handleData
	Assert-True ($handleCategories -contains 'out_of_range_frames') 'handle frames are reported as outside the declared range'
	Assert-True (-not ($handleCategories -contains 'index_lattice_mismatch')) 'contiguous handle frames are not called a lattice mismatch'
	Assert-True ($handleData.index_lattice.mismatch -eq $false) 'the handle fixture is a uniform contiguous lattice'
	Assert-True ((@($handleData.failures | Where-Object { $_.category -eq 'out_of_range_frames' })[0].sample) -eq '5,6,7,8,9,250,251,252,253,254') 'the out-of-range sample names every handle frame'
	Assert-True (@($handleData.violations.missing_indices).Count -eq 0) 'every declared index is present behind the handles'
	Register-Group 'declared-step-offset-lattices-pass' 'declared step and offset lattices pass, a mismatch in either direction is named, and handle frames stay out-of-range'

	# ============================================================ group 14: per-frame digests are real, and a fake one fails the suite
	# The clean and 0-byte groups above already hold every frames[] entry to the digest contract. This group
	# proves the contract can fail: it runs mutated copies of the helper that write a constant and an empty
	# digest while still claiming 'computed', and requires Get-DigestViolations to name the file and index of
	# each frame. A mutation that did not apply would pass vacuously, so each one is checked to differ from
	# the shipped source before it runs. The copies live under the fixture root, never in scripts/.
	$digestDir = Join-Path $fixtureRoot 'digest3'
	New-FrameSequence -Directory $digestDir -Start 1 -EndExclusive 4
	Register-FixtureSnapshot 'digest3'
	$digestBound = {
		param([string]$ReportPath)
		@{
			FramesDirectory    = $digestDir
			StartNumber        = 1
			EndNumberExclusive = 4
			ReportPath         = $ReportPath
			ExpectedWidth      = 64
			ExpectedHeight     = 48
		}
	}
	$digestReport = New-ReportPath 'digest3'
	$digestResult = Invoke-Measure (& $digestBound $digestReport)
	Assert-True ($digestResult.ExitCode -eq 0) "the three-frame digest fixture exits 0, got $($digestResult.ExitCode): $($digestResult.Output)"
	$digestData = Read-Report $digestReport
	Assert-True (@($digestData.frames).Count -eq 3) 'the digest fixture reports three frames'
	Assert-True (@(Get-DigestViolations $digestData $digestDir).Count -eq 0) 'the shipped helper writes real SHA-256 digests with digest_state computed'
	Assert-True (@($digestData.frames | Where-Object { $_.sha256 -match '^[0-9a-f]{64}$' }).Count -eq 3) 'each digest is 64 lowercase hex digits'

	$measureSource = [System.IO.File]::ReadAllText($measureScript)
	$realHashExpression = '(Get-FileHash -LiteralPath $fileInfo.FullName -Algorithm SHA256).Hash.ToLowerInvariant()'
	Assert-True ($measureSource.IndexOf($realHashExpression, [System.StringComparison]::Ordinal) -ge 0) 'the helper computes the per-frame digest with the expression the mutations replace'
	$mutantRoot = Join-Path $fixtureRoot 'mutants'
	Register-FixtureRootFile 'mutants'
	[System.IO.Directory]::CreateDirectory($mutantRoot) | Out-Null
	foreach ($mutation in @(
		@{ Name = 'constant'; Replacement = "'deadbeef'"; Expected = 'deadbeef' },
		@{ Name = 'empty'; Replacement = "''"; Expected = '' }
	)) {
		$mutantSource = $measureSource.Replace($realHashExpression, $mutation.Replacement)
		Assert-True ($mutantSource -cne $measureSource) "the '$($mutation.Name)' digest mutation changes the helper source"
		$mutantScript = Join-Path $mutantRoot ("measure-$($mutation.Name).ps1")
		[System.IO.File]::WriteAllText($mutantScript, $mutantSource, [System.Text.UTF8Encoding]::new($false))
		$mutantReport = New-ReportPath ("digest3-$($mutation.Name)")
		$mutantResult = Invoke-Measure (& $digestBound $mutantReport) -Script $mutantScript
		Assert-True (-not $mutantResult.Threw) "the '$($mutation.Name)' mutant ran: $($mutantResult.Error)"
		Assert-True ($mutantResult.ExitCode -eq 0) "the '$($mutation.Name)' mutant still reports an overall pass, which is the defect under test, got $($mutantResult.ExitCode): $($mutantResult.Output)"
		$mutantData = Read-Report $mutantReport
		Assert-True ($mutantData.artifact_verdict -eq 'pass') "the '$($mutation.Name)' mutant passes every other check, so only the digest assertion can catch it"
		$mutantViolations = @(Get-DigestViolations $mutantData $digestDir)
		$mutantText = $mutantViolations -join '; '
		Assert-True ($mutantViolations.Count -eq 3) "the '$($mutation.Name)' mutant is reported once per frame, got $($mutantViolations.Count): $mutantText"
		foreach ($expectedFrame in @(@('000001.png', 1), @('000002.png', 2), @('000003.png', 3))) {
			Assert-True ($mutantText.Contains("$($expectedFrame[0]) (index $($expectedFrame[1]))")) "the '$($mutation.Name)' mutant violation names $($expectedFrame[0]) at index $($expectedFrame[1]), got: $mutantText"
		}
	}
	Register-Group 'per-frame-digests-equal-real' 'per-frame digests equal the real SHA-256 with digest_state computed, a 0-byte frame follows the same rule, and a constant or empty digest fails by file and index'

	# ============================================================ group 15: MRQ's real file names
	# MRQ never writes a bare index. Its default is `<sequence_name>.<frame_number>` with a 4-digit pad
	# (legacy Output Setting) or `<sequence_name>.<layer_name>.<frame_number>` (Movie Graph). The helper
	# used to accept only `<digits>.png`, so a correct 240-frame MRQ sequence failed with 240 "missing"
	# frames. The prefix and width are now declared, and an undeclared prefixed sequence is named as a
	# naming-contract mismatch instead of as lost frames.
	$mrqDir = Join-Path $fixtureRoot 'mrq-legacy'
	New-FrameSequence -Directory $mrqDir -Start 0 -EndExclusive 240 -Prefix 'Shot0001.' -DigitCount 4
	Register-FixtureSnapshot 'mrq-legacy'
	$mrqBefore = Get-DirectorySnapshot $mrqDir
	Assert-True (@(Get-ChildItem -LiteralPath $mrqDir -File | Where-Object { $_.Name -match '^Shot0001\.[0-9]{4}\.png$' }).Count -eq 240) 'the legacy MRQ fixture holds 240 Shot0001.NNNN.png files'

	$mrqDeclaredReport = New-ReportPath 'mrq-legacy-declared'
	$mrqDeclaredResult = Invoke-Measure @{
		FramesDirectory    = $mrqDir
		StartNumber        = 0
		EndNumberExclusive = 240
		NamePrefix         = 'Shot0001.'
		Digits             = 4
		ReportPath         = $mrqDeclaredReport
		ExpectedWidth      = 64
		ExpectedHeight     = 48
	}
	Assert-True (-not $mrqDeclaredResult.Threw) "declared MRQ sequence did not throw: $($mrqDeclaredResult.Error)"
	Assert-True ($mrqDeclaredResult.ExitCode -eq 0) "a declared Shot0001.NNNN sequence exits 0, got $($mrqDeclaredResult.ExitCode): $($mrqDeclaredResult.Output)"
	$mrqDeclaredData = Read-Report $mrqDeclaredReport
	Assert-True ($mrqDeclaredData.artifact_verdict -eq 'pass') 'a declared MRQ legacy sequence passes the artifact verdict'
	foreach ($check in @('composition', 'naming', 'completeness', 'range', 'file_size', 'decode', 'resolution')) {
		Assert-True ($mrqDeclaredData.checks.$check -eq 'pass') "declared MRQ sequence check '$check' is pass, got '$($mrqDeclaredData.checks.$check)'"
	}
	Assert-True ($mrqDeclaredData.observed.contract_file_count -eq 240) 'the declared MRQ sequence counts all 240 frames'
	Assert-True ($mrqDeclaredData.input.name_prefix -eq 'Shot0001.' -and $mrqDeclaredData.input.digits -eq 4) 'the report records the declared prefix and width'
	Assert-True ($mrqDeclaredData.input.naming_contract -eq 'Shot0001.[4 digit zero-padded index].png') "the report names the real contract, got '$($mrqDeclaredData.input.naming_contract)'"
	Assert-True (@($mrqDeclaredData.failures).Count -eq 0) 'a declared MRQ sequence records no failure'

	# The falling side: the same 240 correct frames without the declaration. This used to read as
	# "240 missing frames" and send the reader to re-render.
	$mrqUndeclaredReport = New-ReportPath 'mrq-legacy-undeclared'
	$mrqUndeclaredResult = Invoke-Measure @{
		FramesDirectory    = $mrqDir
		StartNumber        = 0
		EndNumberExclusive = 240
		ReportPath         = $mrqUndeclaredReport
		ExpectedWidth      = 64
		ExpectedHeight     = 48
	}
	Assert-True ($mrqUndeclaredResult.ExitCode -eq 1) "an undeclared Shot0001.NNNN sequence exits 1, got $($mrqUndeclaredResult.ExitCode): $($mrqUndeclaredResult.Output)"
	$mrqUndeclaredData = Read-Report $mrqUndeclaredReport
	Assert-True ($mrqUndeclaredData.artifact_verdict -eq 'fail') 'an undeclared MRQ sequence fails'
	$mrqUndeclaredCategories = Get-FailureCategories $mrqUndeclaredData
	Assert-True ($mrqUndeclaredCategories -contains 'naming_contract_mismatch') 'the undeclared MRQ sequence is named as a naming-contract mismatch'
	Assert-True (-not ($mrqUndeclaredCategories -contains 'missing_frames')) 'the undeclared MRQ sequence is not reported as missing frames'
	Assert-True (-not ($mrqUndeclaredCategories -contains 'unexpected_name')) 'the 240 frames of the mismatched sequence are not also reported as unexpected names'
	$mrqMismatch = @($mrqUndeclaredData.failures | Where-Object { $_.category -eq 'naming_contract_mismatch' })[0]
	Assert-True ($mrqMismatch.detail.Contains("-NamePrefix 'Shot0001.' -Digits 4")) 'the mismatch names the declaration that would match'
	Assert-True ($mrqMismatch.detail.Contains('do not re-render')) 'the mismatch tells the reader this is not a render failure'
	Assert-True ($mrqUndeclaredData.naming_contract_mismatch.observed_count -eq 240) 'the report counts the 240 mismatched entries'
	Assert-True ($mrqUndeclaredData.naming_contract_mismatch.observed_prefix -eq 'Shot0001.' -and $mrqUndeclaredData.naming_contract_mismatch.observed_digits -eq 4) 'the report records the observed prefix and width'
	Assert-True ($mrqUndeclaredData.checks.naming -eq 'fail' -and $mrqUndeclaredData.checks.completeness -eq 'fail') 'the undeclared sequence still fails naming and completeness'
	Assert-True ($mrqUndeclaredData.checks.decode -ne 'fail') 'zero matched frames is not a decode failure; nothing was decoded'
	Assert-True ($mrqUndeclaredData.checks.resolution -ne 'fail') 'zero matched frames is not a resolution failure'
	Assert-True (@($mrqUndeclaredData.violations.decode_failures).Count -eq 0) 'no decode failure is recorded for an undeclared sequence'

	# A declaration that is only partly right must still fail, and must name what is actually there.
	$mrqWrongWidthReport = New-ReportPath 'mrq-legacy-wrong-width'
	$mrqWrongWidthResult = Invoke-Measure @{
		FramesDirectory    = $mrqDir
		StartNumber        = 0
		EndNumberExclusive = 240
		NamePrefix         = 'Shot0001.'
		Digits             = 6
		ReportPath         = $mrqWrongWidthReport
		ExpectedWidth      = 64
		ExpectedHeight     = 48
	}
	Assert-True ($mrqWrongWidthResult.ExitCode -eq 1) "a right prefix with the wrong width exits 1, got $($mrqWrongWidthResult.ExitCode): $($mrqWrongWidthResult.Output)"
	$mrqWrongWidthData = Read-Report $mrqWrongWidthReport
	Assert-True ((Get-FailureCategories $mrqWrongWidthData) -contains 'ambiguous_name') 'a right prefix with the wrong width is an ambiguous name, not a pass'
	Assert-True ($mrqWrongWidthData.artifact_verdict -eq 'fail') 'a wrong width does not pass'

	$mrqWrongPrefixReport = New-ReportPath 'mrq-legacy-wrong-prefix'
	$mrqWrongPrefixResult = Invoke-Measure @{
		FramesDirectory    = $mrqDir
		StartNumber        = 0
		EndNumberExclusive = 240
		NamePrefix         = 'Shot0002.'
		Digits             = 4
		ReportPath         = $mrqWrongPrefixReport
	}
	Assert-True ($mrqWrongPrefixResult.ExitCode -eq 1) "a wrong declared prefix exits 1, got $($mrqWrongPrefixResult.ExitCode): $($mrqWrongPrefixResult.Output)"
	$mrqWrongPrefixData = Read-Report $mrqWrongPrefixReport
	Assert-True ((Get-FailureCategories $mrqWrongPrefixData) -contains 'naming_contract_mismatch') 'a wrong declared prefix is a naming-contract mismatch'
	Assert-True ((@($mrqWrongPrefixData.failures | Where-Object { $_.category -eq 'naming_contract_mismatch' })[0].detail).Contains("prefix 'Shot0002.'")) 'the mismatch quotes the wrongly declared prefix'
	Assert-True ((Get-DirectorySnapshot $mrqDir) -ceq $mrqBefore) 'no MRQ-named file was renamed, repaired or added by any of these runs'

	# Movie Graph: `<sequence_name>.<layer_name>.<frame_number>`.
	$graphDir = Join-Path $fixtureRoot 'mrq-moviegraph'
	New-FrameSequence -Directory $graphDir -Start 0 -EndExclusive 240 -Prefix 'Shot0001.Deferred.' -DigitCount 4
	Register-FixtureSnapshot 'mrq-moviegraph'
	$graphDeclaredReport = New-ReportPath 'mrq-moviegraph-declared'
	$graphDeclaredResult = Invoke-Measure @{
		FramesDirectory    = $graphDir
		StartNumber        = 0
		EndNumberExclusive = 240
		NamePrefix         = 'Shot0001.Deferred.'
		Digits             = 4
		ReportPath         = $graphDeclaredReport
		ExpectedWidth      = 64
		ExpectedHeight     = 48
	}
	Assert-True ($graphDeclaredResult.ExitCode -eq 0) "a declared Movie Graph sequence exits 0, got $($graphDeclaredResult.ExitCode): $($graphDeclaredResult.Output)"
	Assert-True ((Read-Report $graphDeclaredReport).artifact_verdict -eq 'pass') 'a declared Movie Graph sequence passes the artifact verdict'
	$graphUndeclaredReport = New-ReportPath 'mrq-moviegraph-undeclared'
	$graphUndeclaredResult = Invoke-Measure @{
		FramesDirectory    = $graphDir
		StartNumber        = 0
		EndNumberExclusive = 240
		ReportPath         = $graphUndeclaredReport
		ExpectedWidth      = 64
		ExpectedHeight     = 48
	}
	Assert-True ($graphUndeclaredResult.ExitCode -eq 1) "an undeclared Movie Graph sequence exits 1, got $($graphUndeclaredResult.ExitCode): $($graphUndeclaredResult.Output)"
	$graphUndeclaredData = Read-Report $graphUndeclaredReport
	Assert-True ((Get-FailureCategories $graphUndeclaredData) -contains 'naming_contract_mismatch') 'an undeclared Movie Graph sequence is a naming-contract mismatch'
	Assert-True ($graphUndeclaredData.naming_contract_mismatch.observed_prefix -eq 'Shot0001.Deferred.') 'the report names the layer in the observed prefix'
	Assert-True (-not ((Get-FailureCategories $graphUndeclaredData) -contains 'missing_frames')) 'the undeclared Movie Graph sequence is not reported as missing frames'

	# The mismatch is not a catch-all: a prefix declaration against bare six-digit names has no
	# observed prefix to name, so it stays an unexpected-name failure, and a stray file beside a
	# prefixed sequence is still reported on its own.
	$barePrefixReport = New-ReportPath 'bare-with-prefix'
	$barePrefixResult = Invoke-Measure @{
		FramesDirectory    = $cleanDir
		StartNumber        = 0
		EndNumberExclusive = 240
		NamePrefix         = 'Shot0001.'
		ReportPath         = $barePrefixReport
	}
	Assert-True ($barePrefixResult.ExitCode -eq 1) "bare six-digit names against a declared prefix exit 1, got $($barePrefixResult.ExitCode): $($barePrefixResult.Output)"
	$barePrefixData = Read-Report $barePrefixReport
	Assert-True ((Get-FailureCategories $barePrefixData) -contains 'unexpected_name') 'bare names against a declared prefix are unexpected names'
	Assert-True (-not ((Get-FailureCategories $barePrefixData) -contains 'naming_contract_mismatch')) 'bare names have no prefix to name, so no mismatch is claimed'

	$strayPrefixDir = Join-Path $fixtureRoot 'mrq-legacy-stray'
	New-FrameSequence -Directory $strayPrefixDir -Start 0 -EndExclusive 6 -Prefix 'Shot0001.' -DigitCount 4
	[System.IO.File]::WriteAllText((Join-Path $strayPrefixDir 'notes.txt'), 'fixture note', [System.Text.UTF8Encoding]::new($false))
	Register-FixtureSnapshot 'mrq-legacy-stray'
	$strayPrefixReport = New-ReportPath 'mrq-legacy-stray'
	$strayPrefixResult = Invoke-Measure @{
		FramesDirectory    = $strayPrefixDir
		StartNumber        = 0
		EndNumberExclusive = 6
		ReportPath         = $strayPrefixReport
	}
	Assert-True ($strayPrefixResult.ExitCode -eq 1) "a stray file beside an undeclared prefixed sequence exits 1, got $($strayPrefixResult.ExitCode)"
	$strayPrefixCategories = Get-FailureCategories (Read-Report $strayPrefixReport)
	Assert-True ($strayPrefixCategories -contains 'naming_contract_mismatch') 'the prefixed sequence is still named as a mismatch beside a stray file'
	Assert-True ($strayPrefixCategories -contains 'unexpected_name') 'the stray file is still reported as an unexpected name'
	Register-Group 'mrq-legacy-movie-graph-names' 'MRQ legacy and Movie Graph names pass when declared, an undeclared prefix is a naming-contract mismatch rather than missing frames, and no input was renamed'

	# ============================================================ group 17: codec contract for non-PNG extensions
	# MRQ writes more than PNG (BMP/JPG/EXR output nodes), and -Extension accepts any of them. The codec
	# check used to run only for .png, so a .jpg sequence with one PNG frame in it passed every check.
	# The JPEG below is a real 64x48 baseline mjpeg frame (generated once with ffmpeg, embedded so the
	# suite needs no encoder); the "wrong codec" side reuses PNG bytes under a different extension.
	$jpegBytes = [Convert]::FromBase64String('/9j/4AAQSkZJRgABAgAAAQABAAD//gAQTGF2YzYyLjI4LjEwMgD/2wBDAAgQEBMQExYWFhYWFhoYGhsbGxoaGhobGxsdHR0iIiIdHR0bGx0dICAiIiUmJSMjIiMmJigoKDAwLi44ODpFRVP/xABKAAEAAAAAAAAAAAAAAAAAAAAAAQEAAAAAAAAAAAAAAAAAAAAAEAEAAAAAAAAAAAAAAAAAAAAAEQEAAAAAAAAAAAAAAAAAAAAA/8AAEQgAMABAAwEiAAIRAAMRAP/aAAwDAQACEQMRAD8AAAAAAAAAAAAAAAAAAAAAAAAA/9k=')
	function New-CodecFixture {
		param([string]$Name, [string]$Extension, [string[]]$Kinds)
		$dir = Join-Path $fixtureRoot $Name
		[System.IO.Directory]::CreateDirectory($dir) | Out-Null
		for ($i = 0; $i -lt $Kinds.Count; $i++) {
			$bytes = if ($Kinds[$i] -eq 'jpeg') { $jpegBytes } else { New-FixturePng -Width 64 -Height 48 -Shade ($i * 11) }
			[System.IO.File]::WriteAllBytes((Join-Path $dir ('{0:D6}{1}' -f $i, $Extension)), $bytes)
		}
		Register-FixtureSnapshot $Name
		return $dir
	}

	$jpgRealDir = New-CodecFixture -Name 'codec-jpg-real' -Extension '.jpg' -Kinds @('jpeg', 'jpeg', 'jpeg')
	$jpgRealReport = New-ReportPath 'codec-jpg-real'
	$jpgRealResult = Invoke-Measure @{
		FramesDirectory = $jpgRealDir; StartNumber = 0; EndNumberExclusive = 3; Extension = '.jpg'
		ReportPath = $jpgRealReport; ExpectedWidth = 64; ExpectedHeight = 48
	}
	Assert-True ($jpgRealResult.ExitCode -eq 0) "real mjpeg frames named .jpg exit 0, got $($jpgRealResult.ExitCode): $($jpgRealResult.Output)"
	$jpgRealData = Read-Report $jpgRealReport
	Assert-True ($jpgRealData.artifact_verdict -eq 'pass') 'real mjpeg .jpg frames pass'
	Assert-True ($jpgRealData.input.expected_codec -eq 'mjpeg' -and $jpgRealData.expectations.codec -eq 'mjpeg') 'the report records mjpeg as the codec expected for .jpg'
	Assert-True (@($jpgRealData.frames | Where-Object { $_.codec -eq 'mjpeg' }).Count -eq 3) 'every .jpg frame reports the mjpeg codec'
	Assert-True (@($jpgRealData.failures).Count -eq 0) 'a real .jpg sequence records no failure'

	$jpgMixedDir = New-CodecFixture -Name 'codec-jpg-mixed' -Extension '.jpg' -Kinds @('png', 'jpeg', 'jpeg')
	$jpgMixedReport = New-ReportPath 'codec-jpg-mixed'
	$jpgMixedResult = Invoke-Measure @{
		FramesDirectory = $jpgMixedDir; StartNumber = 0; EndNumberExclusive = 3; Extension = '.jpg'
		ReportPath = $jpgMixedReport; ExpectedWidth = 64; ExpectedHeight = 48
	}
	Assert-True ($jpgMixedResult.ExitCode -eq 1) "a .jpg sequence with one PNG frame exits 1, got $($jpgMixedResult.ExitCode): $($jpgMixedResult.Output)"
	$jpgMixedData = Read-Report $jpgMixedReport
	Assert-True ($jpgMixedData.artifact_verdict -eq 'fail') 'a mixed-codec .jpg sequence fails'
	Assert-True ((Get-FailureCategories $jpgMixedData) -contains 'codec_mismatch') 'the mixed-codec .jpg sequence names codec_mismatch'
	Assert-True ($jpgMixedData.checks.decode -eq 'fail') 'the decode check fails for the mixed-codec .jpg sequence'
	Assert-True (@($jpgMixedData.violations.codec_mismatches).Count -eq 1 -and $jpgMixedData.violations.codec_mismatches[0].file -eq '000000.jpg' -and $jpgMixedData.violations.codec_mismatches[0].codec -eq 'png') 'the odd frame is named with the codec it really decoded to'
	Assert-True (((@($jpgMixedData.frames | ForEach-Object { $_.codec })) -join ',') -eq 'png,mjpeg,mjpeg') 'the report keeps frames[].codec for each frame'

	$exrPngDir = New-CodecFixture -Name 'codec-exr-png' -Extension '.exr' -Kinds @('png')
	$exrPngReport = New-ReportPath 'codec-exr-png'
	$exrPngResult = Invoke-Measure @{
		FramesDirectory = $exrPngDir; StartNumber = 0; EndNumberExclusive = 1; Extension = '.exr'
		ReportPath = $exrPngReport; ExpectedWidth = 64; ExpectedHeight = 48
	}
	Assert-True ($exrPngResult.ExitCode -eq 1) "PNG bytes saved under an .exr name exit 1, got $($exrPngResult.ExitCode): $($exrPngResult.Output)"
	$exrPngData = Read-Report $exrPngReport
	Assert-True ($exrPngData.input.expected_codec -eq 'exr') 'the report records exr as the codec expected for .exr'
	Assert-True ((Get-FailureCategories $exrPngData) -contains 'codec_mismatch') 'PNG bytes under an .exr name are a codec mismatch'

	$tifDir = New-CodecFixture -Name 'codec-tif-unknown' -Extension '.tif' -Kinds @('png', 'png')
	$tifReport = New-ReportPath 'codec-tif-unknown'
	$tifResult = Invoke-Measure @{
		FramesDirectory = $tifDir; StartNumber = 0; EndNumberExclusive = 2; Extension = '.tif'
		ReportPath = $tifReport; ExpectedWidth = 64; ExpectedHeight = 48
	}
	Assert-True ($tifResult.ExitCode -eq 2) "an extension with no codec contract exits 2 (unverified), got $($tifResult.ExitCode): $($tifResult.Output)"
	$tifData = Read-Report $tifReport
	Assert-True ($tifData.artifact_verdict -eq 'unverified') 'an unknown extension is unverified, never pass'
	Assert-True ($tifData.checks.decode -eq 'unverified') 'the decode check stays unverified when the codec was not checked'
	Assert-True ($tifData.input.expected_codec -eq 'not_configured') 'the report says no codec was configured for the extension'
	Assert-True ((Get-FailureCategories $tifData) -contains 'codec_not_configured') 'an unknown extension names codec_not_configured'
	Assert-True ($tifData.checks.naming -eq 'pass' -and $tifData.checks.completeness -eq 'pass') 'the unknown extension is still accepted by the naming and completeness checks (not rejected)'
	Register-Group 'extension-carries-codec-contract-jpg' '-Extension carries a codec contract (.jpg mjpeg passes, a mixed or wrong-codec sequence fails by name, an unknown extension is unverified)'

	# ============================================================ group 15b: render exit code is judged, not only recorded
	# Before this group the helper recorded -RenderExitCode and ignored it: a declared exit 1 still
	# ended in VERDICT pass / exit 0 / no failure, and a non-numeric value was written into the report as
	# if it were an observed exit code. The fixture is the clean 240-frame sequence, so every image
	# sequence check passes and only the render argument differs between the cases below.
	$renderExitCases = @(
		@{ Label = 'exit1'; Args = @{ RenderExitCode = '1'; RenderNotification = 'MRQFAILED' }; State = 'fail'; Verdict = 'fail'; Exit = 1; Text = '1' },
		@{ Label = 'exit7'; Args = @{ RenderExitCode = '7' }; State = 'fail'; Verdict = 'fail'; Exit = 1; Text = '7' },
		@{ Label = 'exit-negative'; Args = @{ RenderExitCode = '-1' }; State = 'fail'; Verdict = 'fail'; Exit = 1; Text = '-1' },
		@{ Label = 'exit0'; Args = @{ RenderExitCode = '0'; RenderNotification = 'MRQOK' }; State = 'pass'; Verdict = 'pass'; Exit = 0; Text = '0' },
		@{ Label = 'exit0-padded'; Args = @{ RenderExitCode = ' 0 ' }; State = 'pass'; Verdict = 'pass'; Exit = 0; Text = '0' },
		@{ Label = 'not-given'; Args = @{}; State = 'unverified'; Verdict = 'unverified'; Exit = 2; Text = 'not_provided' },
		@{ Label = 'notification-only'; Args = @{ RenderNotification = 'MRQOK' }; State = 'unverified'; Verdict = 'unverified'; Exit = 2; Text = 'not_provided' },
		@{ Label = 'failure-wording-exit0'; Args = @{ RenderExitCode = '0'; RenderNotification = 'MRQ FAILED: render error' }; State = 'pass'; Verdict = 'pass'; Exit = 0; Text = '0' }
	)
	foreach ($renderExitCase in $renderExitCases) {
		$caseReport = New-ReportPath ('render-' + $renderExitCase.Label)
		$caseBound = @{
			FramesDirectory    = $cleanDir
			StartNumber        = 0
			EndNumberExclusive = 240
			ReportPath         = $caseReport
			ExpectedWidth      = 64
			ExpectedHeight     = 48
		}
		foreach ($caseKey in $renderExitCase.Args.Keys) { $caseBound[$caseKey] = $renderExitCase.Args[$caseKey] }
		$caseResult = Invoke-Measure $caseBound -NoDefaultRenderExit
		$caseLabel = "render case '$($renderExitCase.Label)'"
		Assert-True (-not $caseResult.Threw) "$caseLabel did not throw: $($caseResult.Error)"
		Assert-True ($caseResult.ExitCode -eq $renderExitCase.Exit) "$caseLabel exits $($renderExitCase.Exit), got $($caseResult.ExitCode): $($caseResult.Output)"
		$caseData = Read-Report $caseReport
		Assert-True ($caseData.artifact_verdict -eq $renderExitCase.Verdict) "$caseLabel artifact_verdict is $($renderExitCase.Verdict), got $($caseData.artifact_verdict)"
		Assert-True ($caseData.checks.render_exit -eq $renderExitCase.State) "$caseLabel checks.render_exit is $($renderExitCase.State), got $($caseData.checks.render_exit)"
		Assert-True ($caseData.render_evidence.exit_code -ceq $renderExitCase.Text) "$caseLabel records exit_code '$($renderExitCase.Text)', got '$($caseData.render_evidence.exit_code)'"
		Assert-True ($caseData.render_evidence.render_artifacts_cannot_prove_render_success -eq $true) "$caseLabel keeps the artifacts-cannot-prove-render-success note"
		Assert-True ($caseData.overall_qa_verdict -eq 'not_assessed') "$caseLabel does not become an overall QA verdict"
		foreach ($artifactCheck in @('composition', 'naming', 'completeness', 'range', 'file_size', 'decode', 'resolution')) {
			Assert-True ($caseData.checks.$artifactCheck -eq 'pass') "$caseLabel leaves the artifact check '$artifactCheck' at pass, got '$($caseData.checks.$artifactCheck)'"
		}
		$caseCategories = Get-FailureCategories $caseData
		if ($renderExitCase.State -eq 'fail') {
			Assert-True (@($caseCategories | Where-Object { $_ -eq 'render_exit_nonzero' }).Count -eq 1) "$caseLabel lists exactly one render_exit_nonzero failure"
			Assert-True (@($caseData.failures).Count -eq 1) "$caseLabel has no failure besides the render one, got $(@($caseData.failures).Count)"
			Assert-True ($caseData.render_evidence.conclusion -eq 'evaluated_from_exit_code') "$caseLabel concludes from the declared exit code"
			Assert-True ($caseResult.Output.Contains('render_exit=fail')) "$caseLabel prints render_exit=fail in the CHECKS line"
		} elseif ($renderExitCase.State -eq 'pass') {
			Assert-True (@($caseData.failures).Count -eq 0) "$caseLabel records no failure"
			Assert-True ($caseData.render_evidence.conclusion -eq 'evaluated_from_exit_code') "$caseLabel concludes from the declared exit code"
		} else {
			Assert-True ($caseCategories -contains 'render_exit_not_provided') "$caseLabel names render_exit_not_provided"
			Assert-True ($caseData.render_evidence.conclusion -eq 'not_provided') "$caseLabel records that no exit code was provided"
			Assert-True ($caseData.render_evidence.exit_code_provided -eq $false) "$caseLabel records exit_code_provided false"
		}
		if ($renderExitCase.Args.ContainsKey('RenderNotification')) {
			Assert-True ($caseData.render_evidence.notification -ceq $renderExitCase.Args['RenderNotification']) "$caseLabel records the notification text verbatim"
		}
	}

	# A value that is not an integer is rejected before any report exists. It exits 3, which is neither
	# the artifact fail (1) nor unverified (2), so it cannot be read as a verdict.
	foreach ($badExit in @('unknown', '1.5', '0x1', '1e3', '--1', '12345678901', 'exit code 0 (warning: none)')) {
		$badReport = New-ReportPath 'render-invalid'
		$script:refusedReportCounter++
		$badResult = Invoke-Measure @{
			FramesDirectory    = $cleanDir
			StartNumber        = 0
			EndNumberExclusive = 240
			ReportPath         = $badReport
			ExpectedWidth      = 64
			ExpectedHeight     = 48
			RenderExitCode     = $badExit
		} -NoDefaultRenderExit
		Assert-True ($badResult.ExitCode -eq 3) "RenderExitCode '$badExit' is rejected with exit 3, got $($badResult.ExitCode): $($badResult.Output)"
		Assert-True (-not (Test-Path -LiteralPath $badReport)) "RenderExitCode '$badExit' writes no report"
		Assert-True (-not $badResult.Output.Contains('VERDICT:')) "RenderExitCode '$badExit' prints no verdict"
		Assert-True ($badResult.Output.Contains('Invalid input: RenderExitCode')) "RenderExitCode '$badExit' is reported as invalid input, got: $($badResult.Output)"
	}
	Register-Group 'render-exit-code-judged-not-only-recorded' 'a declared non-zero render exit code fails the verdict and exit 1, 0 passes, no declaration or only a notification stays unverified, and a non-integer is rejected with exit 3 and no report'

	# ============================================================ group 15c: a re-inspection of the same run is written, not refused
	# docs/05-qa.md tells the agent to re-render a black or short sequence, and the helper refuses to
	# overwrite a report. With one fixed report path the second inspection of a run therefore wrote
	# nothing and the QA record kept pointing at the first, stale pass. The path now carries an attempt
	# number, so both inspections are written and the latest one describes the current frames.
	$rerunRoot = Join-Path $fixtureRoot 'rerun-run'
	$rerunFrames = Join-Path $rerunRoot 'frames'
	$rerunEvidence = Join-Path $rerunRoot 'evidence'
	New-FrameSequence -Directory $rerunFrames -Start 0 -EndExclusive 3
	[System.IO.Directory]::CreateDirectory($rerunEvidence) | Out-Null
	function Get-LatestAttemptReport([string]$EvidenceDirectory) {
		# The report for the current frames is the one with the highest attempt number.
		$candidates = @(Get-ChildItem -LiteralPath $EvidenceDirectory -File | Where-Object { $_.Name -match '^frames-check-(\d+)\.json$' })
		if ($candidates.Count -eq 0) { return $null }
		return ($candidates | Sort-Object -Property @{ Expression = { [int]($_.Name -replace '^frames-check-(\d+)\.json$', '$1') } } | Select-Object -Last 1)
	}
	$attemptArgs = @{ FramesDirectory = $rerunFrames; StartNumber = 0; EndNumberExclusive = 3; ExpectedWidth = 64; ExpectedHeight = 48; RunId = "fixture-$testId"; SourceRevision = 'fixture' }
	$attempt1Path = Join-Path $rerunEvidence 'frames-check-1.json'
	$attempt1Result = Invoke-Measure ($attemptArgs + @{ ReportPath = $attempt1Path })
	Assert-True ($attempt1Result.ExitCode -eq 0) "attempt 1 of the run exits 0, got $($attempt1Result.ExitCode): $($attempt1Result.Output)"
	$attempt1Data = Read-Report $attempt1Path
	Assert-True ($attempt1Data.artifact_verdict -eq 'pass' -and $attempt1Data.observed.contract_file_count -eq 3) 'attempt 1 records pass over 3 frames'
	$attempt1Hash = (Get-FileHash -LiteralPath $attempt1Path -Algorithm SHA256).Hash

	# The re-render produced a shorter sequence. Reusing attempt 1's path is refused with exit 3 and
	# leaves the stale pass untouched: exactly the situation the numbered path exists to avoid.
	Remove-Item -LiteralPath (Join-Path $rerunFrames '000002.png')
	$staleResult = Invoke-Measure ($attemptArgs + @{ ReportPath = $attempt1Path })
	Assert-True ($staleResult.ExitCode -eq 3) "writing the second inspection to the first report path is refused with exit 3, got $($staleResult.ExitCode)"
	Assert-True ((Get-FileHash -LiteralPath $attempt1Path -Algorithm SHA256).Hash -ceq $attempt1Hash) 'the refused second inspection left the first report untouched'
	Assert-True ((Read-Report $attempt1Path).observed.contract_file_count -ne @(Get-ChildItem -LiteralPath $rerunFrames -File).Count) 'the first report no longer describes the current frames, so it cannot be cited as their evidence'

	$attempt2Path = Join-Path $rerunEvidence 'frames-check-2.json'
	$attempt2Result = Invoke-Measure ($attemptArgs + @{ ReportPath = $attempt2Path })
	Assert-True ($attempt2Result.ExitCode -eq 1) "attempt 2 of the same run is written and fails the shorter sequence with exit 1, got $($attempt2Result.ExitCode): $($attempt2Result.Output)"
	$attempt2Data = Read-Report $attempt2Path
	Assert-True ($attempt2Data.artifact_verdict -eq 'fail') 'attempt 2 records the fail verdict of the current frames'
	Assert-True ($attempt2Data.observed.contract_file_count -eq 2) 'attempt 2 records the 2 frames that exist now'
	Assert-True (@($attempt2Data.failures).Count -gt 0) 'attempt 2 names the failure that the stale pass hid'
	Assert-True ($attempt2Data.generated_at_utc -and $attempt1Data.generated_at_utc) 'both reports carry generated_at_utc'
	Assert-True ((Get-FileHash -LiteralPath $attempt1Path -Algorithm SHA256).Hash -ceq $attempt1Hash) 'attempt 1 is kept as history, unchanged'
	$latestReport = Get-LatestAttemptReport $rerunEvidence
	Assert-True ($latestReport.Name -ceq 'frames-check-2.json') "the latest attempt is the report for the current frames, got $($latestReport.Name)"
	Assert-True ((Read-Report $latestReport.FullName).observed.contract_file_count -eq @(Get-ChildItem -LiteralPath $rerunFrames -File).Count) 'the latest report matches the frames on disk'
	Register-FixtureSnapshot 'rerun-run'

	# The rule lives in docs/05-qa.md once and the other documents point at it. Each case below breaks
	# one thing in a copy of the documents and has to be reported, so the check cannot decay into an
	# assertion that passes on any text.
	$citeRule = [regex]::Unescape('\u65e2\u5b58report\u3092\u73fe\u5728\u306eframes\u306e\u8a3c\u62e0\u3068\u3057\u3066\u5f15\u7528\u3057\u306a\u3044')
	$ruleSection = [regex]::Unescape('\u753b\u50cf\u5217\u691c\u67fb\u306e\u518d\u5b9f\u884c')
	$utf8Reader = [System.Text.Encoding]::UTF8
	$ruleDocs = [ordered]@{
		'docs/05-qa.md'                       = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'docs/05-qa.md'), $utf8Reader)
		'README.md'                           = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'README.md'), $utf8Reader)
		'templates/QA.md'                     = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'templates/QA.md'), $utf8Reader)
		'scripts/Get-UECaptureEncodePlan.ps1' = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'scripts/Get-UECaptureEncodePlan.ps1'), $utf8Reader)
	}
	function Get-ReportRuleProblems($Docs, [string]$CiteRule, [string]$RuleSection) {
		$problems = New-Object System.Collections.Generic.List[string]
		$ruleCount = 0
		foreach ($name in @($Docs.Keys)) {
			$text = [string]$Docs[$name]
			$ruleCount += ([regex]::Matches($text, [regex]::Escape($CiteRule))).Count
			if ($text.Contains('frames-check.json')) { $problems.Add("$name still names the single fixed frames-check.json path") }
			if (-not $text.Contains('frames-check-<attempt>.json')) { $problems.Add("$name does not name frames-check-<attempt>.json") }
		}
		if ($ruleCount -ne 1) { $problems.Add("the re-inspection rule appears $ruleCount times, expected exactly 1") }
		elseif (-not ([string]$Docs['docs/05-qa.md']).Contains($CiteRule)) { $problems.Add('the re-inspection rule is not in docs/05-qa.md') }
		foreach ($pointer in @('README.md', 'templates/QA.md')) {
			if (-not ([string]$Docs[$pointer]).Contains($RuleSection)) { $problems.Add("$pointer does not point at the re-inspection section") }
		}
		return $problems.ToArray()
	}
	$realRuleProblems = @(Get-ReportRuleProblems $ruleDocs $citeRule $ruleSection)
	Assert-True ($realRuleProblems.Count -eq 0) ('the documents state the re-inspection rule once and name the numbered path: ' + ($realRuleProblems -join '; '))
	$brokenCases = @(
		@{ Name = 'the rule sentence is broken'; File = 'docs/05-qa.md'; Edit = { param($t) $t.Replace($citeRule, 'rule removed') }; Needle = 'appears 0 times' },
		@{ Name = 'the rule is repeated in README.md'; File = 'README.md'; Edit = { param($t) $t + $citeRule }; Needle = 'appears 2 times' },
		@{ Name = 'README.md goes back to the single fixed path'; File = 'README.md'; Edit = { param($t) $t.Replace('frames-check-<attempt>.json', 'frames-check.json') }; Needle = 'README.md still names the single fixed' },
		@{ Name = 'the QA template goes back to the single fixed path'; File = 'templates/QA.md'; Edit = { param($t) $t.Replace('frames-check-<attempt>.json', 'frames-check.json') }; Needle = 'templates/QA.md still names the single fixed' },
		@{ Name = 'the plan script goes back to the single fixed path'; File = 'scripts/Get-UECaptureEncodePlan.ps1'; Edit = { param($t) $t.Replace('frames-check-<attempt>.json', 'frames-check.json') }; Needle = 'scripts/Get-UECaptureEncodePlan.ps1 still names the single fixed' },
		@{ Name = 'the QA template stops pointing at the section'; File = 'templates/QA.md'; Edit = { param($t) $t.Replace($ruleSection, 'removed') }; Needle = 'templates/QA.md does not point at the re-inspection section' }
	)
	foreach ($brokenCase in $brokenCases) {
		$brokenDocs = [ordered]@{}
		foreach ($name in @($ruleDocs.Keys)) { $brokenDocs[$name] = $ruleDocs[$name] }
		$brokenDocs[$brokenCase.File] = & $brokenCase.Edit $ruleDocs[$brokenCase.File]
		$brokenProblems = @(Get-ReportRuleProblems $brokenDocs $citeRule $ruleSection)
		Assert-True (($brokenProblems -join '; ').Contains($brokenCase.Needle)) "the rule check fails when $($brokenCase.Name), got: $($brokenProblems -join '; ')"
	}
	Register-Group 'same-run-reinspection-numbered-report-rule' 'a second inspection of the same run is written to its own numbered report and describes the current frames, the first report is kept as history, and the single documented rule fails when it is broken or repeated'
	# ============================================================ group 15d: identical frames across files (DOT-3453)
	# docs/05-qa.md says not to produce duplicate frames, yet 240 byte-identical frames used to pass
	# every check. The helper now counts distinct digests from the frames[].sha256 it already computes.
	# Whether identical frames are a defect is the caller's declaration, so frame_variety stays
	# unverified by default and only a declaration produces pass or fail. The decoder is left missing in
	# the cheap runs because this group is about digests, not pictures; one real-decoder run of a
	# distinct sequence proves the positive case exits 0.
	function New-ShadeSequence {
		# One frame per entry of Shades: the same shade is the same bytes, a different shade is not.
		param([string]$Directory, [int[]]$Shades)
		[System.IO.Directory]::CreateDirectory($Directory) | Out-Null
		$cache = @{}
		for ($i = 0; $i -lt $Shades.Count; $i++) {
			$shade = $Shades[$i]
			if (-not $cache.ContainsKey($shade)) { $cache[$shade] = New-FixturePng -Width 64 -Height 48 -Shade $shade }
			[System.IO.File]::WriteAllBytes((Join-Path $Directory ('{0:D6}.png' -f $i)), $cache[$shade])
		}
	}
	$noDecoder = Join-Path $fixtureRoot 'no-such-ffprobe.exe'
	$varietyBase = @{ StartNumber = 0; ExpectedWidth = 64; ExpectedHeight = 48; DecoderPath = $noDecoder; RunId = "fixture-$testId"; SourceRevision = 'fixture' }

	$frozenDir = Join-Path $fixtureRoot 'variety-frozen240'
	New-ShadeSequence -Directory $frozenDir -Shades @(1..240 | ForEach-Object { 7 })
	Register-FixtureSnapshot 'variety-frozen240'
	$mixedDir = Join-Path $fixtureRoot 'variety-mixed240'
	New-ShadeSequence -Directory $mixedDir -Shades @((1..239 | ForEach-Object { 7 }) + @(200))
	Register-FixtureSnapshot 'variety-mixed240'
	$runsDir = Join-Path $fixtureRoot 'variety-runs12'
	# A A A B B C D D D D E F: 6 distinct, groups of 3, 2 and 4 = 9 duplicate frames, longest run 4.
	New-ShadeSequence -Directory $runsDir -Shades @(10, 10, 10, 20, 20, 30, 40, 40, 40, 40, 50, 60)
	Register-FixtureSnapshot 'variety-runs12'
	$distinctDir = Join-Path $fixtureRoot 'variety-distinct240'
	New-ShadeSequence -Directory $distinctDir -Shades @(0..239)
	Register-FixtureSnapshot 'variety-distinct240'

	# Undeclared: the existing clean240 fixture only has 20 distinct frames (shade = index * 11 mod 220),
	# so it is itself a repetition. It still passes, frame_variety is unverified, and the counts show it.
	$cleanVariety = Read-Report $cleanReport
	Assert-True ($cleanVariety.artifact_verdict -eq 'pass') 'an undeclared frame_variety does not change the verdict of the existing clean sequence'
	Assert-True ($cleanVariety.checks.frame_variety -eq 'unverified') 'frame_variety is unverified by default'
	Assert-True ($cleanVariety.frame_variety_declaration -eq 'none') 'the report records that no declaration was made'
	Assert-True ($cleanVariety.observed.distinct_frame_hashes -eq 20 -and $cleanVariety.observed.hashed_frame_count -eq 240) "the clean fixture reports its 20 distinct digests over 240 frames, got $($cleanVariety.observed.distinct_frame_hashes)/$($cleanVariety.observed.hashed_frame_count)"
	Assert-True (@($cleanVariety.failures | Where-Object { $_.category -like 'frame_variety*' }).Count -eq 0) 'an undeclared frame_variety adds no failure entry'

	# Frozen: all 240 frames identical.
	$frozenArgs = $varietyBase + @{ FramesDirectory = $frozenDir; EndNumberExclusive = 240 }
	$frozenUndeclaredPath = New-ReportPath 'variety-frozen-undeclared'
	$frozenUndeclared = Invoke-Measure ($frozenArgs + @{ ReportPath = $frozenUndeclaredPath })
	$frozenUndeclaredData = Read-Report $frozenUndeclaredPath
	Assert-True ($frozenUndeclaredData.checks.frame_variety -eq 'unverified') 'identical frames without a declaration stay unverified, never pass'
	Assert-True ($frozenUndeclaredData.observed.distinct_frame_hashes -eq 1 -and $frozenUndeclaredData.observed.longest_identical_run -eq 240) 'the undeclared report still says 1 distinct digest and a run of 240'
	Assert-True ($frozenUndeclaredData.observed.duplicate_frames -eq 240 -and $frozenUndeclaredData.observed.duplicate_groups -eq 1) 'the undeclared report names 240 duplicate frames in 1 group'

	$frozenMinPath = New-ReportPath 'variety-frozen-min'
	$frozenMin = Invoke-Measure ($frozenArgs + @{ ReportPath = $frozenMinPath; ExpectedMinDistinctFrames = 2 })
	Assert-True ($frozenMin.ExitCode -eq 1) "240 identical frames with a declared minimum exit 1, got $($frozenMin.ExitCode): $($frozenMin.Output)"
	$frozenMinData = Read-Report $frozenMinPath
	Assert-True ($frozenMinData.checks.frame_variety -eq 'fail' -and $frozenMinData.artifact_verdict -eq 'fail') 'the declared minimum fails frame_variety and the verdict'
	Assert-True ($frozenMinData.observed.distinct_frame_hashes -eq 1) 'the report keeps distinct_frame_hashes = 1'
	Assert-True ((Get-FailureCategories $frozenMinData) -contains 'frame_variety_below_expected') 'the failure is named frame_variety_below_expected'
	Assert-True ($frozenMinData.frame_variety_declaration -eq 'min_distinct_frames:2') 'the report records the declared minimum'
	Assert-True ($frozenMin.Output.Contains('frame_variety=fail') -and $frozenMin.Output.Contains('distinct=1')) 'the CHECKS and IDENTITY lines show the result'
	foreach ($check in @('composition', 'naming', 'completeness', 'range', 'file_size', 'resolution')) {
		Assert-True ($frozenMinData.checks.$check -eq $frozenUndeclaredData.checks.$check) "declaring the minimum does not change the existing check '$check'"
	}

	# Allow: the same frozen frames, explicitly allowed. frame_variety passes, nothing else moves.
	$frozenAllowPath = New-ReportPath 'variety-frozen-allow'
	$frozenAllow = Invoke-Measure ($frozenArgs + @{ ReportPath = $frozenAllowPath; AllowIdenticalFrames = $true })
	$frozenAllowData = Read-Report $frozenAllowPath
	Assert-True ($frozenAllowData.checks.frame_variety -eq 'pass' -and $frozenAllowData.frame_variety_declaration -eq 'allow_identical_frames') 'an explicit allowance passes frame_variety and records the declaration'
	Assert-True ($frozenAllowData.observed.distinct_frame_hashes -eq 1) 'the allowance does not hide the counts'
	foreach ($check in @('composition', 'naming', 'completeness', 'range', 'file_size', 'decode', 'resolution', 'render_exit')) {
		Assert-True ($frozenAllowData.checks.$check -eq $frozenUndeclaredData.checks.$check) "the allowance leaves the existing check '$check' unchanged ($($frozenUndeclaredData.checks.$check))"
	}
	Assert-True ($frozenAllow.ExitCode -eq $frozenUndeclared.ExitCode -and $frozenAllowData.artifact_verdict -eq $frozenUndeclaredData.artifact_verdict) 'the allowance does not change the verdict or exit code of the other checks'

	# Negative control: the same frozen frames without the declaration are not failed on variety and
	# never become a pass, so the failing call above is failing because of the declaration.
	Assert-True ($frozenUndeclared.ExitCode -ne 1) 'without the declaration the frozen sequence is not failed on variety'
	Assert-True ($frozenUndeclaredData.checks.frame_variety -ne 'pass') 'removing the declaration cannot turn the check into a pass'

	# Mixed: 239 identical frames plus one different one.
	$mixedPath = New-ReportPath 'variety-mixed'
	$mixed = Invoke-Measure ($varietyBase + @{ FramesDirectory = $mixedDir; EndNumberExclusive = 240; ReportPath = $mixedPath; ExpectedMinDistinctFrames = 3 })
	$mixedData = Read-Report $mixedPath
	Assert-True ($mixed.ExitCode -eq 1 -and $mixedData.checks.frame_variety -eq 'fail') 'a minimum of 3 fails the 239 + 1 sequence'
	Assert-True ($mixedData.observed.distinct_frame_hashes -eq 2 -and $mixedData.observed.duplicate_groups -eq 1 -and $mixedData.observed.duplicate_frames -eq 239) 'the 239 + 1 sequence has 2 distinct digests and 1 duplicate group of 239 frames'
	$mixedGroup = @($mixedData.observed.duplicate_group_samples)[0]
	Assert-True ($mixedGroup.frame_count -eq 239 -and $mixedGroup.first_index -eq 0 -and $mixedGroup.last_index -eq 238) 'the duplicate group names indices 0..238'
	Assert-True (@($mixedGroup.files)[0] -ceq '000000.png' -and @($mixedGroup.indices).Count -le 20 -and $mixedGroup.sample_truncated -eq $true) 'the group lists file names as a bounded sample and says it is truncated'
	Assert-True ($mixedData.observed.longest_identical_run -eq 239) 'the longest identical run is 239'

	# Runs: several small groups, counted in one pass.
	$runsPath = New-ReportPath 'variety-runs'
	$runs = Invoke-Measure ($varietyBase + @{ FramesDirectory = $runsDir; EndNumberExclusive = 12; ReportPath = $runsPath; ExpectedMinDistinctFrames = 6 })
	$runsData = Read-Report $runsPath
	Assert-True ($runsData.observed.distinct_frame_hashes -eq 6 -and $runsData.observed.duplicate_groups -eq 3 -and $runsData.observed.duplicate_frames -eq 9 -and $runsData.observed.longest_identical_run -eq 4) 'the runs fixture reports 6 distinct, 3 groups, 9 duplicate frames and a longest run of 4'
	Assert-True ($runsData.checks.frame_variety -eq 'pass') 'a minimum equal to the distinct count passes'
	$runsFailPath = New-ReportPath 'variety-runs-fail'
	$runsFail = Invoke-Measure ($varietyBase + @{ FramesDirectory = $runsDir; EndNumberExclusive = 12; ReportPath = $runsFailPath; ExpectedMinDistinctFrames = 7 })
	Assert-True ($runsFail.ExitCode -eq 1 -and (Read-Report $runsFailPath).checks.frame_variety -eq 'fail') 'a minimum one above the distinct count fails'
	$groupSizes = @(@($runsData.observed.duplicate_group_samples) | ForEach-Object { $_.frame_count })
	Assert-True (($groupSizes -join ',') -eq '4,3,2') "duplicate groups are listed largest first, got $($groupSizes -join ',')"

	# The existing repetition fixture is caught only when the caller declares a minimum.
	$cleanMinPath = New-ReportPath 'variety-clean-min'
	$cleanMin = Invoke-Measure ($varietyBase + @{ FramesDirectory = $cleanDir; EndNumberExclusive = 240; ReportPath = $cleanMinPath; ExpectedMinDistinctFrames = 240 })
	Assert-True ($cleanMin.ExitCode -eq 1 -and (Read-Report $cleanMinPath).observed.distinct_frame_hashes -eq 20) 'the 20-distinct clean fixture fails a declared minimum of 240'

	# Input refusal: contradictions and unreachable minimums are exit 3 with no report.
	$refusals = @(
		@{ Name = 'both declarations'; Extra = @{ ExpectedMinDistinctFrames = 2; AllowIdenticalFrames = $true }; Needle = 'contradict' },
		@{ Name = 'a minimum above the expected frame count'; Extra = @{ ExpectedMinDistinctFrames = 241 }; Needle = 'larger than the 240' },
		@{ Name = 'a minimum of 0'; Extra = @{ ExpectedMinDistinctFrames = 0 }; Needle = 'must be 1 or greater' }
	)
	foreach ($refusal in $refusals) {
		$refusedPath = New-ReportPath 'variety-refused'
		$script:refusedReportCounter++
		$refused = Invoke-Measure ($frozenArgs + @{ ReportPath = $refusedPath } + $refusal.Extra)
		Assert-True ($refused.ExitCode -eq 3) "$($refusal.Name) is refused with exit 3, got $($refused.ExitCode): $($refused.Output)"
		Assert-True (-not (Test-Path -LiteralPath $refusedPath)) "$($refusal.Name) writes no report"
		Assert-True ($refused.Output.Contains($refusal.Needle)) "$($refusal.Name) names the reason, got: $($refused.Output)"
	}

	# Positive: 240 distinct frames, real decoder, declared minimum 240 -> pass, exit 0.
	$distinctPath = New-ReportPath 'variety-distinct'
	$distinct = Invoke-Measure @{ FramesDirectory = $distinctDir; StartNumber = 0; EndNumberExclusive = 240; ReportPath = $distinctPath; ExpectedWidth = 64; ExpectedHeight = 48; ExpectedMinDistinctFrames = 240; RunId = "fixture-$testId"; SourceRevision = 'fixture' }
	Assert-True ($distinct.ExitCode -eq 0) "240 distinct frames with a declared minimum of 240 exit 0, got $($distinct.ExitCode): $($distinct.Output)"
	$distinctData = Read-Report $distinctPath
	Assert-True ($distinctData.checks.frame_variety -eq 'pass' -and $distinctData.artifact_verdict -eq 'pass') 'the distinct sequence passes frame_variety and the verdict'
	Assert-True ($distinctData.observed.distinct_frame_hashes -eq 240 -and $distinctData.observed.duplicate_groups -eq 0 -and $distinctData.observed.longest_identical_run -eq 1) 'the report shows 240 distinct digests, no duplicate group and a longest run of 1'
	Assert-True (@(Get-DigestViolations $distinctData $distinctDir).Count -eq 0) 'the distinct sequence digests are the real SHA-256 of each file'
	Register-Group 'frame-variety-declared-identical-frames' 'identical frames across files are counted from the existing digests, frame_variety is unverified unless declared, a declared minimum fails a frozen or 239 + 1 sequence with exit 1, an allowance passes it without moving the other checks, bad declarations are refused with exit 3, and 240 distinct frames pass with exit 0'

	# ============================================================ group 14b: run / revision provenance
	# A report with an empty run_id or source_revision cannot be tied to the run or template version
	# it inspected. The helper refuses before it creates anything, so no such report can exist.
	$provenanceBefore = Get-DirectorySnapshot $cleanDir
	$provenanceCases = @(
		@{ Label = 'both omitted'; Bound = @{}; Names = @('RunId', 'SourceRevision') },
		@{ Label = 'RunId omitted'; Bound = @{ SourceRevision = 'abc1234' }; Names = @('RunId') },
		@{ Label = 'SourceRevision omitted'; Bound = @{ RunId = 'run-1' }; Names = @('SourceRevision') },
		@{ Label = 'RunId empty'; Bound = @{ RunId = ''; SourceRevision = 'abc1234' }; Names = @('RunId') },
		@{ Label = 'SourceRevision empty'; Bound = @{ RunId = 'run-1'; SourceRevision = '' }; Names = @('SourceRevision') },
		@{ Label = 'RunId whitespace'; Bound = @{ RunId = '   '; SourceRevision = 'abc1234' }; Names = @('RunId') },
		@{ Label = 'SourceRevision whitespace'; Bound = @{ RunId = 'run-1'; SourceRevision = "`t " }; Names = @('SourceRevision') }
	)
	foreach ($case in $provenanceCases) {
		$caseReport = New-ReportPath ('provenance-' + ($case.Label -replace '[^A-Za-z]', ''))
		$script:refusedReportCounter++
		$bound = @{
			FramesDirectory    = $cleanDir
			StartNumber        = 0
			EndNumberExclusive = 240
			ReportPath         = $caseReport
			ExpectedWidth      = 64
			ExpectedHeight     = 48
		}
		foreach ($key in $case.Bound.Keys) { $bound[$key] = $case.Bound[$key] }
		$caseResult = Invoke-Measure $bound -KeepProvenanceAsGiven
		Assert-True ($caseResult.ExitCode -eq 3) "provenance case '$($case.Label)' is refused with exit 3, got $($caseResult.ExitCode)"
		Assert-True ($caseResult.Output.Contains('Invalid input')) "provenance case '$($case.Label)' is an input refusal: $($caseResult.Output)"
		foreach ($name in $case.Names) {
			Assert-True ($caseResult.Output.Contains($name)) "provenance case '$($case.Label)' names $name in the refusal: $($caseResult.Output)"
		}
		Assert-True (-not (Test-Path -LiteralPath $caseReport)) "provenance case '$($case.Label)' created no report"
	}
	Assert-True ((Get-DirectorySnapshot $cleanDir) -ceq $provenanceBefore) 'provenance refusals left the inspected frames unchanged'

	$provenanceReport = New-ReportPath 'provenance-valid'
	$provenanceResult = Invoke-Measure @{
		FramesDirectory    = $cleanDir
		StartNumber        = 0
		EndNumberExclusive = 240
		ReportPath         = $provenanceReport
		ExpectedWidth      = 64
		ExpectedHeight     = 48
		RunId              = 'run-20261122-a'
		SourceRevision     = '0123abc'
	} -KeepProvenanceAsGiven
	Assert-True (-not $provenanceResult.Threw) "explicit provenance is accepted: $($provenanceResult.Error)"
	Assert-True ($provenanceResult.ExitCode -eq 0) "explicit provenance on the clean sequence exits 0, got $($provenanceResult.ExitCode): $($provenanceResult.Output)"
	$provenanceData = Read-Report $provenanceReport
	Assert-True ($provenanceData.run_id -ceq 'run-20261122-a') 'the report records RunId exactly as given'
	Assert-True ($provenanceData.source_revision -ceq '0123abc') 'the report records SourceRevision exactly as given'
	Assert-True ($provenanceData.artifact_verdict -eq 'pass') 'the sequence verdict is unchanged by provenance'
	foreach ($check in @('composition', 'naming', 'completeness', 'range', 'file_size', 'decode', 'resolution')) {
		Assert-True ($provenanceData.checks.$check -eq 'pass') "provenance run keeps check '$check' at pass"
	}
	Assert-True ((Get-DirectorySnapshot $cleanDir) -ceq $provenanceBefore) 'the accepted provenance run left the inspected frames unchanged'
	Register-Group 'run-source-revision-provenance-required' 'a missing, empty or blank RunId / SourceRevision is refused before any report exists, and explicit values are recorded verbatim'
	# ============================================================ group 16: the inspector never changed its input
	# Every fixture built above registered the snapshot it had when the suite finished building it.
	# This gate compares all 40 of them again, so a later group that corrupts an earlier fixture is
	# caught here by path instead of being reported as a pass by a tautology. reports/ is excluded from
	# those snapshots because the suite writes it on purpose; its contents are accounted separately
	# (one non-empty report per allocated path, minus the deliberately refused ones).
	Assert-FixtureInputsUnchanged
	$fixtureCount = $script:fixtureBaselines.Count
	Assert-True ($fixtureCount -eq 40) "every fixture directory built by the suite is covered by the comparison, got $fixtureCount"
	Assert-True (@(Get-FixtureInputDrift).Count -eq 0) 'no fixture directory was modified, added to or removed after it was built'
	Assert-True (@(Get-ReportDrift).Count -eq 0) 'reports/ holds exactly one non-empty report per allocated report path'
	Register-Group 'all-fixture-directories-report-directory' "all $fixtureCount fixture directories and the report directory are unchanged since they were built"

	# ============================================================ the declared groups all ran
	# The ledger gate must fail for a dropped, undeclared, duplicated or empty ledger, or it is a
	# tautology again. Each drift is applied to a copy of what this run registered and has to throw
	# with the offending identifier in the message; the real ledger is then compared.
	$selfGroup = 'group-ledger-drift-fails'
	$simulatedRegistration = @($registeredGroups) + $selfGroup
	$driftCases = @(
		@{ Name = 'a declared group that never registers'; Expected = $expectedGroups; Registered = @($simulatedRegistration | Select-Object -Skip 1); Needle = ('missing groups: ' + $expectedGroups[0]) },
		@{ Name = 'a registered group that was never declared'; Expected = $expectedGroups; Registered = @($simulatedRegistration) + 'injected-undeclared-group'; Needle = 'undeclared groups: injected-undeclared-group' },
		@{ Name = 'a group that registers twice'; Expected = $expectedGroups; Registered = @($simulatedRegistration) + $expectedGroups[0]; Needle = ('groups registered twice: ' + $expectedGroups[0]) },
		@{ Name = 'an empty declaration'; Expected = @(); Registered = @($simulatedRegistration); Needle = 'the ledger declares no groups' }
	)
	foreach ($driftCase in $driftCases) {
		$driftMessage = $null
		try { Assert-GroupLedger $driftCase.Expected $driftCase.Registered } catch { $driftMessage = $_.Exception.Message }
		Assert-True ($null -ne $driftMessage) ("the ledger gate fails for $($driftCase.Name)")
		Assert-True ($driftMessage.Contains($driftCase.Needle)) ("the ledger failure for $($driftCase.Name) names it: $($driftCase.Needle); got: $driftMessage")
	}
	Assert-GroupLedger $expectedGroups $simulatedRegistration
	Register-Group $selfGroup 'a declared group that never registers, an undeclared or duplicated group and an empty declaration each fail the ledger by identifier'
	Assert-GroupLedger $expectedGroups @($registeredGroups)
	Write-Output ('GROUPS: {0}/{1} registered' -f $registeredGroups.Count, $expectedGroups.Count)
} catch {
	$suiteError = $_
} finally {
	# The suite has to prove it left no trace even when an assertion above failed, so cleanup and the
	# residual-state checks run unconditionally and the original failure is re-thrown at the end.
	$cleanupProblems = @()
	try {
		if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
			Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
		}
	} catch {
		$cleanupProblems += "fixture root cleanup: $($_.Exception.Message)"
	}
	$cleanupProblems += @(Get-ProductionResidue | ForEach-Object { "Production/ residual entry after cleanup: $_" })
	if (Test-Path -LiteralPath $fixtureRoot) { $cleanupProblems += "fixture root still exists: $fixtureRoot" }
	$finalCheckoutStatus = @(& git -C $repoRoot status --porcelain --untracked-files=all)
	if ($LASTEXITCODE -ne 0) { throw 'Could not verify the developer checkout status after testing.' }
	if (($finalCheckoutStatus -join "`n") -cne ($initialCheckoutStatus -join "`n")) {
		$cleanupProblems += 'test suite leaves the developer checkout unchanged'
		$cleanupProblems += ('before: ' + ($initialCheckoutStatus -join ' | '))
		$cleanupProblems += ('after: ' + ($finalCheckoutStatus -join ' | '))
	}
	if ($cleanupProblems.Count -gt 0) {
		if ($null -ne $suiteError) {
			Write-Output "ASSERT FAILED: $($suiteError.Exception.Message)"
		}
		Assert-True $false ('test suite did not leave a clean tree: ' + ($cleanupProblems -join '; '))
	}
	if ($null -ne $suiteError) { throw $suiteError }
}
