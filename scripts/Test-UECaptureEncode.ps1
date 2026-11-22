[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$productionRoot = Join-Path $repoRoot 'Production'
$measureScript = Join-Path $PSScriptRoot 'Measure-UECaptureEncode.ps1'
$planScript = Join-Path $PSScriptRoot 'Get-UECaptureEncodePlan.ps1'
$presetFile = Join-Path $repoRoot 'templates\CAPTURE-PRESETS.json'
$initialCheckoutStatus = @(& git -C $repoRoot status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0) { throw 'Could not record the developer checkout status before testing.' }

$testId = [Guid]::NewGuid().ToString('N')
$fixtureRoot = Join-Path $productionRoot ('.capture-encode-test-' + $testId)
$reportRoot = Join-Path $fixtureRoot 'reports'
$sourceRoot = Join-Path $fixtureRoot 'sources'
$videoRoot = Join-Path $fixtureRoot 'videos'
$reportCounter = 0
# Taken before any fixture exists: every fixture written afterwards belongs to "this render attempt".
$suiteStartUtc = [DateTime]::UtcNow.AddSeconds(-2).ToString('o')

function Assert-True([bool]$Condition, [string]$Message) {
	if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function New-ReportPath([string]$Label) {
	$script:reportCounter++
	return (Join-Path $reportRoot ("{0:D3}-{1}.json" -f $script:reportCounter, $Label))
}

function Invoke-Tool {
	param([string]$Script, [hashtable]$Bound)
	$captured = New-Object System.Collections.Generic.List[string]
	$exitCode = $null
	$threw = $false
	$errorMessage = ''
	try {
		& $Script @Bound 2>&1 | ForEach-Object { $captured.Add([string]$_) }
		$exitCode = $LASTEXITCODE
	} catch {
		$threw = $true
		$errorMessage = $_.Exception.Message
	}
	return [pscustomobject]@{
		ExitCode = $exitCode
		Threw = $threw
		Error = $errorMessage
		Output = ($captured -join "`n")
	}
}

function Invoke-External {
	param([string]$FilePath, [string[]]$ArgumentList)
	# Windows PowerShell 5.1 turns native stderr into an error record, which 'Stop' would throw. The
	# exit code is what is asserted, so stderr is only captured here.
	$ErrorActionPreference = 'Continue'
	$captured = New-Object System.Collections.Generic.List[string]
	& $FilePath @ArgumentList 2>&1 | ForEach-Object { $captured.Add([string]$_) }
	$exitCode = $LASTEXITCODE
	return [pscustomobject]@{ ExitCode = $exitCode; Output = ($captured -join "`n") }
}

function Read-Report([string]$Path) {
	Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "report was created: $Path"
	return [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
}

function Get-FailureCategories($Report) {
	return (@($Report.failures | ForEach-Object { [string]$_.category }))
}

# ---------------------------------------------------------------- preset source of truth

function Read-Utf8Json([string]$Path) {
	# Windows PowerShell 5.1 decodes a BOM-less Get-Content -Raw with the ANSI code page, which
	# mangles the Japanese preset descriptions before ConvertFrom-Json sees them.
	return [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false, $true))) | ConvertFrom-Json
}

function Read-Preset([string]$Name) {
	$data = Read-Utf8Json $presetFile
	$entry = @($data.presets | Where-Object { [string]$_.name -eq $Name })
	Assert-True ($entry.Count -eq 1) "preset '$Name' is defined exactly once in templates/CAPTURE-PRESETS.json"
	$item = $entry[0]
	Assert-True ($null -eq $item.frame_count) "preset '$Name' does not declare frame_count; it is derived from fps x duration"
	$width = [int]$item.width
	$height = [int]$item.height
	$fps = [double]$item.fps
	$duration = [double]$item.duration_seconds
	$derived = $fps * $duration
	Assert-True ([Math]::Abs($derived - [Math]::Round($derived)) -lt 0.0001) "preset '$Name' yields a whole frame count from fps x duration"
	return [pscustomobject]@{
		Name = $Name
		Width = $width
		Height = $height
		Fps = $fps
		Duration = $duration
		FrameCount = [int][Math]::Round($derived)
	}
}

$vertical = Read-Preset 'vertical'
$landscape = Read-Preset 'landscape'
Assert-True ($vertical.FrameCount -ne $landscape.FrameCount) 'the two presets differ in frame count, so one command cannot satisfy both'
Assert-True ($vertical.Width -ne $landscape.Width) 'the two presets differ in resolution'

# ---------------------------------------------------------------- fixtures

# The fixtures are synthetic colour ramps rendered by ffmpeg's testsrc2, not render results. The
# source images are made small and scaled up at encode time so the suite stays fast; the encoded
# frame counts and durations are what the contract checks.
function Invoke-EncodeFixture {
	param(
		[pscustomobject]$Preset,
		[int]$SourceFrames,
		[int]$FrameLimit,
		[int]$EncodeFps,
		[string]$Name,
		[string[]]$ExtraArguments = @()
	)
	$sourceDir = Join-Path $sourceRoot $Name
	[System.IO.Directory]::CreateDirectory($sourceDir) | Out-Null
	$generate = Invoke-External -FilePath $script:FfmpegPath -ArgumentList @(
		'-hide_banner', '-loglevel', 'error', '-n',
		'-f', 'lavfi', '-i', ("testsrc2=size={0}x{1}:rate=30" -f ($Preset.Width / 10), ($Preset.Height / 10)),
		'-frames:v', "$SourceFrames", '-start_number', '0',
		(Join-Path $sourceDir '%06d.png')
	)
	Assert-True ($generate.ExitCode -eq 0) "fixture source for '$Name' was generated (ffmpeg exited $($generate.ExitCode)): $($generate.Output)"

	$videoPath = Join-Path $videoRoot ("$Name.mp4")
	$arguments = @(
		'-hide_banner', '-loglevel', 'error', '-n',
		'-framerate', "$EncodeFps", '-start_number', '0',
		'-i', (Join-Path $sourceDir '%06d.png'),
		'-frames:v', "$FrameLimit"
	) + $ExtraArguments + @(
		'-vf', ("scale={0}:{1}" -f $Preset.Width, $Preset.Height),
		'-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '28', '-preset', 'veryfast',
		'-movflags', '+faststart',
		$videoPath
	)
	$encode = Invoke-External -FilePath $script:FfmpegPath -ArgumentList $arguments
	return [pscustomobject]@{
		SourceFrames = $SourceFrames
		FrameLimit = $FrameLimit
		EncodeFps = $EncodeFps
		VideoPath = $videoPath
		ExitCode = $encode.ExitCode
		Output = $encode.Output
		SourceDirectory = $sourceDir
	}
}

function Get-VideoHash([string]$Path) {
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
	return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-ProductionResidue {
	# .gitignore excludes Production/* from `git status --untracked-files=all`, so an ignored leftover
	# from an interrupted run is invisible to the checkout comparison at the end of the suite. This
	# suite reports only names it creates itself, so a developer's generated project does not block it.
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
		if (-not $entry.Name.StartsWith('.capture-encode-test-', [System.StringComparison]::Ordinal)) { continue }
		$violations.Add("Production/$($entry.Name): unexpected entry (ignored by .gitignore, so git status does not report it)")
	}
	return $violations.ToArray()
}

# ---------------------------------------------------------------- tool availability

$script:FfmpegPath = ''
$script:FfprobePath = ''
foreach ($name in @('ffmpeg', 'ffprobe')) {
	$found = @(Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
	if ($null -eq $found) {
		# A suite that silently passes without the tools it needs is the defect being repaired here.
		Write-Output "UNVERIFIED: $name is not on PATH, so the encode contract cannot be exercised on this host (nothing was verified)"
		Write-Output "SUITE_EXIT=2"
		exit 2
	}
	$full = [System.IO.Path]::GetFullPath($found.Source)
	if ($name -eq 'ffmpeg') { $script:FfmpegPath = $full } else { $script:FfprobePath = $full }
}
Write-Output ("TOOLS: ffmpeg={0} ffprobe={1}" -f $script:FfmpegPath, $script:FfprobePath)
$ffmpegBanner = @((Invoke-External -FilePath $script:FfmpegPath -ArgumentList @('-version')).Output -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
Write-Output ("FFMPEG-VERSION: {0}" -f $ffmpegBanner)

$initialProductionResidue = @(Get-ProductionResidue)
Assert-True ($initialProductionResidue.Count -eq 0) ("Production/ holds only the tracked placeholder before testing: " + ($initialProductionResidue -join '; '))

$suiteError = $null
$cleanupFailures = New-Object System.Collections.Generic.List[string]
try {
	[System.IO.Directory]::CreateDirectory($reportRoot) | Out-Null
	[System.IO.Directory]::CreateDirectory($videoRoot) | Out-Null

	# ============================================================ group 1: the plan derives every number from the preset
	# The documented commands must not carry their own copy of the frame count. If a preset changes,
	# the printed command has to change with it.
	$verticalPlan = Invoke-Tool -Script $planScript -Bound @{ Preset = 'vertical'; Format = 'json' }
	Assert-True (-not $verticalPlan.Threw) "the vertical plan did not throw: $($verticalPlan.Error)"
	Assert-True ($verticalPlan.ExitCode -eq 0) "the vertical plan exits 0, got $($verticalPlan.ExitCode): $($verticalPlan.Output)"
	$verticalPlanData = $verticalPlan.Output | ConvertFrom-Json
	Assert-True ($verticalPlanData.expectations.frame_count -eq $vertical.FrameCount) "the vertical plan derives $($vertical.FrameCount) frames from the preset"
	Assert-True ($verticalPlanData.expectations.end_number_exclusive -eq $vertical.FrameCount) 'the vertical plan range is end-exclusive over the derived frame count'
	Assert-True ($verticalPlanData.expectations.width -eq $vertical.Width -and $verticalPlanData.expectations.height -eq $vertical.Height) 'the vertical plan resolution comes from the preset'
	Assert-True ($verticalPlanData.commands.ffmpeg.Contains("-frames:v $($vertical.FrameCount)")) 'the vertical ffmpeg command uses the derived frame count as -frames:v'
	Assert-True ($landscapePlanData.commands.ffmpeg -notmatch "-frames:v $($vertical.FrameCount) ") 'the landscape command never carries the vertical preset frame count, which is how the documented command truncated a 300-frame render'
	Assert-True ($verticalPlanData.commands.frames_check.Contains("-EndNumberExclusive $($vertical.FrameCount)")) 'the image-sequence check uses the same end-exclusive range'
	Assert-True ($verticalPlanData.commands.inspect.Contains('Measure-UECaptureEncode.ps1')) 'the plan points at the encode inspector'
	Assert-True ($verticalPlanData.commands.inspect.Contains('-RenderStartedUtc $renderStartedUtc') -and $verticalPlanData.commands.inspect.Contains('-FramesDirectory')) 'the inspect command carries the render marker and the frame directory'
	Assert-True ($verticalPlanData.commands.render_marker.Contains('$renderStartedUtc =')) 'the plan prints the command that takes the render marker'

	$landscapePlan = Invoke-Tool -Script $planScript -Bound @{ Preset = 'landscape'; Format = 'json' }
	Assert-True (-not $landscapePlan.Threw) "the landscape plan did not throw: $($landscapePlan.Error)"
	$landscapePlanData = $landscapePlan.Output | ConvertFrom-Json
	Assert-True ($landscapePlanData.expectations.frame_count -eq $landscape.FrameCount) "the landscape plan derives $($landscape.FrameCount) frames from the preset"
	Assert-True ($landscapePlanData.commands.ffmpeg.Contains("-frames:v $($landscape.FrameCount)")) 'the landscape ffmpeg command uses the landscape frame count'
	Assert-True ($verticalPlanData.commands.ffmpeg -ne $landscapePlanData.commands.ffmpeg) 'the two presets produce different encode commands'

	$unknownPlan = Invoke-Tool -Script $planScript -Bound @{ Preset = 'no-such-preset' }
	Assert-True ($unknownPlan.Threw -or $unknownPlan.ExitCode -ne 0) 'an undefined preset does not produce a command'

	# The retired command is the defect: the docs' only encode line pinned 240 frames for both presets.
	foreach ($document in @('docs\05-qa.md', 'README.md')) {
		$text = [System.IO.File]::ReadAllText((Join-Path $repoRoot $document))
		Assert-True (-not $text.Contains('-frames:v 240')) "$document does not repeat the vertical frame count as a literal encode limit"
		Assert-True ($text.Contains('CAPTURE-PRESETS.json')) "$document points at the single preset definition"
	}
	Write-Output 'PASS: both presets derive their frame count, range and command from one definition, and the documents do not restate the numbers'

	# ============================================================ group 2: (a) the old 240-frame command truncates a 300-frame preset
	# This is the reported defect: the encode exits 0, the MP4 is 240 frames / 8 s long, and the
	# ffprobe numbers are internally consistent. Only the preset expectation exposes the loss.
	$a = Invoke-EncodeFixture -Preset $landscape -SourceFrames $landscape.FrameCount -FrameLimit $vertical.FrameCount -EncodeFps 30 -Name 'a-truncated'
	Assert-True ($a.ExitCode -eq 0) "the truncating encode exits 0 like the documented command did, got $($a.ExitCode): $($a.Output)"
	$aHashBefore = Get-VideoHash $a.VideoPath
	$aReport = New-ReportPath 'a-truncated'
	$aResult = Invoke-Tool -Script $measureScript -Bound @{ Preset = 'landscape'; VideoPath = $a.VideoPath; ReportPath = $aReport }
	Assert-True (-not $aResult.Threw) "the landscape inspection of the truncated video did not throw: $($aResult.Error)"
	Assert-True ($aResult.ExitCode -eq 1) "240 frames against the 300-frame landscape preset exits 1, got $($aResult.ExitCode): $($aResult.Output)"
	$aData = Read-Report $aReport
	Assert-True ($aData.artifact_verdict -eq 'fail') 'the truncated video verdict is fail, not pass and not unverified'
	Assert-True ($aData.checks.frame_count -eq 'fail') 'the frame count check fails'
	Assert-True ($aData.observed.nb_read_frames -eq $vertical.FrameCount) 'report records the observed 240 frames instead of hiding them'
	Assert-True ($aData.expectations.frame_count -eq $landscape.FrameCount) 'report records the preset expectation of 300 frames'
	Assert-True (@(Get-FailureCategories $aData) -contains 'frame_count_mismatch') 'report names frame_count_mismatch'
	Assert-True ([string]($aData.preset.name) -ceq 'landscape') 'report records which preset was applied'
	Assert-True ($aData.decoder.resolution -eq 'path_lookup' -or $aData.decoder.resolution -eq 'explicit') 'report records how ffprobe was resolved'
	Assert-True ((Get-VideoHash $a.VideoPath) -ceq $aHashBefore) 'the inspector did not modify the video it inspected'
	Write-Output ("PASS: a 300-frame preset encoded with -frames:v {0} exits 0 for ffmpeg, is detected as {1} frames, and fails with frame_count_mismatch" -f $vertical.FrameCount, $aData.observed.nb_read_frames)

	# ============================================================ group 3: (b) a correct landscape encode passes
	$b = Invoke-EncodeFixture -Preset $landscape -SourceFrames $landscape.FrameCount -FrameLimit $landscape.FrameCount -EncodeFps 30 -Name 'b-correct'
	Assert-True ($b.ExitCode -eq 0) "the correct landscape encode exited 0, got $($b.ExitCode): $($b.Output)"
	$bReport = New-ReportPath 'b-correct'
	$bResult = Invoke-Tool -Script $measureScript -Bound @{ Preset = 'landscape'; VideoPath = $b.VideoPath; ReportPath = $bReport; RenderStartedUtc = $suiteStartUtc; FramesDirectory = $b.SourceDirectory }
	Assert-True (-not $bResult.Threw) "the landscape inspection of the correct video did not throw: $($bResult.Error)"
	Assert-True ($bResult.ExitCode -eq 0) "a correct landscape encode exits 0, got $($bResult.ExitCode): $($bResult.Output)"
	$bData = Read-Report $bReport
	Assert-True ($bData.artifact_verdict -eq 'pass') 'the correct landscape video verdict is pass'
	foreach ($check in @('preset', 'probe', 'stream_count', 'frame_count', 'duration', 'resolution', 'fps', 'render_attempt', 'source_frames_fresh')) {
		Assert-True ($bData.checks.$check -eq 'pass') "correct landscape check '$check' is pass, got '$($bData.checks.$check)'"
	}
	Assert-True ($bData.observed.nb_read_frames -eq $landscape.FrameCount) 'the correct landscape video has 300 frames'
	Assert-True ([Math]::Abs([double]$bData.observed.duration_seconds - $landscape.Duration) -lt 0.1) 'the correct landscape video lasts 10 s'
	Assert-True (@($bData.failures).Count -eq 0) 'the correct landscape video records no failure'
	Write-Output 'PASS: a correct 300-frame 1920x1080 encode passes the same contract that rejects the truncated one'

	# ============================================================ group 4: the vertical preset still passes at its own length
	$bVertical = Invoke-EncodeFixture -Preset $vertical -SourceFrames $vertical.FrameCount -FrameLimit $vertical.FrameCount -EncodeFps 30 -Name 'b-vertical'
	Assert-True ($bVertical.ExitCode -eq 0) "the vertical encode exited 0, got $($bVertical.ExitCode): $($bVertical.Output)"
	$bVerticalReport = New-ReportPath 'b-vertical'
	$bVerticalResult = Invoke-Tool -Script $measureScript -Bound @{ Preset = 'vertical'; VideoPath = $bVertical.VideoPath; ReportPath = $bVerticalReport; RenderStartedUtc = $suiteStartUtc; FramesDirectory = $bVertical.SourceDirectory }
	Assert-True ($bVerticalResult.ExitCode -eq 0) "a correct vertical encode exits 0, got $($bVerticalResult.ExitCode): $($bVerticalResult.Output)"
	$bVerticalData = Read-Report $bVerticalReport
	Assert-True ($bVerticalData.artifact_verdict -eq 'pass') 'the correct vertical video verdict is pass'
	Assert-True ($bVerticalData.observed.nb_read_frames -eq $vertical.FrameCount) 'the correct vertical video has 240 frames'
	Assert-True ((Get-VideoHash $bVertical.VideoPath) -cne $aHashBefore) 'the vertical fixture is a different video from the landscape fixture'
	Write-Output ("PASS: the vertical preset passes at {0} frames and {1}x{2}, and is not silently satisfied by a landscape encode" -f $vertical.FrameCount, $vertical.Width, $vertical.Height)

	# ============================================================ group 5: (c) one frame short is a failure
	$c = Invoke-EncodeFixture -Preset $landscape -SourceFrames ($landscape.FrameCount - 1) -FrameLimit $landscape.FrameCount -EncodeFps 30 -Name 'c-short-one'
	Assert-True ($c.ExitCode -eq 0) "the one-frame-short encode exits 0, got $($c.ExitCode): $($c.Output)"
	$cReport = New-ReportPath 'c-short-one'
	$cResult = Invoke-Tool -Script $measureScript -Bound @{ Preset = 'landscape'; VideoPath = $c.VideoPath; ReportPath = $cReport }
	Assert-True ($cResult.ExitCode -eq 1) "299 frames against the 300-frame preset exits 1, got $($cResult.ExitCode): $($cResult.Output)"
	$cData = Read-Report $cReport
	Assert-True ($cData.observed.nb_read_frames -eq ($landscape.FrameCount - 1)) 'report records 299 observed frames'
	Assert-True (@(Get-FailureCategories $cData) -contains 'frame_count_mismatch') 'a single missing frame is reported as frame_count_mismatch'
	Write-Output ("PASS: a sequence one frame short of {0} fails, so the tolerance for a missing frame is zero" -f $landscape.FrameCount)

	# ============================================================ group 6: duration is checked independently of the frame count
	# 300 frames fed at 25 fps keep their count and become 12 s: the frame count check passes and
	# the duration and fps checks fail, so the length contract cannot really be counting frames.
	$duration = Invoke-EncodeFixture -Preset $landscape -SourceFrames $landscape.FrameCount -FrameLimit $landscape.FrameCount -EncodeFps 25 -Name 'duration-only'
	Assert-True ($duration.ExitCode -eq 0) "the slow encode exits 0, got $($duration.ExitCode): $($duration.Output)"
	$durationReport = New-ReportPath 'duration-only'
	$durationResult = Invoke-Tool -Script $measureScript -Bound @{ Preset = 'landscape'; VideoPath = $duration.VideoPath; ReportPath = $durationReport }
	Assert-True ($durationResult.ExitCode -eq 1) "a 12 s video against the 10 s preset exits 1, got $($durationResult.ExitCode): $($durationResult.Output)"
	$durationData = Read-Report $durationReport
	Assert-True ($durationData.checks.frame_count -eq 'pass') 'the frame count check still passes for an over-long video'
	Assert-True ($durationData.checks.duration -eq 'fail') 'the duration check fails for an over-long video'
	Assert-True ($durationData.checks.fps -eq 'fail') 'the fps check fails for a 25 fps video against a 30 fps preset'
	Assert-True (@(Get-FailureCategories $durationData) -contains 'duration_mismatch') 'the report names duration_mismatch'
	Write-Output 'PASS: a correct frame count with the wrong fps and duration still fails, so length is not inferred from the frame count alone'

	# ============================================================ group 7: (d) a missing ffprobe is never a pass
	$missingReport = New-ReportPath 'd-missing-ffprobe'
	$missingResult = Invoke-Tool -Script $measureScript -Bound @{
		Preset        = 'landscape'
		VideoPath     = $b.VideoPath
		ReportPath    = $missingReport
		FfprobePath   = (Join-Path $fixtureRoot 'no-such-ffprobe.exe')
	}
	Assert-True (-not $missingResult.Threw) "a missing ffprobe did not throw out of the inspector: $($missingResult.Error)"
	Assert-True ($missingResult.ExitCode -eq 2) "a missing ffprobe exits 2 (unverified), got $($missingResult.ExitCode): $($missingResult.Output)"
	$missingData = Read-Report $missingReport
	Assert-True ($missingData.artifact_verdict -eq 'unverified') 'a missing ffprobe is unverified, not pass and not fail'
	Assert-True (@(Get-FailureCategories $missingData) -contains 'ffprobe_not_found') 'the report names ffprobe_not_found'
	Assert-True ($missingData.checks.frame_count -ne 'pass') 'the frame count is not claimed as pass without a measurement'
	Assert-True ($missingData.observed.nb_read_frames -eq $null) 'no frame count is invented without a measurement'
	Write-Output 'PASS: without ffprobe the inspector reports unverified with ffprobe_not_found and never pass'

	# ============================================================ group 8: (e) a single video stream is required
	$twoStreamPath = Join-Path $videoRoot 'e-two-streams.mp4'
	$twoStream = Invoke-External -FilePath $script:FfmpegPath -ArgumentList @(
		'-hide_banner', '-loglevel', 'error', '-n',
		'-i', $b.VideoPath, '-i', $b.VideoPath,
		'-map', '0:v:0', '-map', '1:v:0',
		'-c', 'copy', '-movflags', '+faststart', $twoStreamPath
	)
	Assert-True ($twoStream.ExitCode -eq 0) "the two-stream fixture was built (ffmpeg exited $($twoStream.ExitCode)): $($twoStream.Output)"
	$twoStreamReport = New-ReportPath 'e-two-streams'
	$twoStreamResult = Invoke-Tool -Script $measureScript -Bound @{ Preset = 'landscape'; VideoPath = $twoStreamPath; ReportPath = $twoStreamReport }
	Assert-True ($twoStreamResult.ExitCode -eq 1) "two video streams exit 1, got $($twoStreamResult.ExitCode): $($twoStreamResult.Output)"
	$twoStreamData = Read-Report $twoStreamReport
	Assert-True ($twoStreamData.checks.stream_count -eq 'fail') 'the stream count check fails'
	Assert-True ($twoStreamData.observed.video_stream_count -eq 2) 'report records the two video streams it found'
	Assert-True (@(Get-FailureCategories $twoStreamData) -contains 'stream_count') 'the report names the stream_count failure'
	Assert-True ($twoStreamData.checks.frame_count -ne 'pass') 'a video with two streams never passes the frame count check'
	Write-Output 'PASS: a file with two video streams fails instead of being measured on whichever stream came first'

	# ============================================================ group 9: (f) an undefined preset and a missing video never pass
	$unknownReport = New-ReportPath 'f-unknown-preset'
	$unknownResult = Invoke-Tool -Script $measureScript -Bound @{ Preset = 'no-such-preset'; VideoPath = $b.VideoPath; ReportPath = $unknownReport }
	Assert-True ($unknownResult.ExitCode -ne 0) "an undefined preset never exits 0, got $($unknownResult.ExitCode): $($unknownResult.Output)"
	$unknownData = Read-Report $unknownReport
	Assert-True ($unknownData.artifact_verdict -ne 'pass') 'an undefined preset is not a pass'
	Assert-True (@(Get-FailureCategories $unknownData) -contains 'preset_unknown') 'the report names preset_unknown and lists the defined presets'

	$missingVideoReport = New-ReportPath 'f-missing-video'
	$missingVideoResult = Invoke-Tool -Script $measureScript -Bound @{ Preset = 'landscape'; VideoPath = (Join-Path $videoRoot 'no-such-video.mp4'); ReportPath = $missingVideoReport }
	Assert-True ($missingVideoResult.ExitCode -eq 2) "a missing video exits 2 (unverified), got $($missingVideoResult.ExitCode): $($missingVideoResult.Output)"
	$missingVideoData = Read-Report $missingVideoReport
	Assert-True (@(Get-FailureCategories $missingVideoData) -contains 'video_missing') 'the report names video_missing'
	Assert-True ($missingVideoData.artifact_verdict -ne 'pass') 'a missing video is not a pass'

	$existingReport = $bReport
	$overwriteResult = Invoke-Tool -Script $measureScript -Bound @{ Preset = 'landscape'; VideoPath = $b.VideoPath; ReportPath = $existingReport }
	Assert-True ($overwriteResult.Threw -or $overwriteResult.ExitCode -ne 0) 'an existing report path is refused instead of overwritten'
	Assert-True ((Read-Report $existingReport).artifact_verdict -eq 'pass') 'the refused overwrite left the original report intact'
	Write-Output 'PASS: an undefined preset, a missing video and an existing report path all fail closed'

	# ============================================================ group 10: the preset definition itself is validated
	$duplicatePresetFile = Join-Path $fixtureRoot 'presets-with-frame-count.json'
	$duplicateData = Read-Utf8Json $presetFile
	$duplicateEntry = $duplicateData.presets | Where-Object { [string]$_.name -eq 'landscape' }
	$duplicateEntry | Add-Member -NotePropertyName 'frame_count' -NotePropertyValue 300 -Force
	[System.IO.File]::WriteAllText($duplicatePresetFile, ($duplicateData | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
	$duplicateReport = New-ReportPath 'g-duplicate-frame-count'
	$duplicateResult = Invoke-Tool -Script $measureScript -Bound @{
		Preset     = 'landscape'
		VideoPath  = $b.VideoPath
		ReportPath = $duplicateReport
		PresetFile = $duplicatePresetFile
	}
	Assert-True ($duplicateResult.ExitCode -ne 0) "a preset that restates its frame count never exits 0, got $($duplicateResult.ExitCode): $($duplicateResult.Output)"
	$duplicateDataReport = Read-Report $duplicateReport
	Assert-True (@(Get-FailureCategories $duplicateDataReport) -contains 'preset_invalid') 'the report names preset_invalid for a duplicated frame count'

	$partialPresetFile = Join-Path $fixtureRoot 'presets-partial-second.json'
	$partialData = Read-Utf8Json $presetFile
	# 30 fps x 10.25 s = 307.5, which is not a whole frame count, so the definition itself is invalid.
	($partialData.presets | Where-Object { [string]$_.name -eq 'landscape' }) | Add-Member -NotePropertyName 'duration_seconds' -NotePropertyValue 10.25 -Force
	[System.IO.File]::WriteAllText($partialPresetFile, ($partialData | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
	$partialReport = New-ReportPath 'g-partial-frame-count'
	$partialResult = Invoke-Tool -Script $measureScript -Bound @{
		Preset     = 'landscape'
		VideoPath  = $b.VideoPath
		ReportPath = $partialReport
		PresetFile = $partialPresetFile
	}
	Assert-True ($partialResult.ExitCode -ne 0) "a preset whose fps x duration is not a whole frame count never exits 0, got $($partialResult.ExitCode): $($partialResult.Output)"
	$partialDataReport = Read-Report $partialReport
	Assert-True (@(Get-FailureCategories $partialDataReport) -contains 'preset_invalid') 'the report names preset_invalid for a non-integral frame count'
	Write-Output 'PASS: the preset definition rejects a duplicated or non-integral frame count instead of quietly trusting it'

	# ============================================================ group 11: which render attempt made the MP4
	# `ffmpeg -n` exits 0 without writing when the output exists. A re-render followed by the same
	# encode line therefore leaves the previous MP4 in place, and its frame count and duration still
	# match the expectation. Only the modification time against a render-start marker exposes it.
	function Set-FileAge([string[]]$Paths, [int]$HoursOld) {
		$aged = [DateTime]::UtcNow.AddHours(-$HoursOld)
		foreach ($path in $Paths) { [System.IO.File]::SetLastWriteTimeUtc($path, $aged) }
	}

	function New-TestFrames {
		param([string]$Directory, [int]$Count, [pscustomobject]$Preset, [string]$Source)
		[System.IO.Directory]::CreateDirectory($Directory) | Out-Null
		$result = Invoke-External -FilePath $script:FfmpegPath -ArgumentList @(
			'-hide_banner', '-loglevel', 'error', '-y',
			'-f', 'lavfi', '-i', ("{0}=size={1}x{2}:rate=30" -f $Source, ($Preset.Width / 10), ($Preset.Height / 10)),
			'-frames:v', "$Count", '-start_number', '0',
			(Join-Path $Directory '%06d.png')
		)
		Assert-True ($result.ExitCode -eq 0) "test frames were generated in $Directory (ffmpeg exited $($result.ExitCode)): $($result.Output)"
	}

	function Invoke-TestEncode {
		param([string]$Directory, [int]$FrameLimit, [string]$VideoPath, [pscustomobject]$Preset)
		return Invoke-External -FilePath $script:FfmpegPath -ArgumentList @(
			'-hide_banner', '-loglevel', 'error', '-n',
			'-framerate', '30', '-start_number', '0',
			'-i', (Join-Path $Directory '%06d.png'),
			'-frames:v', "$FrameLimit",
			'-vf', ("scale={0}:{1}" -f $Preset.Width, $Preset.Height),
			'-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '28', '-preset', 'veryfast',
			'-movflags', '+faststart',
			$VideoPath
		)
	}

	# (b) re-render, then the same encode line: ffmpeg exits 0, the old MP4 stays, the probe still matches.
	$v1 = Invoke-EncodeFixture -Preset $vertical -SourceFrames $vertical.FrameCount -FrameLimit $vertical.FrameCount -EncodeFps 30 -Name 'p-v1'
	Assert-True ($v1.ExitCode -eq 0) "the first attempt encoded, got $($v1.ExitCode): $($v1.Output)"
	Set-FileAge -Paths (@($v1.VideoPath) + @(Get-ChildItem -LiteralPath $v1.SourceDirectory -File | ForEach-Object { $_.FullName })) -HoursOld 1
	$v1Hash = Get-VideoHash $v1.VideoPath
	$attemptTwoMarker = [DateTime]::UtcNow.ToString('o')
	Remove-Item -LiteralPath $v1.SourceDirectory -Recurse -Force
	New-TestFrames -Directory $v1.SourceDirectory -Count 60 -Preset $vertical -Source 'smptebars'
	$reencode = Invoke-TestEncode -Directory $v1.SourceDirectory -FrameLimit $vertical.FrameCount -VideoPath $v1.VideoPath -Preset $vertical
	Assert-True ($reencode.ExitCode -eq 0) "the second encode with -n exits 0 even though it wrote nothing (the reported defect), got $($reencode.ExitCode)"
	Assert-True ($reencode.Output -match 'already exists') "ffmpeg says on stderr that the output already exists: $($reencode.Output)"
	Assert-True ((Get-VideoHash $v1.VideoPath) -ceq $v1Hash) 'the second encode left the first attempt MP4 byte-identical'
	$staleReport = New-ReportPath 'p-stale-mp4'
	$staleResult = Invoke-Tool -Script $measureScript -Bound @{ Preset = 'vertical'; VideoPath = $v1.VideoPath; ReportPath = $staleReport; RenderStartedUtc = $attemptTwoMarker; FramesDirectory = $v1.SourceDirectory }
	Assert-True ($staleResult.ExitCode -eq 1) "an MP4 older than the render marker exits 1, got $($staleResult.ExitCode): $($staleResult.Output)"
	$staleData = Read-Report $staleReport
	Assert-True ($staleData.artifact_verdict -eq 'fail') 'the stale MP4 verdict is fail'
	Assert-True ($staleData.checks.frame_count -eq 'pass' -and $staleData.checks.duration -eq 'pass') 'the stale MP4 still matches the 240 frame / 8 s expectation, so the count check alone would have passed it'
	Assert-True ($staleData.checks.render_attempt -eq 'fail') 'the render_attempt check fails'
	Assert-True (@(Get-FailureCategories $staleData) -contains 'video_stale') 'the report names video_stale'
	Assert-True ($staleData.checks.source_frames_fresh -eq 'pass') 'the 60 frames of the second attempt are fresh, so only the MP4 is stale'
	Write-Output 'PASS: re-running the encode line over an existing MP4 exits 0 and keeps the old file, and the inspector fails it as video_stale although the frame count and duration match'

	# (c) v1 leftovers under a few v2 frames: the count is right, the content is a mix of two renders.
	$mixDir = Join-Path $sourceRoot 'p-mixed'
	New-TestFrames -Directory $mixDir -Count $vertical.FrameCount -Preset $vertical -Source 'testsrc2'
	Set-FileAge -Paths @(Get-ChildItem -LiteralPath $mixDir -File | ForEach-Object { $_.FullName }) -HoursOld 1
	$mixMarker = [DateTime]::UtcNow.ToString('o')
	New-TestFrames -Directory $mixDir -Count 60 -Preset $vertical -Source 'smptebars'
	$mixVideo = Join-Path $videoRoot 'p-mixed.mp4'
	$mixEncode = Invoke-TestEncode -Directory $mixDir -FrameLimit $vertical.FrameCount -VideoPath $mixVideo -Preset $vertical
	Assert-True ($mixEncode.ExitCode -eq 0) "the mixed-source encode exits 0, got $($mixEncode.ExitCode): $($mixEncode.Output)"
	$mixReport = New-ReportPath 'p-mixed-frames'
	$mixResult = Invoke-Tool -Script $measureScript -Bound @{ Preset = 'vertical'; VideoPath = $mixVideo; ReportPath = $mixReport; RenderStartedUtc = $mixMarker; FramesDirectory = $mixDir }
	Assert-True ($mixResult.ExitCode -eq 1) "leftover frames from an earlier render exit 1, got $($mixResult.ExitCode): $($mixResult.Output)"
	$mixData = Read-Report $mixReport
	Assert-True ($mixData.checks.frame_count -eq 'pass' -and $mixData.checks.render_attempt -eq 'pass') 'the mixed MP4 is fresh and has the right frame count, so neither check alone catches it'
	Assert-True ($mixData.checks.source_frames_fresh -eq 'fail') 'the source_frames_fresh check fails'
	Assert-True (@(Get-FailureCategories $mixData) -contains 'stale_source_frames') 'the report names stale_source_frames'
	Assert-True ($mixData.provenance.frames_fresh -eq 60 -and $mixData.provenance.frames_stale -eq ($vertical.FrameCount - 60)) 'the report counts 60 fresh and the rest stale frames'
	Write-Output 'PASS: 60 new frames over 180 leftover frames give a right-sized MP4 that still fails as stale_source_frames'

	# (d) a missing frame in the middle stops the encoder short.
	$gapDir = Join-Path $sourceRoot 'p-gap'
	New-TestFrames -Directory $gapDir -Count $vertical.FrameCount -Preset $vertical -Source 'testsrc2'
	Remove-Item -LiteralPath (Join-Path $gapDir '000119.png') -Force
	$gapVideo = Join-Path $videoRoot 'p-gap.mp4'
	$gapEncode = Invoke-TestEncode -Directory $gapDir -FrameLimit $vertical.FrameCount -VideoPath $gapVideo -Preset $vertical
	Assert-True ($gapEncode.ExitCode -eq 0) "the gapped encode exits 0, got $($gapEncode.ExitCode): $($gapEncode.Output)"
	$gapReport = New-ReportPath 'p-gap'
	$gapResult = Invoke-Tool -Script $measureScript -Bound @{ Preset = 'vertical'; VideoPath = $gapVideo; ReportPath = $gapReport; RenderStartedUtc = $suiteStartUtc; FramesDirectory = $gapDir }
	Assert-True ($gapResult.ExitCode -eq 1) "a gapped sequence exits 1, got $($gapResult.ExitCode): $($gapResult.Output)"
	Assert-True (@(Get-FailureCategories (Read-Report $gapReport)) -contains 'frame_count_mismatch') 'a gap is reported as frame_count_mismatch'
	Write-Output 'PASS: a gap in the sequence encodes short with exit 0 and fails on the frame count'

	# (e) ffprobe cannot read the file: its exit code is non-zero and no stream is reported.
	$brokenVideo = Join-Path $videoRoot 'p-broken.mp4'
	[System.IO.File]::WriteAllBytes($brokenVideo, [System.Text.Encoding]::ASCII.GetBytes('this is not an mp4'))
	$brokenReport = New-ReportPath 'p-broken'
	$brokenResult = Invoke-Tool -Script $measureScript -Bound @{ Preset = 'vertical'; VideoPath = $brokenVideo; ReportPath = $brokenReport; RenderStartedUtc = $suiteStartUtc; FramesDirectory = $gapDir }
	Assert-True ($brokenResult.ExitCode -eq 1) "an unreadable MP4 exits 1, got $($brokenResult.ExitCode): $($brokenResult.Output)"
	$brokenData = Read-Report $brokenReport
	Assert-True ($brokenData.checks.probe -eq 'fail' -and $brokenData.decoder.exit_code -ne 0) 'the probe exit code is recorded and non-zero'
	Assert-True ($brokenData.artifact_verdict -ne 'pass') 'an unreadable MP4 is never a pass'
	Write-Output 'PASS: an unreadable MP4 fails on the probe exit code instead of reading an empty stream list as a measurement'

	# Without the marker or the frame directory the attempt cannot be tied to the MP4: never a pass.
	$noMarkerReport = New-ReportPath 'p-no-marker'
	$noMarkerResult = Invoke-Tool -Script $measureScript -Bound @{ Preset = 'landscape'; VideoPath = $b.VideoPath; ReportPath = $noMarkerReport; FramesDirectory = $b.SourceDirectory }
	Assert-True ($noMarkerResult.ExitCode -eq 2) "a correct MP4 without a render marker exits 2 (unverified), got $($noMarkerResult.ExitCode): $($noMarkerResult.Output)"
	$noMarkerData = Read-Report $noMarkerReport
	Assert-True ($noMarkerData.artifact_verdict -eq 'unverified' -and $noMarkerData.checks.frame_count -eq 'pass') 'the measurements pass but the verdict stays unverified'
	Assert-True (@(Get-FailureCategories $noMarkerData) -contains 'marker_missing') 'the report names marker_missing'

	$noFramesReport = New-ReportPath 'p-no-frames-dir'
	$noFramesResult = Invoke-Tool -Script $measureScript -Bound @{ Preset = 'landscape'; VideoPath = $b.VideoPath; ReportPath = $noFramesReport; RenderStartedUtc = $suiteStartUtc }
	Assert-True ($noFramesResult.ExitCode -eq 2) "a correct MP4 without a frame directory exits 2, got $($noFramesResult.ExitCode): $($noFramesResult.Output)"
	Assert-True (@(Get-FailureCategories (Read-Report $noFramesReport)) -contains 'frames_directory_missing') 'the report names frames_directory_missing'

	$futureReport = New-ReportPath 'p-future-marker'
	$futureResult = Invoke-Tool -Script $measureScript -Bound @{ Preset = 'landscape'; VideoPath = $b.VideoPath; ReportPath = $futureReport; RenderStartedUtc = [DateTime]::UtcNow.AddHours(2).ToString('o'); FramesDirectory = $b.SourceDirectory }
	Assert-True ($futureResult.ExitCode -eq 2) "a marker in the future exits 2, got $($futureResult.ExitCode): $($futureResult.Output)"
	Assert-True (@(Get-FailureCategories (Read-Report $futureReport)) -contains 'marker_in_future') 'the report names marker_in_future'
	Write-Output 'PASS: a missing or impossible marker and a missing frame directory leave the verdict unverified, never pass'

	# ============================================================ group 12: reports are exclusive and the inputs are untouched
	$reportFiles = @(Get-ChildItem -LiteralPath $reportRoot -Force)
	$expectedReports = $script:reportCounter
	Assert-True (@($reportFiles | Where-Object { $_.PSIsContainer }).Count -eq 0) 'no directories were created in reports/'
	Assert-True ($reportFiles.Count -eq $expectedReports) "reports/ holds one report per allocated path (expected $expectedReports, found $($reportFiles.Count))"
	Assert-True (@($reportFiles | Where-Object { $_.Length -le 0 }).Count -eq 0) 'every report is non-empty'
	foreach ($video in @(Get-ChildItem -LiteralPath $videoRoot -Force -Filter '*.mp4')) {
		Assert-True ($video.Length -gt 0) "fixture video $($video.Name) is non-empty"
	}
	Write-Output ("PASS: {0} reports were written exclusively and every fixture video is intact" -f $expectedReports)
} catch {
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
		$cleanupProblems += 'test suite leaves the developer checkout unchanged'
		$cleanupProblems += ('before: ' + ($initialCheckoutStatus -join ' | '))
		$cleanupProblems += ('after: ' + ($finalCheckoutStatus -join ' | '))
	}
	if ($cleanupProblems.Count -gt 0) {
		if ($null -ne $suiteError) { Write-Output "ASSERT FAILED: $($suiteError.Exception.Message)" }
		Assert-True $false ('test suite did not leave a clean tree: ' + ($cleanupProblems -join '; '))
	}
	if ($null -ne $suiteError) {
		Write-Output "SUITE_EXIT=1"
		Write-Output "ASSERT FAILED: $($suiteError.Exception.Message)"
		exit 1
	}
}

Write-Output "SUITE_EXIT=0"
exit 0
