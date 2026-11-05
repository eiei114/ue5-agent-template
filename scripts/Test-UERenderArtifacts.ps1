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

try {
	[System.IO.Directory]::CreateDirectory($reportRoot) | Out-Null

	# ============================================================ group 1: clean 240-frame sequence
	# 240 frames is the vertical-loop baseline (8s at 30fps), so the clean case matches the shape a
	# real MRQ run produces: zero-based, six-digit, end-exclusive.
	$cleanDir = Join-Path $fixtureRoot 'clean240'
	New-FrameSequence -Directory $cleanDir -Start 0 -EndExclusive 240
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
	Write-Output 'PASS: report creation is exclusive and cannot write inside the inspected sequence'

	# ============================================================ group 3: baseline blind spot
	# The documented baseline only counts 240 output frames. A sequence that lost frame 120 and
	# gained frame 240 still holds exactly 240 files, so a count-only check passes while ffmpeg
	# would encode a shifted sequence. The index-set comparison must fail this fixture.
	$swapDir = Join-Path $fixtureRoot 'swap240'
	Copy-Item -LiteralPath $cleanDir -Destination $swapDir -Recurse
	Remove-Item -LiteralPath (Join-Path $swapDir '000120.png') -Force
	Add-Frame -Directory $swapDir -Index 240
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
	Assert-True ($halfResult.Error.Contains('must be given together')) 'the refusal explains the paired requirement'
	Write-Output 'PASS: resolution mismatches fail and unconfigured or half-configured resolution stays unverified'

	# ============================================================ group 10: range inputs
	$offsetDir = Join-Path $fixtureRoot 'offset'
	New-FrameSequence -Directory $offsetDir -Start 10 -EndExclusive 16
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
	Assert-True ($equalRangeResult.Error.Contains('greater than StartNumber')) 'the refusal explains the end-exclusive range rule'
	Write-Output 'PASS: non-zero starts need an explicit declaration and an empty range cannot pass'

	# ============================================================ group 11: decoder absence, failure, timeout
	$decoderDir = Join-Path $fixtureRoot 'decoder'
	New-FrameSequence -Directory $decoderDir -Start 0 -EndExclusive 6
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

	# ============================================================ group 12: shipped sequence untouched
	$finalCheck = Get-DirectorySnapshot $fixtureRoot
	Assert-True ($finalCheck -notmatch 'frames-mutated') 'fixture root snapshot is stable'
	Write-Output 'PASS: fixture tree inspected before cleanup'
} finally {
	if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
		Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
	}
	$finalCheckoutStatus = @(& git -C $repoRoot status --porcelain --untracked-files=all)
	if ($LASTEXITCODE -ne 0) { throw 'Could not verify the developer checkout status after testing.' }
	Assert-True (($finalCheckoutStatus -join "`n") -ceq ($initialCheckoutStatus -join "`n")) 'test suite leaves the developer checkout unchanged'
}
