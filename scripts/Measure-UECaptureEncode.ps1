[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)]
	[string]$Preset,

	[Parameter(Mandatory = $true)]
	[string]$VideoPath,

	[Parameter(Mandatory = $true)]
	[string]$ReportPath,

	[string]$PresetFile = '',

	[string]$FfprobePath = '',

	[ValidateRange(1000, 120000)]
	[int]$ProbeTimeoutMilliseconds = 15000
)

# Read-only inspection of one encoded MP4 against the capture preset it was rendered from.
# Expectations (frame count, duration, resolution, fps) are never written by hand here: they are
# derived from templates/CAPTURE-PRESETS.json, which is the only place those numbers live.
# The script does not render, does not start UE, and does not modify the video it inspects.

$ErrorActionPreference = 'Stop'

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$ordinalIgnoreCase = [System.StringComparison]::OrdinalIgnoreCase

function Quote-Argument([string]$Value) {
	if ([string]::IsNullOrEmpty($Value)) { return '""' }
	if ($Value -match '[\s"]') { return '"' + ($Value -replace '"', '\"') + '"' }
	return $Value
}

function Stop-OwnedProcessTree([System.Diagnostics.Process]$Process) {
	# The bool overload of Kill (kill whole tree) exists only on .NET Core and later. On Windows
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
	# Every ffprobe call is bounded. A deadline kill is reported as `timedOut` and is never rounded
	# into a success. Only the process started here is terminated.
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
		$stdoutTask = $process.StandardOutput.ReadToEndAsync()
		$stderrTask = $process.StandardError.ReadToEndAsync()
		$timedOut = $false
		if (-not $process.WaitForExit($TimeoutMilliseconds)) {
			$timedOut = $true
			Stop-OwnedProcessTree -Process $process
			$null = $process.WaitForExit(2000)
		}
		$stdout = ''
		$stderr = ''
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
			timed_out = $timedOut
			exit_code = $exitCode
			stdout = $stdout
			stderr = $stderr
			error = ''
		}
	} catch {
		return [ordered]@{
			started = $false
			timed_out = $false
			exit_code = $null
			stdout = ''
			stderr = ''
			error = $_.Exception.Message
		}
	} finally {
		if ($null -ne $process) { $process.Dispose() }
	}
}

# ---------------------------------------------------------------- input validation

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($PresetFile)) {
	$PresetFile = Join-Path $repoRoot 'templates\CAPTURE-PRESETS.json'
}
$presetFull = [System.IO.Path]::GetFullPath($PresetFile)

$reportFull = [System.IO.Path]::GetFullPath($ReportPath)
if (Test-Path -LiteralPath $reportFull) {
	throw "Invalid input: report path already exists and will not be overwritten: $reportFull"
}
$reportParent = Split-Path -Parent $reportFull
if (-not [string]::IsNullOrWhiteSpace($reportParent) -and -not (Test-Path -LiteralPath $reportParent -PathType Container)) {
	[System.IO.Directory]::CreateDirectory($reportParent) | Out-Null
}

$videoItem = Get-Item -LiteralPath $VideoPath -ErrorAction SilentlyContinue
$videoFull = ''
if ($null -ne $videoItem -and -not $videoItem.PSIsContainer) { $videoFull = [System.IO.Path]::GetFullPath($videoItem.FullName) }

# ---------------------------------------------------------------- state

$checks = [ordered]@{
	preset = 'unverified'
	probe = 'unverified'
	stream_count = 'unverified'
	frame_count = 'unverified'
	duration = 'unverified'
	resolution = 'unverified'
	fps = 'unverified'
}
$failures = New-Object System.Collections.Generic.List[object]
$expectations = [ordered]@{
	frame_count = $null
	duration_seconds = $null
	fps = $null
	width = $null
	height = $null
}
$observed = [ordered]@{
	video_stream_count = $null
	audio_stream_count = $null
	codec = ''
	nb_read_frames = $null
	duration_seconds = $null
	width = $null
	height = $null
	r_frame_rate = ''
	fps = $null
	size_bytes = $null
}
$presetInfo = [ordered]@{
	requested_name = $Preset
	file = $presetFull
	name = $null
	use = ''
}
$probeInfo = [ordered]@{
	requested_path = $FfprobePath
	resolution = 'not_found'
	path = ''
	version = 'unknown'
	exit_code = $null
	timed_out = $false
}

function Add-Failure {
	param([string]$Category, [string]$Detail, [string]$State = 'fail', [string]$Sample = '')
	$script:failures.Add([ordered]@{ category = $Category; detail = $Detail; state = $State; sample = $Sample })
}

function Set-Check {
	param([string]$Name, [string]$State)
	$script:checks[$Name] = $State
}

function Get-OptionalValue {
	param($Value)
	if ($null -eq $Value) { return $null }
	if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
	return $Value
}

function ConvertTo-OptionalInt($Value) {
	if ($null -eq $Value) { return $null }
	$parsedValue = 0
	if ([int]::TryParse(([string]$Value).Trim(), [ref]$parsedValue)) { return $parsedValue }
	return $null
}

function ConvertTo-FrameRate([string]$Value) {
	if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
	if ($Value -match '^\s*([0-9]+)\s*/\s*([0-9]+)\s*$') {
		$numerator = [double]$matches[1]
		$denominator = [double]$matches[2]
		if ($denominator -eq 0) { return $null }
		return ($numerator / $denominator)
	}
	$direct = 0.0
	if ([double]::TryParse($Value, [ref]$direct)) { return $direct }
	return $null
}

# ---------------------------------------------------------------- preset definition

$presetLoaded = $false
if (-not (Test-Path -LiteralPath $presetFull -PathType Leaf)) {
	Set-Check 'preset' 'unverified'
	Add-Failure 'preset_file_missing' "the capture preset definition was not found: $presetFull" 'unverified'
} else {
	$presetData = $null
	# Read as UTF-8 explicitly: Windows PowerShell 5.1 decodes a BOM-less Get-Content -Raw with
	# the ANSI code page, so the Japanese preset descriptions would be mangled before conversion.
	try {
		$presetText = [System.IO.File]::ReadAllText($presetFull, (New-Object System.Text.UTF8Encoding($false, $true)))
		$presetData = $presetText | ConvertFrom-Json
	} catch {
		Add-Failure 'preset_file_invalid' "the capture preset definition could not be parsed: $($_.Exception.Message)" 'unverified'
	}
	if ($null -ne $presetData -and $null -ne $presetData.presets) {
		$matches_ = @($presetData.presets | Where-Object { [string]$_.name -eq $Preset })
		if ($matches_.Count -eq 0) {
			$known = (@($presetData.presets | ForEach-Object { [string]$_.name }) -join ', ')
			Add-Failure 'preset_unknown' "preset '$Preset' is not defined in $presetFull (defined: $known)" 'unverified'
		} elseif ($matches_.Count -gt 1) {
			Add-Failure 'preset_duplicate' "preset '$Preset' is defined $($matches_.Count) times in $presetFull" 'unverified'
		} else {
			$entry = $matches_[0]
			$fpsValue = 0.0
			$durationValue = 0.0
			$widthParsed = 0
			$heightParsed = 0
			$numericOk = $true
			if (-not [int]::TryParse(([string]$entry.width).Trim(), [ref]$widthParsed)) { $numericOk = $false }
			if (-not [int]::TryParse(([string]$entry.height).Trim(), [ref]$heightParsed)) { $numericOk = $false }
			if (-not [double]::TryParse(([string]$entry.fps).Trim(), [ref]$fpsValue)) { $numericOk = $false }
			if (-not [double]::TryParse(([string]$entry.duration_seconds).Trim(), [ref]$durationValue)) { $numericOk = $false }
			if ($numericOk -and $widthParsed -gt 0 -and $heightParsed -gt 0 -and $fpsValue -gt 0 -and $durationValue -gt 0) {
				# The frame count is derived, never read from the file, so a preset cannot declare a
				# frame count that contradicts its own fps and duration.
				$derived = $fpsValue * $durationValue
				if ([Math]::Abs($derived - [Math]::Round($derived)) -gt 0.0001) {
					Add-Failure 'preset_invalid' "preset '$Preset' does not yield a whole frame count: fps $fpsValue x duration $durationValue s = $derived" 'unverified'
				} elseif ($null -ne $entry.frame_count) {
					Add-Failure 'preset_invalid' "preset '$Preset' declares frame_count as well as fps and duration_seconds; the frame count is derived from fps x duration and must not be duplicated in the definition" 'unverified'
				} else {
					$presetInfo.name = [string]$entry.name
					$presetInfo.use = [string]$entry.use
					$expectations.width = $widthParsed
					$expectations.height = $heightParsed
					$expectations.fps = $fpsValue
					$expectations.duration_seconds = $durationValue
					$expectations.frame_count = [int][Math]::Round($derived)
					$expectations.duration_tolerance_seconds = [Math]::Round((1.0 / $fpsValue), 4)
					$presetLoaded = $true
				}
			} else {
				Add-Failure 'preset_invalid' "preset '$Preset' needs positive numeric width, height, fps and duration_seconds" 'unverified'
			}
		}
	}
}
if ($presetLoaded) { Set-Check 'preset' 'pass' }

# ---------------------------------------------------------------- video and decoder

if ([string]::IsNullOrWhiteSpace($videoFull)) {
	Add-Failure 'video_missing' "no encoded video was found at: $VideoPath" 'unverified'
} else {
	$observed.size_bytes = [long](Get-Item -LiteralPath $videoFull).Length
	if ($observed.size_bytes -le 0) {
		Add-Failure 'video_empty' "the encoded video is 0 bytes: $videoFull" 'unverified'
	}
}

if (-not [string]::IsNullOrWhiteSpace($FfprobePath)) {
	if (Test-Path -LiteralPath $FfprobePath -PathType Leaf) {
		$probeInfo.resolution = 'explicit'
		$probeInfo.path = [System.IO.Path]::GetFullPath((Get-Item -LiteralPath $FfprobePath).FullName)
	} else {
		$probeInfo.resolution = 'explicit_path_missing'
	}
} else {
	$discovered = @(Get-Command -Name 'ffprobe' -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
	if ($null -ne $discovered) {
		$probeInfo.resolution = 'path_lookup'
		$probeInfo.path = [System.IO.Path]::GetFullPath($discovered.Source)
	}
}

if ($probeInfo.resolution -eq 'explicit' -or $probeInfo.resolution -eq 'path_lookup') {
	$versionProbe = Invoke-BoundedProcess -FilePath $probeInfo.path -ArgumentList @('-version') -TimeoutMilliseconds ([Math]::Min($ProbeTimeoutMilliseconds, 15000))
	if ($versionProbe.started -and -not $versionProbe.timed_out -and $versionProbe.exit_code -eq 0) {
		$firstLine = @(($versionProbe.stdout -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -First 1
		if (-not [string]::IsNullOrWhiteSpace($firstLine)) { $probeInfo.version = $firstLine.Trim() }
	} elseif ($versionProbe.timed_out) {
		$probeInfo.version = 'unknown (version probe timed out)'
	} else {
		$probeInfo.version = 'unknown (version probe failed)'
	}
} else {
	Add-Failure 'ffprobe_not_found' "ffprobe is neither on PATH nor an existing file, so the video cannot be measured ($($probeInfo.resolution))" 'unverified'
}

# ---------------------------------------------------------------- measurement

$measured = $false
if ([string]::IsNullOrWhiteSpace($videoFull)) {
	# Nothing to probe: a missing artifact is not a measurement, so no probe result is invented.
	Set-Check 'probe' 'unverified'
} elseif ($probeInfo.resolution -eq 'explicit' -or $probeInfo.resolution -eq 'path_lookup') {
	$probe = Invoke-BoundedProcess -FilePath $probeInfo.path -ArgumentList @(
		'-v', 'error',
		'-count_frames',
		'-show_entries', 'stream=index,codec_type,codec_name,width,height,r_frame_rate,nb_read_frames,duration,sample_rate,channels',
		'-show_entries', 'format=duration,size',
		'-of', 'json',
		$videoFull
	) -TimeoutMilliseconds $ProbeTimeoutMilliseconds

	$probeInfo.exit_code = $probe.exit_code
	$probeInfo.timed_out = $probe.timed_out

	if (-not $probe.started) {
		Set-Check 'probe' 'fail'
		Add-Failure 'probe_start_failed' "ffprobe could not be started: $($probe.error)"
	} elseif ($probe.timed_out) {
		Set-Check 'probe' 'unverified'
		Add-Failure 'probe_timeout' "ffprobe did not finish within $ProbeTimeoutMilliseconds ms; the probe was killed and its result is not counted as success" 'unverified'
	} elseif ($probe.exit_code -ne 0) {
		Set-Check 'probe' 'fail'
		$message = ($probe.stderr -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -First 1
		Add-Failure 'probe_failed' "ffprobe exited $($probe.exit_code): $message"
	} else {
		Set-Check 'probe' 'pass'
		$measured = $true
	}
}

$parsed = $null
if ($measured) {
	try {
		$parsed = $probe.stdout | ConvertFrom-Json
	} catch {
		Set-Check 'probe' 'fail'
		Add-Failure 'probe_output_unparsable' "ffprobe exited 0 but its JSON output could not be parsed: $($_.Exception.Message)"
	}
}

if ($measured -and $null -ne $parsed) {
	$streams = @($parsed.streams | Where-Object { $null -ne $_ })
	$videoStreams = @($streams | Where-Object { [string]$_.codec_type -eq 'video' })
	$audioStreams = @($streams | Where-Object { [string]$_.codec_type -eq 'audio' })
	$observed.video_stream_count = $videoStreams.Count
	$observed.audio_stream_count = $audioStreams.Count

	if ($videoStreams.Count -ne 1) {
		Set-Check 'stream_count' 'fail'
		Add-Failure 'stream_count' "$($videoStreams.Count) video stream(s) were found; exactly one encoded video stream is required for a measurable contract" 'fail' (@($videoStreams | ForEach-Object { "#$($_.index)" }) -join ',')
	} else {
		Set-Check 'stream_count' 'pass'
		$video = $videoStreams[0]
		$observed.codec = [string]$video.codec_name
		$observed.width = ConvertTo-OptionalInt $video.width
		$observed.height = ConvertTo-OptionalInt $video.height
		$observed.r_frame_rate = [string]$video.r_frame_rate
		$observed.fps = ConvertTo-FrameRate ([string]$video.r_frame_rate)

		$framesValue = Get-OptionalValue $video.nb_read_frames
		if ($null -eq $framesValue) {
			Set-Check 'frame_count' 'unverified'
			Add-Failure 'frame_count_unreadable' 'ffprobe did not report nb_read_frames for the encoded video, so the frame count is unknown rather than correct' 'unverified'
		} else {
			$observed.nb_read_frames = [int]$framesValue
		}

		$durationValue = Get-OptionalValue $parsed.format.duration
		if ($null -eq $durationValue) { $durationValue = Get-OptionalValue $video.duration }
		if ($null -eq $durationValue) {
			Set-Check 'duration' 'unverified'
			Add-Failure 'duration_unreadable' 'ffprobe reported no duration for the encoded video, so the length is unknown rather than correct' 'unverified'
		} else {
			$observed.duration_seconds = [double]$durationValue
		}

		if ($presetLoaded) {
			if ($null -ne $observed.nb_read_frames) {
				if ($observed.nb_read_frames -eq $expectations.frame_count) {
					Set-Check 'frame_count' 'pass'
				} else {
					Set-Check 'frame_count' 'fail'
					$delta = [int]$observed.nb_read_frames - [int]$expectations.frame_count
					Add-Failure 'frame_count_mismatch' "preset '$Preset' expects $($expectations.frame_count) frame(s) but the encoded video has $($observed.nb_read_frames) (difference $delta)" 'fail' "observed=$($observed.nb_read_frames) expected=$($expectations.frame_count)"
				}
			}

			if ($null -ne $observed.duration_seconds) {
				$tolerance = [double]$expectations.duration_tolerance_seconds
				if ([Math]::Abs($observed.duration_seconds - [double]$expectations.duration_seconds) -le $tolerance) {
					Set-Check 'duration' 'pass'
				} else {
					Set-Check 'duration' 'fail'
					Add-Failure 'duration_mismatch' "preset '$Preset' expects $($expectations.duration_seconds) s but the encoded video lasts $($observed.duration_seconds) s (tolerance $tolerance s)" 'fail' "observed=$($observed.duration_seconds) expected=$($expectations.duration_seconds)"
				}
			}

			if ($null -ne $observed.width -and $null -ne $observed.height) {
				if ($observed.width -eq $expectations.width -and $observed.height -eq $expectations.height) {
					Set-Check 'resolution' 'pass'
				} else {
					Set-Check 'resolution' 'fail'
					Add-Failure 'resolution_mismatch' "preset '$Preset' expects $($expectations.width)x$($expectations.height) but the encoded video is $($observed.width)x$($observed.height)" 'fail' "observed=$($observed.width)x$($observed.height) expected=$($expectations.width)x$($expectations.height)"
				}
			} else {
				Set-Check 'resolution' 'unverified'
				Add-Failure 'resolution_unreadable' 'ffprobe did not report width and height for the encoded video' 'unverified'
			}

			if ($null -ne $observed.fps) {
				if ([Math]::Abs($observed.fps - [double]$expectations.fps) -le 0.001) {
					Set-Check 'fps' 'pass'
				} else {
					Set-Check 'fps' 'fail'
					Add-Failure 'fps_mismatch' "preset '$Preset' expects $($expectations.fps) fps but the encoded video reports $($observed.r_frame_rate) ($($observed.fps) fps)" 'fail' "observed=$($observed.r_frame_rate) expected=$($expectations.fps)"
				}
			} else {
				Set-Check 'fps' 'unverified'
				Add-Failure 'fps_unreadable' "ffprobe did not report a parsable r_frame_rate for the encoded video (got '$($observed.r_frame_rate)')" 'unverified'
			}
		}
	}
}

# ---------------------------------------------------------------- verdict

$failedChecks = @($checks.Keys | Where-Object { $checks[$_] -eq 'fail' })
$unverifiedChecks = @($checks.Keys | Where-Object { $checks[$_] -ne 'pass' -and $checks[$_] -ne 'fail' })
$failFailures = @($failures | Where-Object { $_.state -eq 'fail' })

$verdict = 'pass'
if ($failedChecks.Count -gt 0 -or $failFailures.Count -gt 0) {
	$verdict = 'fail'
} elseif ($unverifiedChecks.Count -gt 0 -or $failures.Count -gt 0) {
	$verdict = 'unverified'
}

$report = [ordered]@{
	schema_version = 1
	tool = 'scripts/Measure-UECaptureEncode.ps1'
	generated_at_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
	scope = 'encoded_mp4_contract_only'
	preset = $presetInfo
	preset_definition = [ordered]@{
		rule = 'frame_count = fps x duration_seconds'
		source = $presetFull
		note = 'The expected frame count, duration, resolution and fps are derived from the shared preset definition; this tool never takes hand-written expectations.'
	}
	input = [ordered]@{
		video_path = $videoFull
		video_exists = (-not [string]::IsNullOrWhiteSpace($videoFull))
		size_bytes = $observed.size_bytes
	}
	expectations = $expectations
	observed = $observed
	decoder = $probeInfo
	checks = $checks
	failures = @($failures | ForEach-Object { $_ })
	artifact_verdict = $verdict
	unverified_scope = @(
		'UE5.8.4 real MRQ render',
		'whether the source PNG sequence had the expected index range (Measure-UERenderArtifacts.ps1 owns that contract)',
		'visual review of first/middle/last frames and full playback',
		'audio existence is not audio review',
		'loop seam review',
		'video quality (crf/bitrate) is not assessed here'
	)
	notes = @(
		'This report covers the encoded MP4 only; it is not a render, playback, audio or loop result.',
		'ffmpeg -frames:v is an output upper bound. A short source sequence is encoded short with exit 0, which is why the frame count is checked here rather than inferred from the encode command.'
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
Write-Output ("PRESET: {0} (frame_count={1} duration={2}s {3}x{4} {5}fps)" -f $presetInfo.name, $expectations.frame_count, $expectations.duration_seconds, $expectations.width, $expectations.height, $expectations.fps)
Write-Output ("CHECKS: preset={0} probe={1} stream_count={2} frame_count={3} duration={4} resolution={5} fps={6}" -f $checks.preset, $checks.probe, $checks.stream_count, $checks.frame_count, $checks.duration, $checks.resolution, $checks.fps)
Write-Output ("FFPROBE: {0} {1}" -f $probeInfo.resolution, $probeInfo.version)
Write-Output ("OBSERVED: frames={0} duration={1} size={2}x{3} r_frame_rate={4} video_streams={5} audio_streams={6}" -f $observed.nb_read_frames, $observed.duration_seconds, $observed.width, $observed.height, $observed.r_frame_rate, $observed.video_stream_count, $observed.audio_stream_count)
foreach ($failure in $failures) {
	Write-Output ("FAILURE: {0} [{1}] - {2}" -f $failure.category, $failure.state, $failure.detail)
}
Write-Output "REPORT: $reportFull"

if ($verdict -eq 'pass') { exit 0 }
if ($verdict -eq 'fail') { exit 1 }
exit 2
