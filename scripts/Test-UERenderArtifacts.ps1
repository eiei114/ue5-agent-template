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
		[int[]]$Skip = @()
	)
	[System.IO.Directory]::CreateDirectory($Directory) | Out-Null
	for ($index = $Start; $index -lt $EndExclusive; $index++) {
		if ($Skip -contains $index) { continue }
		$name = '{0:D6}.png' -f $index
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
	param([hashtable]$Bound)
	$captured = New-Object System.Collections.Generic.List[string]
	$exitCode = $null
	$threw = $false
	$errorMessage = ''
	$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
	try {
		& $measureScript @Bound 2>&1 | ForEach-Object { $captured.Add([string]$_) }
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
	Assert-True ($cleanData.render_evidence.conclusion -eq 'unevaluated_by_this_tool') 'artifact verdict does not claim render success'
	Assert-True ($cleanData.overall_qa_verdict -eq 'not_assessed') 'a clean artifact list is not an overall QA pass'
	$cleanAfter = Get-DirectorySnapshot $cleanDir
	Assert-True ($cleanBefore -ceq $cleanAfter) 'inspection left every inspected file and name unchanged'
	Write-Output 'PASS: clean zero-based 240-frame sequence passes and the inspected directory is untouched'

	# ============================================================ group 2: report exclusivity
	$beforeHash = (Get-FileHash -LiteralPath $cleanReport -Algorithm SHA256).Hash
	$reuseResult = Invoke-Measure @{
		FramesDirectory    = $cleanDir
		StartNumber        = 0
		EndNumberExclusive = 240
		ReportPath         = $cleanReport
	}
	Assert-True ($reuseResult.Threw) 'an existing report path is refused instead of overwritten'
	Assert-True ($reuseResult.Error.Contains('already exists')) 'the refusal names the existing report path'
	Assert-True ((Get-FileHash -LiteralPath $cleanReport -Algorithm SHA256).Hash -ceq $beforeHash) 'the existing report content is preserved byte for byte'

	$insideResult = Invoke-Measure @{
		FramesDirectory    = $cleanDir
		StartNumber        = 0
		EndNumberExclusive = 240
		ReportPath         = (Join-Path $cleanDir 'report.json')
	}
	Assert-True ($insideResult.Threw) 'a report inside the inspected directory is refused'
	Assert-True ($insideResult.Error.Contains('outside the inspected frame directory')) 'the refusal names the write-boundary rule'
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
		Assert-True ($junctionResult.Threw) 'a report parent junction into the inspected directory is refused'
		Assert-True ($junctionResult.Error.Contains('reparse point')) 'the junction refusal identifies the unsafe path component'
		Assert-True (-not (Test-Path -LiteralPath $junctionReport)) 'the refused junction report was not created through the alias'
		Assert-True (-not (Test-Path -LiteralPath (Join-Path $cleanDir 'junction-report.json'))) 'the refused junction report did not appear in the inspected directory'
		Assert-True ((Get-DirectorySnapshot $cleanDir) -ceq $junctionBefore) 'the junction refusal left every inspected frame name and hash unchanged'
	} finally {
		# Keep the test safe even when run against a regression that writes through this junction.
		$escapedReport = Join-Path $cleanDir 'junction-report.json'
		if (Test-Path -LiteralPath $escapedReport) { Remove-Item -LiteralPath $escapedReport -Force }
		if (Test-Path -LiteralPath $junctionPath) { [System.IO.Directory]::Delete($junctionPath, $false) }
	}
	Write-Output 'PASS: report creation is exclusive and cannot write inside the inspected sequence'

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
	Assert-True ($swapData.render_evidence.conclusion -eq 'unevaluated_by_this_tool') 'render success is not inferred from or overridden by the artifact check'
	Assert-True ($swapData.overall_qa_verdict -eq 'not_assessed') 'a negative artifact list does not become an overall QA verdict'
	Write-Output 'PASS: a 240-file sequence with one missing and one trailing frame fails where a frame count alone passes'

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
	Write-Output 'PASS: leading, middle and trailing gaps are all detected by index rather than by count'

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
	Write-Output 'PASS: a 241st frame against a 240-frame end-exclusive range fails the range check'

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
	Write-Output 'PASS: unpadded indices and extension-case differences are rejected as ambiguous, not silently accepted'

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
	Write-Output 'PASS: nested layouts and unrelated files fail instead of being skipped'

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
	Write-Output 'PASS: 0-byte, truncated and payload-corrupt frames fail; a parseable header without a decoded frame never passes'

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
	Assert-True ($halfResult.Threw) 'a half-configured resolution is refused instead of guessed'
	$script:refusedReportCounter++
	Assert-True ($halfResult.Error.Contains('must be given together')) 'the refusal explains the paired requirement'
	Write-Output 'PASS: resolution mismatches fail and unconfigured or half-configured resolution stays unverified'

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
	Assert-True ($equalRangeResult.Threw) 'an empty end-exclusive range is refused instead of passing trivially'
	$script:refusedReportCounter++
	Assert-True ($equalRangeResult.Error.Contains('greater than StartNumber')) 'the refusal explains the end-exclusive range rule'
	Write-Output 'PASS: non-zero starts need an explicit declaration and an empty range cannot pass'

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
	Write-Output 'PASS: missing, failing and slow decoders stay unverified or fail, and the timeout is bounded'

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
	Write-Output 'PASS: the untouched-input gate names removed, rewritten and added files and the ignored Production/ leftover, and is silent when they are restored'

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
		Assert-True ($aliasResult.Threw) 'a junction alias as FramesDirectory is refused before the sequence is inspected'
		Assert-True ($aliasResult.Error.Contains('FramesDirectory path contains a reparse point')) "the refusal comes from the FramesDirectory guard, not the report-parent guard, got: $($aliasResult.Error)"
		Assert-True (-not (Test-Path -LiteralPath $escapedReport)) 'the refused alias wrote no report through the junction into the inspected directory'
		Assert-True ((Get-DirectorySnapshot $guardRealFrames) -ceq $guardFramesBefore) 'the refused alias left every inspected frame name and hash unchanged'
	} finally {
		# Keep the test safe and self-cleaning even when run against a mutation that writes through this alias.
		if (Test-Path -LiteralPath $escapedReport) { Remove-Item -LiteralPath $escapedReport -Force }
		if (Test-Path -LiteralPath $guardAlias) { [System.IO.Directory]::Delete($guardAlias, $false) }
	}
	Write-Output 'PASS: a junction alias as FramesDirectory is refused by that guard alone, and the plain guarded case stays silent'

	# ============================================================ group 14: the inspector never changed its input
	# Every fixture built above registered the snapshot it had when the suite finished building it.
	# This gate compares all 18 of them again, so a later group that corrupts an earlier fixture is

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
	Write-Output 'PASS: a declared step-2 lattice passes and the same lattice undeclared is named as a lattice mismatch'

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
	Write-Output 'PASS: declared step and offset lattices pass, a mismatch in either direction is named, and handle frames stay out-of-range'

	# ============================================================ group 14: the inspector never changed its input
	# Every fixture built above registered the snapshot it had when the suite finished building it.
	# This gate compares all 21 of them again, so a later group that corrupts an earlier fixture is
	# caught here by path instead of being reported as a pass by a tautology. reports/ is excluded from
	# those snapshots because the suite writes it on purpose; its contents are accounted separately
	# (one non-empty report per allocated path, minus the deliberately refused ones).
	Assert-FixtureInputsUnchanged
	$fixtureCount = $script:fixtureBaselines.Count
	Assert-True ($fixtureCount -eq 21) "every fixture directory built by the suite is covered by the comparison, got $fixtureCount"
	Assert-True (@(Get-FixtureInputDrift).Count -eq 0) 'no fixture directory was modified, added to or removed after it was built'
	Assert-True (@(Get-ReportDrift).Count -eq 0) 'reports/ holds exactly one non-empty report per allocated report path'
	Write-Output "PASS: all $fixtureCount fixture directories and the report directory are unchanged since they were built"
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
