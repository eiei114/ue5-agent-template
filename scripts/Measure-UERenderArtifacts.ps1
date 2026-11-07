[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)]
	[string]$FramesDirectory,

	[Parameter(Mandatory = $true)]
	[int]$StartNumber,

	[Parameter(Mandatory = $true)]
	[int]$EndNumberExclusive,

	[Parameter(Mandatory = $true)]
	[string]$ReportPath,

	[ValidateRange(1, 10)]
	[int]$Digits = 6,

	[ValidatePattern('^\.[A-Za-z0-9]+$')]
	[string]$Extension = '.png',

	[int]$ExpectedWidth = 0,

	[int]$ExpectedHeight = 0,

	[string]$DecoderPath = '',

	[ValidateRange(100, 600000)]
	[int]$DecoderTimeoutMilliseconds = 10000,

	[string]$RunId = '',

	[string]$SourceRevision = '',

	[string]$RenderExitCode = '',

	[string]$RenderNotification = ''
)

# Read-only pre-encode inspection of one MRQ image sequence.
# The script never renames, repairs, deletes or writes into the inspected directory. It only
# creates a new report file at an explicit, previously unused path.

$ErrorActionPreference = 'Stop'

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$ordinalIgnoreCase = [System.StringComparison]::OrdinalIgnoreCase

function Assert-NoReparsePointInPath {
	param(
		[string]$Path,
		[string]$PathRole
	)

	$currentPath = [System.IO.Path]::GetFullPath($Path)
	while (-not [string]::IsNullOrWhiteSpace($currentPath)) {
		try {
			$attributes = [System.IO.File]::GetAttributes($currentPath)
			if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
				throw "Invalid input: $PathRole path contains a reparse point and cannot be verified safely: $currentPath"
			}
		} catch [System.IO.FileNotFoundException] {
			# A report directory may not exist yet. Check its ancestors before creating any directories.
		} catch [System.IO.DirectoryNotFoundException] {
			# A report directory may not exist yet. Check its ancestors before creating any directories.
		}

		$parent = [System.IO.Directory]::GetParent($currentPath)
		if ($null -eq $parent) { break }
		$parentPath = [System.IO.Path]::GetFullPath($parent.FullName)
		if ([string]::Equals($parentPath, $currentPath, [System.StringComparison]::OrdinalIgnoreCase)) { break }
		$currentPath = $parentPath
	}
}

function Quote-Argument([string]$Value) {
	if ([string]::IsNullOrEmpty($Value)) { return '""' }
	if ($Value -match '[\s"]') { return '"' + ($Value -replace '"', '\"') + '"' }
	return $Value
}

function Stop-OwnedProcessTree([System.Diagnostics.Process]$Process) {
	# The bool overload of Kill (kill entire tree) exists only on .NET Core and later. On Windows
	# PowerShell 5.1 it is missing, and a plain Kill() would leave a launched shell's child alive
	# holding the output pipe. Fall back to an exact-PID tree kill for the process started here.
	try {
		$treeKill = $Process.GetType().GetMethod('Kill', [Type[]]@([bool]))
		if ($null -ne $treeKill) {
			$null = $treeKill.Invoke($Process, @($true))
			return
		}
	} catch { }
	try {
		$taskKill = @(Get-Command -Name 'taskkill.exe' -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
		if ($null -ne $taskKill) {
			$null = & $taskKill.Source /PID $Process.Id /T /F 2>&1
			return
		}
	} catch { }
	try { $Process.Kill() } catch { }
}

function Invoke-BoundedProcess {
	param(
		[string]$FilePath,
		[string[]]$ArgumentList,
		[int]$TimeoutMilliseconds
	)
	# Every external probe is bounded. A deadline kill is reported as `timedOut`; it is never
	# rounded into a success. Only the process started here is terminated.
	$process = $null
	try {
		$startInfo = New-Object System.Diagnostics.ProcessStartInfo
		$startInfo.FileName = $FilePath
		$startInfo.Arguments = (($ArgumentList | ForEach-Object { Quote-Argument $_ }) -join ' ')
		$startInfo.UseShellExecute = $false
		$startInfo.CreateNoWindow = $true
		$startInfo.RedirectStandardOutput = $true
		$startInfo.RedirectStandardError = $true
		$process = [System.Diagnostics.Process]::Start($startInfo)
		# Drain both pipes while waiting. Reading them only after the wait makes a slow or verbose
		# decoder block on a full pipe and turns a short deadline into minutes.
		$stdoutTask = $process.StandardOutput.ReadToEndAsync()
		$stderrTask = $process.StandardError.ReadToEndAsync()
		if (-not $process.WaitForExit($TimeoutMilliseconds)) {
			$timedOut = $true
			Stop-OwnedProcessTree -Process $process
			$null = $process.WaitForExit(2000)
		} else {
			$timedOut = $false
		}
		$stdout = ''
		$stderr = ''
		# Reading .Result on an incomplete task blocks with no deadline, so only read a task that
		# actually completed. A deadline kill that leaves output undrained must not stall the run.
		$drainDeadline = [DateTime]::UtcNow.AddSeconds(2)
		while (-not $stdoutTask.IsCompleted -and [DateTime]::UtcNow -lt $drainDeadline) { Start-Sleep -Milliseconds 50 }
		while (-not $stderrTask.IsCompleted -and [DateTime]::UtcNow -lt $drainDeadline) { Start-Sleep -Milliseconds 50 }
		if ($stdoutTask.IsCompleted) { try { $stdout = $stdoutTask.Result } catch { } }
		if ($stderrTask.IsCompleted) { try { $stderr = $stderrTask.Result } catch { } }
		$exitCode = $null
		if (-not $timedOut) {
			try { $exitCode = $process.ExitCode } catch { }
		}
		return [ordered]@{
			started = $true
			timedOut = $timedOut
			exit_code = $exitCode
			stdout = $stdout
			stderr = $stderr
			error = ''
		}
	} catch {
		return [ordered]@{
			started = $false
			timedOut = $false
			exit_code = $null
			stdout = ''
			stderr = ''
			error = $_.Exception.Message
		}
	} finally {
		if ($null -ne $process) { $process.Dispose() }
	}
}

function Get-WorstState([string[]]$States) {
	if (@($States | Where-Object { $_ -eq 'fail' }).Count -gt 0) { return 'fail' }
	if (@($States).Count -eq 0) { return 'unverified' }
	if (@($States | Where-Object { $_ -eq 'unverified' }).Count -gt 0) { return 'unverified' }
	return 'pass'
}

# ---------------------------------------------------------------- input validation

if ($StartNumber -lt 0) {
	throw 'Invalid input: StartNumber must be 0 or greater. A non-zero start is supported but must be set explicitly from the render range.'
}
if ($EndNumberExclusive -le $StartNumber) {
	throw 'Invalid input: EndNumberExclusive must be greater than StartNumber. The render range is end-exclusive.'
}
if (($ExpectedWidth -eq 0) -ne ($ExpectedHeight -eq 0)) {
	throw 'Invalid input: ExpectedWidth and ExpectedHeight must be given together, or both omitted when the resolution is unknown.'
}
if ($ExpectedWidth -lt 0 -or $ExpectedHeight -lt 0) {
	throw 'Invalid input: expected resolution must not be negative.'
}

$framesItem = Get-Item -LiteralPath $FramesDirectory -ErrorAction SilentlyContinue
if ($null -eq $framesItem -or -not $framesItem.PSIsContainer) {
	throw "Invalid input: FramesDirectory is not an existing directory: $FramesDirectory"
}
$framesFull = [System.IO.Path]::GetFullPath($framesItem.FullName).TrimEnd([char[]]@('\', '/'))
$pathSeparator = [System.IO.Path]::DirectorySeparatorChar
Assert-NoReparsePointInPath -Path $framesItem.FullName -PathRole 'FramesDirectory'

$reportFull = [System.IO.Path]::GetFullPath($ReportPath)
if (Test-Path -LiteralPath $reportFull) {
	throw "Invalid input: report path already exists and will not be overwritten: $reportFull"
}
$reportParent = Split-Path -Parent $reportFull
if (-not [string]::IsNullOrWhiteSpace($reportParent)) {
	Assert-NoReparsePointInPath -Path $reportParent -PathRole 'ReportPath parent'
}
if ($reportFull.StartsWith($framesFull + $pathSeparator, $ordinalIgnoreCase)) {
	throw 'Invalid input: the report must be written outside the inspected frame directory so the inspection cannot change its own input.'
}
if (-not [string]::IsNullOrWhiteSpace($reportParent) -and -not (Test-Path -LiteralPath $reportParent -PathType Container)) {
	[System.IO.Directory]::CreateDirectory($reportParent) | Out-Null
}

$resolutionConfigured = ($ExpectedWidth -gt 0 -and $ExpectedHeight -gt 0)
$expectedCount = $EndNumberExclusive - $StartNumber
$expectedIndices = New-Object System.Collections.Generic.HashSet[int]
for ($index = $StartNumber; $index -lt $EndNumberExclusive; $index++) { $null = $expectedIndices.Add($index) }

$strictPattern = '^(?<index>[0-9]{' + $Digits + '})' + [System.Text.RegularExpressions.Regex]::Escape($Extension) + '$'
$strictRegex = New-Object System.Text.RegularExpressions.Regex($strictPattern, [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
$looseExtensionPattern = '^(?<index>[0-9]{' + $Digits + '})' + [System.Text.RegularExpressions.Regex]::Escape($Extension) + '$'
$looseExtensionRegex = New-Object System.Text.RegularExpressions.Regex($looseExtensionPattern, ([System.Text.RegularExpressions.RegexOptions]::CultureInvariant -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase))
$anyDigitsPattern = '^(?<index>[0-9]+)' + [System.Text.RegularExpressions.Regex]::Escape($Extension) + '$'
$anyDigitsRegex = New-Object System.Text.RegularExpressions.Regex($anyDigitsPattern, ([System.Text.RegularExpressions.RegexOptions]::CultureInvariant -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase))

# ---------------------------------------------------------------- directory scan

$nestedEntries = New-Object System.Collections.Generic.List[string]
$unexpectedEntries = New-Object System.Collections.Generic.List[object]
$ambiguousEntries = New-Object System.Collections.Generic.List[object]
$frameFiles = New-Object System.Collections.Generic.List[object]

$entries = @(Get-ChildItem -LiteralPath $framesFull -Force | Sort-Object -Property Name)
foreach ($entry in $entries) {
	if ($entry.PSIsContainer) {
		$nestedEntries.Add($entry.Name)
		continue
	}
	if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
		$unexpectedEntries.Add([ordered]@{ file = $entry.Name; reason = 'reparse_point' })
		continue
	}
	$strictMatch = $strictRegex.Match($entry.Name)
	if ($strictMatch.Success) {
		$frameFiles.Add([ordered]@{ index = [int]$strictMatch.Groups['index'].Value; file = $entry; name = $entry.Name })
		continue
	}
	if ($looseExtensionRegex.IsMatch($entry.Name)) {
		$ambiguousEntries.Add([ordered]@{ file = $entry.Name; reason = 'extension_case_differs_from_contract' })
		continue
	}
	if ($anyDigitsRegex.IsMatch($entry.Name)) {
		$ambiguousEntries.Add([ordered]@{ file = $entry.Name; reason = 'digit_padding_differs_from_contract' })
		continue
	}
	$unexpectedEntries.Add([ordered]@{ file = $entry.Name; reason = 'name_does_not_match_contract' })
}

$byIndex = @{}
foreach ($frame in $frameFiles) {
	$key = [int]$frame.index
	if ($byIndex.ContainsKey($key)) {
		$ambiguousEntries.Add([ordered]@{ file = $frame.name; reason = 'duplicate_index_for_contract_name' })
		$ambiguousEntries.Add([ordered]@{ file = $byIndex[$key].name; reason = 'duplicate_index_for_contract_name' })
		continue
	}
	$byIndex[$key] = $frame
}

$missingIndices = New-Object System.Collections.Generic.List[int]
foreach ($expected in ($expectedIndices | Sort-Object)) {
	if (-not $byIndex.ContainsKey($expected)) { $missingIndices.Add($expected) }
}
$outOfRangeIndices = New-Object System.Collections.Generic.List[int]
foreach ($observed in ($byIndex.Keys | Sort-Object)) {
	if (-not $expectedIndices.Contains([int]$observed)) { $outOfRangeIndices.Add([int]$observed) }
}

$inRangeFrames = @($byIndex.Keys | Sort-Object | ForEach-Object { $byIndex[[int]$_] })

function Format-IndexList($Indices) {
	if ($null -eq $Indices) { return '' }
	# A generic List must not be re-wrapped with @(); PowerShell 7 rejects that coercion.
	$list = if ($Indices -is [System.Collections.IList]) { $Indices } else { @($Indices) }
	if ($list.Count -eq 0) { return '' }
	$limit = [Math]::Min(20, $list.Count)
	$shown = New-Object System.Collections.Generic.List[string]
	for ($i = 0; $i -lt $limit; $i++) { $shown.Add([string]$list[$i]) }
	if ($list.Count -gt $limit) { $shown.Add("...(+$($list.Count - $limit) more)") }
	return ($shown -join ',')
}

function Get-EntryFileName($Entry) {
	if ($null -eq $Entry) { return '' }
	if ($Entry -is [System.Collections.IDictionary]) {
		if ($Entry.Contains('file')) { return [string]$Entry['file'] }
		return ''
	}
	if ($Entry.PSObject.Properties['file']) { return [string]$Entry.file }
	return [string]$Entry
}

function Format-SampleList($Items) {
	if ($null -eq $Items) { return '' }
	$list = if ($Items -is [System.Collections.IList]) { $Items } else { @($Items) }
	if ($list.Count -eq 0) { return '' }
	$limit = [Math]::Min(20, $list.Count)
	$shown = New-Object System.Collections.Generic.List[string]
	for ($i = 0; $i -lt $limit; $i++) { $shown.Add((Get-EntryFileName $list[$i])) }
	if ($list.Count -gt $limit) { $shown.Add("...(+$($list.Count - $limit) more)") }
	return ($shown -join ',')
}

# ---------------------------------------------------------------- decoder resolution

$decoder = [ordered]@{
	requested_path = $DecoderPath
	resolution = 'not_found'
	path = ''
	version = 'unknown'
	version_probe_exit = $null
	install_attempted = $false
}

if (-not [string]::IsNullOrWhiteSpace($DecoderPath)) {
	if (Test-Path -LiteralPath $DecoderPath -PathType Leaf) {
		$decoder.resolution = 'explicit'
		$decoder.path = [System.IO.Path]::GetFullPath($DecoderPath)
	} else {
		$decoder.resolution = 'explicit_path_missing'
	}
} else {
	$discovered = @(Get-Command -Name 'ffprobe' -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
	if ($null -ne $discovered) {
		$decoder.resolution = 'path_lookup'
		$decoder.path = $discovered.Source
	}
}

if (-not [string]::IsNullOrWhiteSpace($decoder.path)) {
	$versionProbe = Invoke-BoundedProcess -FilePath $decoder.path -ArgumentList @('-version') -TimeoutMilliseconds ([Math]::Min($DecoderTimeoutMilliseconds, 15000))
	$decoder.version_probe_exit = $versionProbe.exit_code
	if ($versionProbe.started -and -not $versionProbe.timedOut -and $versionProbe.exit_code -eq 0) {
		$firstLine = @(($versionProbe.stdout -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -First 1
		if (-not [string]::IsNullOrWhiteSpace($firstLine)) { $decoder.version = $firstLine.Trim() }
	} elseif ($versionProbe.timedOut) {
		$decoder.version = 'unknown (version probe timed out)'
	} else {
		$decoder.version = 'unknown (version probe failed)'
	}
}

# ---------------------------------------------------------------- per-frame decode

$frameChecks = New-Object System.Collections.Generic.List[object]
$decodeStates = New-Object System.Collections.Generic.List[string]
$emptyFiles = New-Object System.Collections.Generic.List[object]
$decodeFailures = New-Object System.Collections.Generic.List[object]
$codecMismatches = New-Object System.Collections.Generic.List[object]
$resolutionMismatches = New-Object System.Collections.Generic.List[object]
$decodeTimeouts = New-Object System.Collections.Generic.List[object]
$expectedCodec = 'png'

foreach ($frame in $inRangeFrames) {
	$fileInfo = $frame.file
	$sizeBytes = [long]$fileInfo.Length
	$entry = [ordered]@{
		index = [int]$frame.index
		file = [string]$frame.name
		size_bytes = $sizeBytes
		sha256 = ''
		decode = 'unverified'
		codec = ''
		pix_fmt = ''
		width = 0
		height = 0
		detail = ''
	}

	if ($sizeBytes -eq 0) {
		$emptyFiles.Add([ordered]@{ file = $frame.name; index = [int]$frame.index })
		$entry.decode = 'failed'
		$entry.detail = 'empty file (0 bytes); no bytes were decoded'
		# An empty file cannot be decoded either, so the decode check must not pass on its behalf.
		$decodeStates.Add('unverified')
		$frameChecks.Add($entry)
		continue
	}

	$entry.sha256 = (Get-FileHash -LiteralPath $fileInfo.FullName -Algorithm SHA256).Hash.ToLowerInvariant()

	if ($decoder.resolution -ne 'explicit' -and $decoder.resolution -ne 'path_lookup') {
		$entry.decode = 'unverified'
		$entry.detail = "decoder unavailable ($($decoder.resolution)); frame bytes were not decoded"
		$frameChecks.Add($entry)
		continue
	}

	# `-show_frames` is required for the decode verdict: ffprobe exits 0 and still prints a stream
	# header for a truncated or corrupt PNG, but it emits no decoded frame. Counting frames is what
	# separates "a picture decoded" from "a container header was parsed".
	$probe = Invoke-BoundedProcess -FilePath $decoder.path -ArgumentList @(
		'-v', 'error',
		'-select_streams', 'v:0',
		'-show_entries', 'stream=codec_name:frame=width,height,pix_fmt',
		'-of', 'json',
		$fileInfo.FullName
	) -TimeoutMilliseconds $DecoderTimeoutMilliseconds

	if (-not $probe.started) {
		$entry.decode = 'failed'
		$entry.detail = "decoder could not be started: $($probe.error)"
		$decodeFailures.Add([ordered]@{ file = $frame.name; index = [int]$frame.index; detail = $entry.detail })
		$frameChecks.Add($entry)
		continue
	}
	if ($probe.timedOut) {
		$entry.decode = 'timeout'
		$entry.detail = "decoder did not finish within $DecoderTimeoutMilliseconds ms; the probe was killed and the result is not counted as success"
		$decodeTimeouts.Add([ordered]@{ file = $frame.name; index = [int]$frame.index; timeout_ms = $DecoderTimeoutMilliseconds })
		$frameChecks.Add($entry)
		continue
	}
	if ($probe.exit_code -ne 0) {
		$message = ($probe.stderr -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -First 1
		$entry.decode = 'failed'
		$entry.detail = "decoder exit $($probe.exit_code): $message"
		$decodeFailures.Add([ordered]@{ file = $frame.name; index = [int]$frame.index; detail = $entry.detail })
		$frameChecks.Add($entry)
		continue
	}

	$streams = @()
	$decodedFrames = @()
	try {
		$parsed = $probe.stdout | ConvertFrom-Json
		if ($null -ne $parsed) {
			$streams = @($parsed.streams | Where-Object { $null -ne $_ })
			$decodedFrames = @($parsed.frames | Where-Object { $null -ne $_ })
		}
	} catch {
		$streams = @()
		$decodedFrames = @()
	}
	if ($streams.Count -eq 0) {
		$entry.decode = 'failed'
		$entry.detail = 'decoder reported no video stream for this file'
		$decodeFailures.Add([ordered]@{ file = $frame.name; index = [int]$frame.index; detail = $entry.detail })
		$frameChecks.Add($entry)
		continue
	}
	if ($decodedFrames.Count -eq 0) {
		$message = ($probe.stderr -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -First 1
		$entry.codec = [string]$streams[0].codec_name
		$entry.decode = 'failed'
		$entry.detail = "decoder produced no decoded frame although it exited 0: $message"
		$decodeFailures.Add([ordered]@{ file = $frame.name; index = [int]$frame.index; detail = $entry.detail })
		$frameChecks.Add($entry)
		continue
	}

	$stream = $streams[0]
	$decodedFrame = $decodedFrames[0]
	$entry.decode = 'ok'
	$entry.codec = [string]$stream.codec_name
	$entry.width = [int]$decodedFrame.width
	$entry.height = [int]$decodedFrame.height
	$entry.pix_fmt = [string]$decodedFrame.pix_fmt

	# A zero dimension means the decoder could not reconstruct a picture, so it is a failure and
	# never a pass, whatever the exit code said.
	if ($entry.width -le 0 -or $entry.height -le 0) {
		$entry.decode = 'failed'
		$entry.detail = "decoder reported $($entry.width)x$($entry.height); the file has no decodable picture"
		$decodeFailures.Add([ordered]@{ file = $frame.name; index = [int]$frame.index; detail = $entry.detail })
		$frameChecks.Add($entry)
		continue
	}

	if ($Extension -ieq '.png' -and $entry.codec -ne $expectedCodec) {
		$entry.decode = 'failed'
		$entry.detail = "decoded codec '$($entry.codec)' does not match the $Extension name contract"
		$codecMismatches.Add([ordered]@{ file = $frame.name; index = [int]$frame.index; codec = $entry.codec })
	}

	if ($resolutionConfigured) {
		if ($entry.width -ne $ExpectedWidth -or $entry.height -ne $ExpectedHeight) {
			$resolutionMismatches.Add([ordered]@{
				file = $frame.name
				index = [int]$frame.index
				observed = "$($entry.width)x$($entry.height)"
				expected = "${ExpectedWidth}x${ExpectedHeight}"
			})
		}
	}

	if ($entry.decode -eq 'ok') { $decodeStates.Add('pass') } else { $decodeStates.Add('fail') }
	$frameChecks.Add($entry)
}

# ---------------------------------------------------------------- aggregate checks

$namingState = 'pass'
if ($unexpectedEntries.Count -gt 0 -or $ambiguousEntries.Count -gt 0) { $namingState = 'fail' }

$compositionState = 'pass'
if ($nestedEntries.Count -gt 0) { $compositionState = 'fail' }

$completenessState = 'pass'
if ($missingIndices.Count -gt 0) { $completenessState = 'fail' }

$rangeState = 'pass'
if ($outOfRangeIndices.Count -gt 0) { $rangeState = 'fail' }

$sizeState = 'pass'
if ($emptyFiles.Count -gt 0) { $sizeState = 'fail' }

if ($inRangeFrames.Count -eq 0) {
	$decodeState = 'fail'
} elseif ($decodeTimeouts.Count -gt 0) {
	$decodeState = 'unverified'
} else {
	$decodeState = Get-WorstState -States @($decodeStates | Select-Object -Unique)
	if ($decodeFailures.Count -gt 0 -or $codecMismatches.Count -gt 0) { $decodeState = 'fail' }
}

if (-not $resolutionConfigured) {
	$resolutionState = 'unverified'
} elseif ($resolutionMismatches.Count -gt 0) {
	$resolutionState = 'fail'
} elseif ($decodeState -eq 'fail' -or $decodeState -eq 'unverified') {
	$resolutionState = 'unverified'
} else {
	$resolutionState = 'pass'
}

$verdict = Get-WorstState -States @(
	$namingState, $compositionState, $completenessState, $rangeState, $sizeState, $decodeState, $resolutionState
)

$failures = New-Object System.Collections.Generic.List[object]
if ($compositionState -eq 'fail') {
	$failures.Add([ordered]@{
		category = 'unsupported_composition'
		detail = 'subdirectories are present, so this is not one flat sequence (multi-shot/multi-pass layout is unsupported here)'
		sample = (Format-SampleList -Items @($nestedEntries | ForEach-Object { [ordered]@{ file = $_ } }))
	})
}
if ($missingIndices.Count -gt 0) {
	$failures.Add([ordered]@{
		category = 'missing_frames'
		detail = "$($missingIndices.Count) expected index(es) absent from ${StartNumber}..$($EndNumberExclusive - 1)"
		sample = (Format-IndexList -Indices $missingIndices)
	})
}
if ($outOfRangeIndices.Count -gt 0) {
	$failures.Add([ordered]@{
		category = 'out_of_range_frames'
		detail = "$($outOfRangeIndices.Count) frame(s) exist outside the declared end-exclusive range"
		sample = (Format-IndexList -Indices $outOfRangeIndices)
	})
}
if ($unexpectedEntries.Count -gt 0) {
	$failures.Add([ordered]@{
		category = 'unexpected_name'
		detail = "$($unexpectedEntries.Count) entry(ies) do not match the ${Digits}-digit $Extension contract"
		sample = (Format-SampleList -Items $unexpectedEntries)
	})
}
if ($ambiguousEntries.Count -gt 0) {
	$failures.Add([ordered]@{
		category = 'ambiguous_name'
		detail = "$($ambiguousEntries.Count) entry(ies) are near-matches of the contract and cannot be resolved safely"
		sample = (Format-SampleList -Items $ambiguousEntries)
	})
}
if ($emptyFiles.Count -gt 0) {
	$failures.Add([ordered]@{
		category = 'empty_file'
		detail = "$($emptyFiles.Count) frame(s) are 0 bytes"
		sample = (Format-SampleList -Items $emptyFiles)
	})
}
if ($decodeFailures.Count -gt 0) {
	$failures.Add([ordered]@{
		category = 'decode_failed'
		detail = "$($decodeFailures.Count) frame(s) could not be decoded"
		sample = (Format-SampleList -Items $decodeFailures)
	})
}
if ($codecMismatches.Count -gt 0) {
	$failures.Add([ordered]@{
		category = 'codec_mismatch'
		detail = "$($codecMismatches.Count) frame(s) decode to a codec other than the name contract implies"
		sample = (Format-SampleList -Items $codecMismatches)
	})
}
if ($resolutionMismatches.Count -gt 0) {
	$failures.Add([ordered]@{
		category = 'resolution_mismatch'
		detail = "$($resolutionMismatches.Count) frame(s) do not match ${ExpectedWidth}x${ExpectedHeight}"
		sample = (Format-SampleList -Items $resolutionMismatches)
	})
}
if ($decodeTimeouts.Count -gt 0) {
	$failures.Add([ordered]@{
		category = 'decode_timeout'
		detail = "$($decodeTimeouts.Count) frame(s) exceeded the ${DecoderTimeoutMilliseconds} ms decode deadline"
		sample = (Format-SampleList -Items $decodeTimeouts)
	})
}
if (-not $resolutionConfigured) {
	$failures.Add([ordered]@{
		category = 'resolution_not_configured'
		detail = 'no expected resolution was given, so that check stays unverified instead of passing'
		sample = ''
	})
}

$report = [ordered]@{
	schema_version = 1
	tool = 'scripts/Measure-UERenderArtifacts.ps1'
	generated_at_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
	scope = 'pre_encode_artifact_only'
	run_id = $RunId
	source_revision = $SourceRevision
	input = [ordered]@{
		frames_directory = $framesFull
		naming_contract = "[$Digits digit zero-padded index]$Extension"
		digits = $Digits
		extension = $Extension
		start_number = $StartNumber
		end_number_exclusive = $EndNumberExclusive
		end_is_exclusive = $true
		expected_width = $ExpectedWidth
		expected_height = $ExpectedHeight
		resolution_configured = $resolutionConfigured
	}
	expectations = [ordered]@{
		frame_count = $expectedCount
		first_index = $StartNumber
		last_index = $EndNumberExclusive - 1
		resolution = $(if ($resolutionConfigured) { "${ExpectedWidth}x${ExpectedHeight}" } else { 'not_configured' })
	}
	observed = [ordered]@{
		directory_entry_count = $entries.Count
		contract_file_count = $inRangeFrames.Count
		first_index = $(if ($inRangeFrames.Count -gt 0) { [int]$inRangeFrames[0].index } else { $null })
		last_index = $(if ($inRangeFrames.Count -gt 0) { [int]$inRangeFrames[-1].index } else { $null })
		total_bytes = [long](($inRangeFrames | ForEach-Object { [long]$_.file.Length } | Measure-Object -Sum).Sum)
		nested_entries = @($nestedEntries)
	}
	checks = [ordered]@{
		composition = $compositionState
		naming = $namingState
		completeness = $completenessState
		range = $rangeState
		file_size = $sizeState
		decode = $decodeState
		resolution = $resolutionState
	}
	decoder = $decoder
	violations = [ordered]@{
		missing_indices = $missingIndices.ToArray()
		out_of_range_indices = $outOfRangeIndices.ToArray()
		unexpected_entries = $unexpectedEntries.ToArray()
		ambiguous_entries = $ambiguousEntries.ToArray()
		empty_files = $emptyFiles.ToArray()
		decode_failures = $decodeFailures.ToArray()
		decode_timeouts = $decodeTimeouts.ToArray()
		codec_mismatches = $codecMismatches.ToArray()
		resolution_mismatches = $resolutionMismatches.ToArray()
	}
	failures = @($failures | ForEach-Object { $_ })
	frames = @($frameChecks | ForEach-Object { $_ })
	artifact_verdict = $verdict
	render_evidence = [ordered]@{
		render_artifacts_cannot_prove_render_success = $true
		exit_code_provided = (-not [string]::IsNullOrWhiteSpace($RenderExitCode))
		exit_code = $(if ([string]::IsNullOrWhiteSpace($RenderExitCode)) { 'not_provided' } else { $RenderExitCode })
		notification_provided = (-not [string]::IsNullOrWhiteSpace($RenderNotification))
		notification = $(if ([string]::IsNullOrWhiteSpace($RenderNotification)) { 'not_provided' } else { $RenderNotification })
		conclusion = 'unevaluated_by_this_tool'
	}
	unverified_scope = @(
		'UE5.8.4 real MRQ render',
		'MRQ completion notification and exit-code evidence',
		'ffprobe inspection of the encoded MP4',
		'visual review of first/middle/last frames and full playback',
		'audio existence is not audio review',
		'loop seam review',
		'multi-shot / multi-pass / EXR layouts'
	)
	overall_qa_verdict = 'not_assessed'
	notes = @(
		'This report covers the source image sequence only; it is not a render, playback, audio or loop result.',
		'A previous run with the same frame count cannot be ruled out by this check alone. Use a fresh run-scoped output directory and verify ownership before rendering.',
		'Inputs were read only; the inspected directory was not renamed, repaired or modified.'
	)
}

try {
	$fileStream = [System.IO.FileStream]::new($reportFull, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
	try {
		$writer = New-Object System.IO.StreamWriter($fileStream, $utf8NoBom)
		try {
			$writer.Write((ConvertTo-Json -InputObject $report -Depth 12))
			$writer.Write([Environment]::NewLine)
		} finally {
			$writer.Dispose()
		}
	} finally {
		$fileStream.Dispose()
	}
} catch {
	throw "Could not exclusively create the report file: $reportFull. $($_.Exception.Message)"
}

Write-Output "VERDICT: $verdict"
Write-Output ("CHECKS: composition={0} naming={1} completeness={2} range={3} file_size={4} decode={5} resolution={6}" -f $compositionState, $namingState, $completenessState, $rangeState, $sizeState, $decodeState, $resolutionState)
Write-Output ("DECODER: {0} {1}" -f $decoder.resolution, $decoder.version)
Write-Output ("FRAMES: expected={0} observed={1}" -f $expectedCount, $inRangeFrames.Count)
foreach ($failure in $failures) {
	Write-Output ("FAILURE: {0} - {1} {2}" -f $failure.category, $failure.detail, $failure.sample)
}
Write-Output "REPORT: $reportFull"

if ($verdict -eq 'pass') { exit 0 }
if ($verdict -eq 'fail') { exit 1 }
exit 2
