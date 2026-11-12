[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)]
	[string]$Preset,

	[string]$FramesDirectory = 'frames',

	[string]$VideoPath = 'Out/final/clean.mp4',

	[string]$ReportPath = 'Out/run_<runid>/evidence/encode-check.json',

	[string]$PresetFile = '',

	[string]$FfprobePath = '',

	[ValidateSet('text', 'json')]
	[string]$Format = 'text'
)

# Prints the encode, ffprobe and inspection commands for one capture preset.
# Every number in the output (-frames:v, fps, start number, digits, resolution, expected frame count
# and duration) is derived from templates/CAPTURE-PRESETS.json. Nothing here is hand-written, so a
# documented command cannot drift from the preset it is supposed to implement.
# This script neither renders nor encodes: it only prints commands.

$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($PresetFile)) {
	$PresetFile = Join-Path $repoRoot 'templates\CAPTURE-PRESETS.json'
}
$presetFull = [System.IO.Path]::GetFullPath($PresetFile)
if (-not (Test-Path -LiteralPath $presetFull -PathType Leaf)) {
	throw "Invalid input: the capture preset definition was not found: $presetFull"
}

$presetData = $null
# Read as UTF-8 explicitly: Windows PowerShell 5.1 decodes a BOM-less Get-Content -Raw with the
# ANSI code page, so the Japanese preset descriptions would be mangled before ConvertFrom-Json.
try {
	$presetText = [System.IO.File]::ReadAllText($presetFull, (New-Object System.Text.UTF8Encoding($false, $true)))
	$presetData = $presetText | ConvertFrom-Json
} catch {
	throw "Invalid input: $presetFull could not be read as UTF-8 JSON: $($_.Exception.Message)"
}
if ($null -eq $presetData.presets) {
	throw "Invalid input: $presetFull has no 'presets' array"
}

$matches_ = @($presetData.presets | Where-Object { [string]$_.name -eq $Preset })
if ($matches_.Count -ne 1) {
	$known = (@($presetData.presets | ForEach-Object { [string]$_.name }) -join ', ')
	throw "Invalid input: preset '$Preset' must be defined exactly once in $presetFull (defined: $known)"
}
$entry = $matches_[0]

$widthValue = 0
$heightValue = 0
$fpsValue = 0.0
$durationValue = 0.0
$startValue = 0
$digitsValue = 6
$crfValue = 18
if (-not [int]::TryParse(([string]$entry.width).Trim(), [ref]$widthValue)) { throw "Invalid input: preset '$Preset' has a non-numeric width" }
if (-not [int]::TryParse(([string]$entry.height).Trim(), [ref]$heightValue)) { throw "Invalid input: preset '$Preset' has a non-numeric height" }
if (-not [double]::TryParse(([string]$entry.fps).Trim(), [ref]$fpsValue)) { throw "Invalid input: preset '$Preset' has a non-numeric fps" }
if (-not [double]::TryParse(([string]$entry.duration_seconds).Trim(), [ref]$durationValue)) { throw "Invalid input: preset '$Preset' has a non-numeric duration_seconds" }
if ($null -ne $entry.start_number) {
	if (-not [int]::TryParse(([string]$entry.start_number).Trim(), [ref]$startValue)) { throw "Invalid input: preset '$Preset' has a non-numeric start_number" }
}
if ($null -ne $entry.digits) {
	if (-not [int]::TryParse(([string]$entry.digits).Trim(), [ref]$digitsValue)) { throw "Invalid input: preset '$Preset' has a non-numeric digits" }
}
if ($null -ne $entry.crf) {
	if (-not [int]::TryParse(([string]$entry.crf).Trim(), [ref]$crfValue)) { throw "Invalid input: preset '$Preset' has a non-numeric crf" }
}
if ($widthValue -le 0 -or $heightValue -le 0 -or $fpsValue -le 0 -or $durationValue -le 0) {
	throw "Invalid input: preset '$Preset' needs positive width, height, fps and duration_seconds"
}
if ($null -ne $entry.frame_count) {
	throw "Invalid input: preset '$Preset' declares frame_count as well as fps and duration_seconds. The frame count is derived from fps x duration and must not be duplicated."
}

$derivedFrames = $fpsValue * $durationValue
if ([Math]::Abs($derivedFrames - [Math]::Round($derivedFrames)) -gt 0.0001) {
	throw "Invalid input: preset '$Preset' does not yield a whole frame count: fps $fpsValue x duration $durationValue s"
}
$frameCount = [int][Math]::Round($derivedFrames)
$endExclusive = $startValue + $frameCount

$extension = '.png'
if ($null -ne $entry.extension -and -not [string]::IsNullOrWhiteSpace([string]$entry.extension)) { $extension = [string]$entry.extension }
$codec = 'libx264'
$pixFmt = 'yuv420p'
if ($null -ne $entry.pix_fmt -and -not [string]::IsNullOrWhiteSpace([string]$entry.pix_fmt)) { $pixFmt = [string]$entry.pix_fmt }
$fpsText = if ([Math]::Abs($fpsValue - [Math]::Round($fpsValue)) -lt 0.0001) { ([int][Math]::Round($fpsValue)).ToString() } else { $fpsValue.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
$inputPattern = '%0' + $digitsValue + 'd' + $extension

# The ffmpeg input pattern is joined with the platform separator so the printed command can be
# pasted as-is on Windows without hand-fixing slashes.
$framesArgument = $FramesDirectory.TrimEnd([char[]]@('\', '/')) + '\' + $inputPattern

$ffmpegCommand = 'ffmpeg -n -framerate {0} -start_number {1} -i "{2}" -frames:v {3} -c:v {4} -pix_fmt {5} -crf {6} -movflags +faststart "{7}"' -f $fpsText, $startValue, $framesArgument, $frameCount, $codec, $pixFmt, $crfValue, $VideoPath
$ffprobeCommand = 'ffprobe -v error -count_frames -show_entries stream=index,codec_type,codec_name,width,height,r_frame_rate,nb_read_frames,sample_rate,channels -show_entries format=duration,size -of json "{0}"' -f $VideoPath
$framesCheckPath = 'Out/run_<runid>/evidence/frames-check.json'
$framesCheckCommand = '.\scripts\Measure-UERenderArtifacts.ps1 -FramesDirectory "{0}" -StartNumber {1} -EndNumberExclusive {2} -ExpectedWidth {3} -ExpectedHeight {4} -ReportPath "{5}"' -f $FramesDirectory, $startValue, $endExclusive, $widthValue, $heightValue, $framesCheckPath
$inspectCommand = '.\scripts\Measure-UECaptureEncode.ps1 -Preset {0} -VideoPath "{1}" -ReportPath "{2}"' -f $Preset, $VideoPath, $ReportPath

$plan = [ordered]@{
	preset = [string]$entry.name
	use = [string]$entry.use
	definition_file = $presetFull
	expectations = [ordered]@{
		frame_count = $frameCount
		duration_seconds = $durationValue
		width = $widthValue
		height = $heightValue
		fps = $fpsValue
		start_number = $startValue
		end_number_exclusive = $endExclusive
		digits = $digitsValue
		extension = $extension
	}
	commands = [ordered]@{
		frames_check = $framesCheckCommand
		ffmpeg = $ffmpegCommand
		ffprobe = $ffprobeCommand
		inspect = $inspectCommand
	}
	warnings = @(
		'ffmpeg -frames:v is an output upper bound, not a length check. A source sequence with fewer images is encoded short and ffmpeg still exits 0.',
		'Length is verified by Measure-UECaptureEncode.ps1, which compares the encoded frame count and duration with the same preset definition.'
	)
}

if ($Format -eq 'json') {
	$plan | ConvertTo-Json -Depth 8
	exit 0
}

# Resolve ffprobe only to report what the inspection step will use; the plan is printable without it.
$probeStatus = 'not found (pass -FfprobePath for the inspection step)'
if (-not [string]::IsNullOrWhiteSpace($FfprobePath)) {
	$probeStatus = if (Test-Path -LiteralPath $FfprobePath -PathType Leaf) { [System.IO.Path]::GetFullPath($FfprobePath) } else { "missing: $FfprobePath" }
} else {
	$discovered = @(Get-Command -Name 'ffprobe' -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
	if ($null -ne $discovered) { $probeStatus = [System.IO.Path]::GetFullPath($discovered.Source) }
}

Write-Output ("PRESET: {0} - {1}" -f $plan.preset, $plan.use)
Write-Output ("DEFINITION: {0}" -f $plan.definition_file)
Write-Output ("EXPECT: frames={0} duration={1}s resolution={2}x{3} fps={4} range={5}..{6} ({7} frame)" -f $frameCount, $durationValue, $widthValue, $heightValue, $fpsValue, $startValue, ($endExclusive - 1), $frameCount)
Write-Output ("FRAMES-CHECK: {0}" -f $framesCheckCommand)
Write-Output ("FFMPEG: {0}" -f $ffmpegCommand)
Write-Output ("FFPROBE: {0}" -f $ffprobeCommand)
Write-Output ("INSPECT: {0}" -f $inspectCommand)
Write-Output ("FFPROBE-ON-THIS-HOST: {0}" -f $probeStatus)
foreach ($warning in $plan.warnings) { Write-Output ("NOTE: {0}" -f $warning) }
exit 0
