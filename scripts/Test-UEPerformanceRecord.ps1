[CmdletBinding()]
param(
	[string]$RecordPath = '',
	[string]$BuildConfig = '',
	[string]$Instrument = '',
	[string]$Artifact = '',
	[string]$MeasuredAt = '',
	[string]$AverageMs = '',
	[string]$SpikeMs = '',
	[string]$ReportPath = '',
	[switch]$SelfTest
)

# Read-only verdict on whether a performance (frame time) record is attributable.
# It judges the *combination* of measured_build_config, instrument and artifact. It never judges
# whether a number is good, and it never launches Unreal Engine or any instrument.
#
# Why: a Shipping build ships without the engine's own frame time tooling by default (UE 5.8.4,
# read from Engine source on 2026-11-05; static reading, not an execution result):
#   engine-statunit   : console input needs ALLOW_CONSOLE (Build.h ALLOW_CONSOLE_IN_SHIPPING default 0;
#                       PlayerController.cpp / GameViewportClient.cpp are under #if ALLOW_CONSOLE)
#   engine-fpschart   : startfpschart is under #if !UE_BUILD_SHIPPING (UnrealEngine.cpp Exec_Dev) and the
#                       .log/.html output is under ALLOW_DEBUG_FILES (ChartCreation.cpp; WITH_EDITOR=0)
#   engine-startfile  : stat startfile is under #if STATS (StatsCommand.cpp); Shipping STATS defaults to 0
# A target that explicitly turns on bUseConsoleInShipping and friends can differ; this tool covers the
# default only (docs/05-qa.md, "Performance record contract").
#
# Vocabulary (closed):
#   measured_build_config : Editor | Development | Shipping
#   instrument            : engine-statunit | engine-fpschart | engine-startfile | external-capture |
#                           manual-or-unknown | none
#   artifact              : path of the file the numbers came from, or `none`
#
# Verdict per record:
#   fail        impossible combination or a value outside the vocabulary
#   unverified  instrument none/manual-or-unknown/missing, build config missing, artifact none/missing,
#               measured_at missing (never rounded into pass)
#   pass        the combination is attributable (this says nothing about the numbers)
# Exit codes: pass = 0, fail = 1, unverified = 2, usage error = 3. A set of records takes the worst
# verdict (fail over unverified over pass).
#
# -RecordPath is a JSON file holding one record or an array of records. The file is only read. The
# optional -ReportPath must not exist yet; it is created exclusively and never overwritten.
# This file is pure ASCII on purpose (Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI).

$ErrorActionPreference = 'Stop'

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$allowedBuildConfigs = @('Editor', 'Development', 'Shipping')
$allowedInstruments = @('engine-statunit', 'engine-fpschart', 'engine-startfile', 'external-capture', 'manual-or-unknown', 'none')

$shippingImpossible = @{
	'engine-statunit'  = 'Shipping default has no console input path: ALLOW_CONSOLE_IN_SHIPPING=0 (Build.h:215; PlayerController.cpp:3954,3966 and GameViewportClient.cpp:2807 are under #if ALLOW_CONSOLE)'
	'engine-fpschart'  = 'Shipping default does not interpret startfpschart (UnrealEngine.cpp:5752,5826,6664 under #if !UE_BUILD_SHIPPING) and writes no .log/.html (ChartCreation.cpp:914-924 under ALLOW_DEBUG_FILES, WITH_EDITOR=0)'
	'engine-startfile' = 'Shipping default has STATS=0 (Build.h:341-343, FORCE_USE_STATS default 0), so stat startfile is not interpreted (StatsCommand.cpp:2286 under #if STATS)'
}

function Get-FieldText {
	param($Record, [string]$Name)

	if ($null -eq $Record) { return '' }
	$property = $Record.PSObject.Properties[$Name]
	if ($null -eq $property -or $null -eq $property.Value) { return '' }
	return ([string]$property.Value).Trim()
}

function Test-Present {
	param([string]$Text)
	return (-not [string]::IsNullOrWhiteSpace($Text))
}

function Get-PerformanceRecordVerdict {
	param($Record, [int]$Index)

	$config = Get-FieldText $Record 'measured_build_config'
	$instrument = Get-FieldText $Record 'instrument'
	$artifact = Get-FieldText $Record 'artifact'
	$measuredAt = Get-FieldText $Record 'measured_at'
	$hasNumber = (Test-Present (Get-FieldText $Record 'average_ms')) -or (Test-Present (Get-FieldText $Record 'spike_ms'))

	$failReasons = New-Object System.Collections.Generic.List[string]
	$unverifiedReasons = New-Object System.Collections.Generic.List[string]

	if ((Test-Present $config) -and ($allowedBuildConfigs -cnotcontains $config)) {
		$failReasons.Add("vocabulary: measured_build_config '$config' is not one of $($allowedBuildConfigs -join '/')")
	}
	if ((Test-Present $instrument) -and ($allowedInstruments -cnotcontains $instrument)) {
		$failReasons.Add("vocabulary: instrument '$instrument' is not one of $($allowedInstruments -join '/')")
	}

	if ($failReasons.Count -eq 0 -and $config -ceq 'Shipping' -and $shippingImpossible.ContainsKey($instrument)) {
		$failReasons.Add("impossible-pair: Shipping + $instrument. $($shippingImpossible[$instrument])")
	}

	if ($failReasons.Count -eq 0) {
		if (-not (Test-Present $config)) { $unverifiedReasons.Add('measured_build_config is missing: cannot say which build the numbers describe') }
		if (-not (Test-Present $instrument)) {
			$unverifiedReasons.Add('instrument is missing')
		}
		elseif ($instrument -ceq 'none') {
			$unverifiedReasons.Add('instrument is none: no measurement method')
		}
		elseif ($instrument -ceq 'manual-or-unknown') {
			$unverifiedReasons.Add('instrument is manual-or-unknown: the method cannot be attributed')
		}
		if (-not (Test-Present $artifact) -or $artifact -ceq 'none') {
			if ($hasNumber) {
				$unverifiedReasons.Add('artifact is none but a number was recorded: the source of the number is unknown')
			}
			else {
				$unverifiedReasons.Add('artifact is none: none is never grounds for pass')
			}
		}
		if (-not (Test-Present $measuredAt)) { $unverifiedReasons.Add('measured_at is missing') }
	}

	$verdict = 'pass'
	$reasons = @()
	if ($failReasons.Count -gt 0) { $verdict = 'fail'; $reasons = @($failReasons) }
	elseif ($unverifiedReasons.Count -gt 0) { $verdict = 'unverified'; $reasons = @($unverifiedReasons) }

	return [ordered]@{
		index                 = $Index
		measured_build_config = $config
		instrument            = $instrument
		artifact              = $artifact
		measured_at           = $measuredAt
		verdict               = $verdict
		reasons               = $reasons
	}
}

function Get-OverallVerdict {
	param($Results)

	$verdicts = @($Results | ForEach-Object { $_.verdict })
	if ($verdicts -contains 'fail') { return 'fail' }
	if ($verdicts -contains 'unverified') { return 'unverified' }
	if ($verdicts.Count -eq 0) { return 'unverified' }
	return 'pass'
}

function Get-ExitCode {
	param([string]$Verdict)

	switch ($Verdict) {
		'pass' { return 0 }
		'fail' { return 1 }
		default { return 2 }
	}
}

function Get-PerformanceRecordsFromFile {
	param([string]$Path)

	$text = [System.IO.File]::ReadAllText($Path, $utf8NoBom)
	$parsed = $text | ConvertFrom-Json
	return @($parsed)
}

function Write-PerformanceReport {
	param([string]$Path, $Report)

	$json = $Report | ConvertTo-Json -Depth 6
	$stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
	try {
		$bytes = $utf8NoBom.GetBytes($json)
		$stream.Write($bytes, 0, $bytes.Length)
	}
	finally { $stream.Dispose() }
}

function Invoke-Judgement {
	param($Records, [string]$Report)

	$results = New-Object System.Collections.Generic.List[object]
	$i = 0
	foreach ($record in $Records) {
		$results.Add((Get-PerformanceRecordVerdict -Record $record -Index $i))
		$i++
	}
	$overall = Get-OverallVerdict -Results $results
	if (Test-Present $Report) {
		Write-PerformanceReport -Path $Report -Report ([ordered]@{ overall = $overall; records = $results.ToArray() })
	}
	return [pscustomobject]@{ Overall = $overall; Results = $results.ToArray() }
}

function Invoke-SelfTest {
	$check = {
		param([string]$Name, [bool]$Condition)
		if ($Condition) { Write-Output "PASS: $Name" }
		else { Write-Output "FAIL: $Name"; $script:selfFailures++ }
	}
	$script:selfFailures = 0

	function New-Rec {
		param([string]$Config, [string]$Instr, [string]$Art = 'evidence/perf.csv', [string]$At = '2026-11-22T10:00:00Z', [string]$Avg = '14.2')
		return [pscustomobject]@{ measured_build_config = $Config; instrument = $Instr; artifact = $Art; measured_at = $At; average_ms = $Avg; spike_ms = '40.1' }
	}
	function Get-One {
		param($Rec)
		return (Get-PerformanceRecordVerdict -Record $Rec -Index 0)
	}

	# Impossible pairs: must fail and name the engine source line.
	$r = Get-One (New-Rec 'Shipping' 'engine-statunit')
	& $check 'Shipping + engine-statunit is fail' ($r.verdict -eq 'fail')
	& $check 'Shipping + engine-statunit names ALLOW_CONSOLE' (($r.reasons -join ' ') -match 'ALLOW_CONSOLE')
	$r = Get-One (New-Rec 'Shipping' 'engine-fpschart')
	& $check 'Shipping + engine-fpschart is fail' ($r.verdict -eq 'fail')
	& $check 'Shipping + engine-fpschart names ALLOW_DEBUG_FILES' (($r.reasons -join ' ') -match 'ALLOW_DEBUG_FILES')
	$r = Get-One (New-Rec 'Shipping' 'engine-startfile')
	& $check 'Shipping + engine-startfile is fail' ($r.verdict -eq 'fail')
	& $check 'Shipping + engine-startfile names STATS' (($r.reasons -join ' ') -match 'STATS')

	# Valid pairs: pass.
	& $check 'Shipping + external-capture is pass' ((Get-One (New-Rec 'Shipping' 'external-capture')).verdict -eq 'pass')
	& $check 'Development + engine-fpschart is pass' ((Get-One (New-Rec 'Development' 'engine-fpschart')).verdict -eq 'pass')
	& $check 'Development + engine-statunit is pass' ((Get-One (New-Rec 'Development' 'engine-statunit')).verdict -eq 'pass')
	& $check 'Editor + engine-statunit is pass (attributed to Editor)' ((Get-One (New-Rec 'Editor' 'engine-statunit')).verdict -eq 'pass')

	# Unverified branches: never pass, never fail.
	& $check 'instrument none is unverified' ((Get-One (New-Rec 'Shipping' 'none')).verdict -eq 'unverified')
	& $check 'instrument blank is unverified' ((Get-One (New-Rec 'Shipping' '')).verdict -eq 'unverified')
	& $check 'instrument manual-or-unknown is unverified' ((Get-One (New-Rec 'Shipping' 'manual-or-unknown')).verdict -eq 'unverified')
	& $check 'artifact none with a number is unverified' ((Get-One (New-Rec 'Shipping' 'external-capture' 'none')).verdict -eq 'unverified')
	& $check 'artifact blank with a number is unverified' ((Get-One (New-Rec 'Shipping' 'external-capture' '')).verdict -eq 'unverified')
	& $check 'artifact none is never grounds for pass (no number either)' ((Get-One ([pscustomobject]@{ measured_build_config = 'Shipping'; instrument = 'external-capture'; artifact = 'none'; measured_at = '2026-11-22' })).verdict -eq 'unverified')
	& $check 'measured_build_config blank is unverified' ((Get-One (New-Rec '' 'external-capture')).verdict -eq 'unverified')
	& $check 'measured_at blank is unverified' ((Get-One (New-Rec 'Shipping' 'external-capture' 'evidence/perf.csv' '')).verdict -eq 'unverified')

	# Vocabulary is closed and case sensitive.
	& $check 'unknown build config is fail' ((Get-One (New-Rec 'Release' 'external-capture')).verdict -eq 'fail')
	& $check 'unknown instrument is fail' ((Get-One (New-Rec 'Shipping' 'presentmon')).verdict -eq 'fail')
	& $check 'lowercase shipping is fail (no silent coercion)' ((Get-One (New-Rec 'shipping' 'engine-statunit')).verdict -eq 'fail')

	# Overall verdict: worst wins, empty set is not pass.
	$mixed = Invoke-Judgement -Records @((New-Rec 'Shipping' 'external-capture'), (New-Rec 'Shipping' 'none')) -Report ''
	& $check 'pass + unverified overall is unverified (exit 2)' ($mixed.Overall -eq 'unverified' -and (Get-ExitCode $mixed.Overall) -eq 2)
	$mixed = Invoke-Judgement -Records @((New-Rec 'Shipping' 'none'), (New-Rec 'Shipping' 'engine-statunit')) -Report ''
	& $check 'unverified + fail overall is fail (exit 1)' ($mixed.Overall -eq 'fail' -and (Get-ExitCode $mixed.Overall) -eq 1)
	$allPass = Invoke-Judgement -Records @((New-Rec 'Shipping' 'external-capture'), (New-Rec 'Development' 'engine-fpschart')) -Report ''
	& $check 'all pass overall is pass (exit 0)' ($allPass.Overall -eq 'pass' -and (Get-ExitCode $allPass.Overall) -eq 0)
	& $check 'empty record set is unverified, not pass' ((Get-OverallVerdict -Results @()) -eq 'unverified')

	# File input is only read; report is created exclusively and never overwrites.
	$dir = Join-Path ([System.IO.Path]::GetTempPath()) ('uperf-selftest-' + [guid]::NewGuid().ToString('N'))
	[void][System.IO.Directory]::CreateDirectory($dir)
	try {
		$inFile = Join-Path $dir 'records.json'
		$body = '[{"measured_build_config":"Shipping","instrument":"external-capture","artifact":"evidence/perf.csv","measured_at":"2026-11-22","average_ms":"14.2"},{"measured_build_config":"Shipping","instrument":"engine-statunit","artifact":"evidence/perf.csv","measured_at":"2026-11-22"}]'
		[System.IO.File]::WriteAllText($inFile, $body, $utf8NoBom)
		$before = (Get-FileHash -LiteralPath $inFile -Algorithm SHA256).Hash
		$records = @(Get-PerformanceRecordsFromFile -Path $inFile)
		& $check 'array file is parsed into 2 records' ($records.Count -eq 2)
		$single = Join-Path $dir 'single.json'
		[System.IO.File]::WriteAllText($single, '{"measured_build_config":"Shipping","instrument":"none"}', $utf8NoBom)
		& $check 'single-object file is parsed into 1 record' (@(Get-PerformanceRecordsFromFile -Path $single).Count -eq 1)

		$report = Join-Path $dir 'report.json'
		$out = Invoke-Judgement -Records $records -Report $report
		& $check 'file input with an impossible pair is fail' ($out.Overall -eq 'fail')
		& $check 'report was created' (Test-Path -LiteralPath $report)
		$reportJson = [System.IO.File]::ReadAllText($report, $utf8NoBom) | ConvertFrom-Json
		& $check 'report records the overall verdict' ($reportJson.overall -eq 'fail')
		& $check 'input file is unchanged' ((Get-FileHash -LiteralPath $inFile -Algorithm SHA256).Hash -eq $before)
		$threw = $false
		try { [void](Invoke-Judgement -Records $records -Report $report) } catch { $threw = $true }
		& $check 'existing report path is refused, not overwritten' $threw
	}
	finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }

	if ($script:selfFailures -gt 0) {
		Write-Output "SUMMARY: selftest fail=$($script:selfFailures)"
		return
	}
	Write-Output 'SUMMARY: selftest fail=0'
}

if ($SelfTest) {
	Invoke-SelfTest
	exit $script:selfFailures
}

try {
	if (Test-Present $RecordPath) {
		if (-not (Test-Path -LiteralPath $RecordPath -PathType Leaf)) { throw "RecordPath not found: $RecordPath" }
		$records = @(Get-PerformanceRecordsFromFile -Path $RecordPath)
	}
	else {
		$records = @([pscustomobject]@{
				measured_build_config = $BuildConfig
				instrument            = $Instrument
				artifact              = $Artifact
				measured_at           = $MeasuredAt
				average_ms            = $AverageMs
				spike_ms              = $SpikeMs
			})
	}
	$outcome = Invoke-Judgement -Records $records -Report $ReportPath
}
catch {
	Write-Output "ERROR: $($_.Exception.Message)"
	exit 3
}

foreach ($result in $outcome.Results) {
	Write-Output ("RECORD {0}: {1} (build={2} instrument={3} artifact={4})" -f $result.index, $result.verdict.ToUpperInvariant(), $result.measured_build_config, $result.instrument, $result.artifact)
	foreach ($reason in $result.reasons) { Write-Output "  - $reason" }
}
Write-Output "SUMMARY: overall=$($outcome.Overall) records=$($outcome.Results.Count)"
exit (Get-ExitCode -Verdict $outcome.Overall)
