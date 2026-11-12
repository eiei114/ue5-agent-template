[CmdletBinding()]
param(
	[string]$MacOSVersion = '',
	[string]$XcodeVersion = '',
	[string]$ProcessorFamily = '',
	[Nullable[int]]$MemoryGB = $null,
	[string]$MetalSupported = '',
	[string]$ReportPath = '',
	[string]$RunId = '',
	[switch]$SelfTest
)

# Read-only Mac host eligibility verdict for UE 5.8.
# The caller supplies observed host facts. This script never runs `sw_vers` or `xcodebuild` and never
# writes anywhere except an explicit, previously unused report path. A missing observation stays
# `unverified`; it is never rounded into `pass`.
#
# Rules (docs/04-package.md, section "UE 5.8 Mac host requirements"):
#   - Epic's UE 5.8 table sets a minimum OS, processor, memory, Metal and Xcode.
#   - Epic's minimum Xcode (26.0) and Epic's minimum OS (Sonoma 14.5) do not agree with Apple's
#     Xcode support table, which requires macOS 15.6 for Xcode 26.0-26.3.
#   - Therefore the verdict is the intersection of both tables. Neither table alone can pass a host.
#   - Which vendor table is misprinted is not decided here.
#
# Exit codes: pass = 0, fail = 1, unverified = 2.

$ErrorActionPreference = 'Stop'

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$ordinalIgnoreCase = [System.StringComparison]::OrdinalIgnoreCase

$epicMinimumMacOS = [version]'14.5'          # UE 5.8: Sonoma 14.5
$epicRecommendedMacOS = [version]'15.0'      # UE 5.8: Sequoia 15
$epicMinimumXcode = [version]'26.0'
$epicRecommendedXcode = [version]'26.1.1'
$nonCompatibleXcodeLowerBound = [version]'26.4'
$nonCompatibleXcodeUpperBoundExclusive = [version]'26.5'
$epicMinimumMemoryGB = 16

$sourceEpic = 'https://dev.epicgames.com/documentation/en-us/unreal-engine/macos-development-requirements-for-unreal-engine'
$sourceApple = 'https://developer.apple.com/support/xcode/'
$sourceReferencedOn = '2026-11-05'

# Windows PowerShell 5.1 decodes a BOM-less UTF-8 script as ANSI, so a Japanese string literal in this
# file turns into mojibake and the parser stops before -SelfTest can run. Every other script in this
# repository is pure ASCII and is never re-encoded, so the Japanese text this tool has to match inside
# the documents is spelled from code points here instead. Do not paste the decoded text back into this
# file, and do not add a BOM: the suite runs under both PowerShell 5.1 and pwsh from the same bytes.
function ConvertFrom-CodePointText {
	param([uint32[]]$CodePoint)

	$builder = New-Object System.Text.StringBuilder
	foreach ($point in $CodePoint) { [void]$builder.Append([char]$point) }
	return $builder.ToString()
}

# "intersection of both tables"
$docCrossTable = ConvertFrom-CodePointText -CodePoint @(0x4E21, 0x8868, 0x306E, 0x4EA4, 0x5DEE)
# "Mac host eligible" (the QA row label)
$qaMacHostRow = ConvertFrom-CodePointText -CodePoint @(0x004D, 0x0061, 0x0063, 0x0020, 0x0068, 0x006F, 0x0073, 0x0074, 0x9069, 0x683C)
# "intersection"
$qaCross = ConvertFrom-CodePointText -CodePoint @(0x4EA4, 0x5DEE)
# "macOS version", "Xcode version", "processor", "source reference date"
$qaRequiredFields = @(
	(ConvertFrom-CodePointText -CodePoint @(0x006D, 0x0061, 0x0063, 0x004F, 0x0053, 0x7248)),
	(ConvertFrom-CodePointText -CodePoint @(0x0058, 0x0063, 0x006F, 0x0064, 0x0065, 0x7248)),
	(ConvertFrom-CodePointText -CodePoint @(0x30D7, 0x30ED, 0x30BB, 0x30C3, 0x30B5)),
	'Memory',
	'Metal',
	(ConvertFrom-CodePointText -CodePoint @(0x51FA, 0x5178, 0x53C2, 0x7167, 0x65E5))
)

$macOsNameBases = [ordered]@{
	ventura = [version]'13.0'
	sonoma = [version]'14.0'
	sequoia = [version]'15.0'
	tahoe = [version]'26.0'
}

function Get-LowerBoundVersion {
	# Returns the smallest version the observation is compatible with, plus how precisely it was
	# declared. `15` or `Sequoia` becomes 15.0 (a lower bound), so a threshold of 15.6 stays
	# unverified instead of being guessed either way.
	param(
		[string]$Text,
		[string]$FieldName,
		$NameBases
	)

	$result = [ordered]@{
		provided = (-not [string]::IsNullOrWhiteSpace($Text))
		value = $null
		precision = 'none'
		detail = ''
	}

	if (-not $result.provided) {
		$result.detail = "$FieldName was not provided"
		return $result
	}

	$trimmed = $Text.Trim()
	$numericMatch = [regex]::Match($trimmed, '(\d+(?:\.\d+)?)')
	if ($numericMatch.Success) {
		$candidate = $null
		try { $candidate = [version]$numericMatch.Groups[1].Value } catch { $candidate = $null }
		if ($null -eq $candidate) {
			$result.detail = "$FieldName value '$trimmed' is not a readable version"
			return $result
		}
		$result.value = $candidate
		# A bare major number ("15") is a lower bound of 15.0; an explicit minor ("15.6") is exact.
		$result.precision = $(if ($numericMatch.Groups[1].Value -match '\.') { 'minor' } else { 'major_only' })
		$result.detail = "$FieldName '$trimmed' compared as a lower bound $candidate ($($result.precision))"
		return $result
	}

	if ($null -ne $NameBases) {
		$nameMatch = $null
		foreach ($name in $NameBases.Keys) {
			if ($trimmed -imatch [regex]::Escape($name)) { $nameMatch = $name; break }
		}
		if ($null -ne $nameMatch) {
			$result.value = $NameBases[$nameMatch]
			$result.precision = 'name_only'
			$result.detail = "$FieldName '$trimmed' names $nameMatch without a version number; compared as a lower bound $($result.value)"
			return $result
		}
	}

	$result.detail = "$FieldName value '$trimmed' carries no readable version number"
	return $result
}

function Test-MinimumVersion {
	# A lower bound already at or above the threshold passes. A lower bound below the threshold
	# cannot prove anything, so it stays unverified unless the field itself was an exact value.
	param(
		$Observed,
		[version]$Threshold,
		[string]$Label
	)

	if (-not $Observed.provided) {
		return [ordered]@{ state = 'unverified'; detail = "${Label}: no observation, so this check stays unverified" }
	}
	if ($null -eq $Observed.value) {
		return [ordered]@{ state = 'unverified'; detail = "${Label}: $($Observed.detail)" }
	}
	if ($Observed.value -ge $Threshold) {
		return [ordered]@{ state = 'pass'; detail = "${Label}: observed lower bound $($Observed.value) is at or above the minimum $Threshold" }
	}
	if ($Observed.precision -eq 'minor') {
		return [ordered]@{ state = 'fail'; detail = "${Label}: observed $($Observed.value) is below the minimum $Threshold" }
	}
	return [ordered]@{ state = 'unverified'; detail = "${Label}: observed $($Observed.value) is a lower bound only and may hide a version below the minimum $Threshold" }
}

function Get-AppleMacOsFloor {
	# Apple's Xcode support table, read as an OS floor per Xcode band. A band this template has not
	# recorded returns $null so the cross-check stays unverified instead of being invented.
	param($XcodeLowerBound)

	if ($null -eq $XcodeLowerBound) { return $null }
	if ($XcodeLowerBound -ge [version]'26.0' -and $XcodeLowerBound -lt [version]'26.4') { return [version]'15.6' }
	if ($XcodeLowerBound -ge [version]'26.4.1' -and $XcodeLowerBound -lt [version]'26.5') { return [version]'26.2' }
	return $null
}

function Get-WorstState([string[]]$States) {
	if (@($States | Where-Object { $_ -eq 'fail' }).Count -gt 0) { return 'fail' }
	if (@($States).Count -eq 0) { return 'unverified' }
	if (@($States | Where-Object { $_ -eq 'unverified' }).Count -gt 0) { return 'unverified' }
	return 'pass'
}

function Get-MacHostVerdict {
	param(
		$Inputs,
		[int]$Episode = 0
	)

	$checks = New-Object System.Collections.Generic.List[object]

	$macOs = Get-LowerBoundVersion -Text $Inputs.MacOSVersion -FieldName 'macOS version' -NameBases $macOsNameBases
	$xcode = Get-LowerBoundVersion -Text $Inputs.XcodeVersion -FieldName 'Xcode version' -NameBases $null

	# ---- Epic UE 5.8 table: minimum macOS
	$epicMacOs = Test-MinimumVersion -Observed $macOs -Threshold $epicMinimumMacOS -Label 'Epic minimum macOS (Sonoma 14.5)'
	$checks.Add([ordered]@{ check = 'epic_minimum_macos'; state = $epicMacOs.state; detail = $epicMacOs.detail; required = ">= $epicMinimumMacOS" })

	# ---- Epic UE 5.8 table: minimum Xcode
	$epicXcodeState = 'unverified'
	$epicXcodeDetail = 'Epic minimum Xcode (26.0): no observation, so this check stays unverified'
	if ($xcode.provided -and $null -eq $xcode.value) {
		$epicXcodeDetail = "Epic minimum Xcode (26.0): $($xcode.detail)"
	} elseif ($null -ne $xcode.value) {
		if ($xcode.value -ge $epicMinimumXcode) {
			$epicXcodeState = 'pass'
			$epicXcodeDetail = "Epic minimum Xcode (26.0): observed lower bound $($xcode.value) is at or above 26.0"
		} elseif ($xcode.precision -eq 'minor') {
			$epicXcodeState = 'fail'
			$epicXcodeDetail = "Epic minimum Xcode (26.0): observed $($xcode.value) is below 26.0, so this host is outside UE 5.8's supported Mac configuration"
		} else {
			$epicXcodeDetail = "Epic minimum Xcode (26.0): observed $($xcode.value) is a lower bound only and may hide a version below 26.0"
		}
	}
	$checks.Add([ordered]@{ check = 'epic_minimum_xcode'; state = $epicXcodeState; detail = $epicXcodeDetail; required = ">= $epicMinimumXcode" })

	# ---- Epic UE 5.8 table: the documented Xcode 26.4 exclusion, treated as a family
	$nonCompatibleState = 'unverified'
	$nonCompatibleDetail = 'Epic "Xcode 26.4 is not compatible": no Xcode observation, so the exclusion stays unverified'
	if ($xcode.provided -and $null -eq $xcode.value) {
		$nonCompatibleDetail = "Epic `"Xcode 26.4 is not compatible`": $($xcode.detail)"
	} elseif ($null -ne $xcode.value) {
		if ($xcode.value -ge $nonCompatibleXcodeLowerBound -and $xcode.value -lt $nonCompatibleXcodeUpperBoundExclusive) {
			# Epic's sentence does not say whether it means one build or the whole 26.4 family. The family
			# is treated as non-compatible and that uncertainty is recorded instead of guessed away.
			$nonCompatibleState = 'fail'
			$nonCompatibleDetail = "Epic `"Xcode 26.4 is not compatible`": observed $($xcode.value) is inside the treated-as-non-compatible 26.4 family"
		} elseif ($xcode.value -lt $nonCompatibleXcodeLowerBound) {
			$nonCompatibleState = 'pass'
			$nonCompatibleDetail = "Epic `"Xcode 26.4 is not compatible`": observed lower bound $($xcode.value) is below the 26.4 family"
		} else {
			$nonCompatibleDetail = "Epic `"Xcode 26.4 is not compatible`": observed lower bound $($xcode.value) is above every recorded non-compatible version, so the exclusion cannot be confirmed either way"
		}
	}
	$checks.Add([ordered]@{
		check = 'epic_xcode_26_4_excluded'
		state = $nonCompatibleState
		detail = $nonCompatibleDetail
		required = "not in $nonCompatibleXcodeLowerBound..$nonCompatibleXcodeUpperBoundExclusive (exclusive)"
	})

	# ---- Apple's Xcode support table, read as an OS floor for the observed Xcode band
	$appleFloor = Get-AppleMacOsFloor -XcodeLowerBound $xcode.value
	$crossState = 'unverified'
	$crossDetail = 'Epic/Apple cross-check: no Xcode observation, so the Apple OS floor for a specific Xcode band is unknown'
	if ($xcode.provided -and $null -eq $xcode.value) {
		$crossDetail = "Epic/Apple cross-check: $($xcode.detail)"
	} elseif ($null -ne $xcode.value) {
		if ($null -eq $appleFloor) {
			$crossDetail = "Epic/Apple cross-check: Apple's table lists no OS floor for Xcode $($xcode.value) in the bands recorded by this template, so the intersection is unverified"
		} else {
			$cross = Test-MinimumVersion -Observed $macOs -Threshold $appleFloor -Label "Epic/Apple cross-check (Apple requires macOS $appleFloor for Xcode $($xcode.value))"
			$crossState = $cross.state
			$crossDetail = $cross.detail
		}
	}
	$checks.Add([ordered]@{
		check = 'epic_apple_intersection'
		state = $crossState
		detail = $crossDetail
		required = 'Epic minimum OS/Xcode for UE 5.8 and the Apple OS floor for the observed Xcode band'
	})

	# ---- Epic UE 5.8 table: processor
	$processorState = 'unverified'
	$processorDetail = 'Epic minimum processor (Apple Silicon M1/M2): no observation, so this check stays unverified'
	$processorLabel = ''
	if (-not [string]::IsNullOrWhiteSpace($Inputs.ProcessorFamily)) {
		$processorLabel = $Inputs.ProcessorFamily.Trim()
		if ($processorLabel -imatch '^(m[0-9]+|apple[\s-]?silicon|arm64)$') {
			$processorState = 'pass'
			$processorDetail = "Epic minimum processor (Apple Silicon M1/M2): observed '$processorLabel' is Apple Silicon"
		} elseif ($processorLabel -imatch '^(intel|x86[_-]?64|x64|i[3579]|core$)') {
			$processorState = 'fail'
			$processorDetail = "Epic minimum processor (Apple Silicon M1/M2): observed '$processorLabel' is not Apple Silicon"
		} else {
			$processorDetail = "Epic minimum processor (Apple Silicon M1/M2): '$processorLabel' is not covered by this check, so it stays unverified"
		}
	}
	$checks.Add([ordered]@{ check = 'epic_minimum_processor'; state = $processorState; detail = $processorDetail; required = 'Apple Silicon M1/M2 or newer' })

	# ---- Epic UE 5.8 table: memory
	$memoryState = 'unverified'
	$memoryDetail = "Epic minimum memory ($epicMinimumMemoryGB GB): no observation, so this check stays unverified"
	$memoryValue = $null
	if ($null -ne $Inputs.MemoryGB) {
		$memoryValue = [int]$Inputs.MemoryGB
		if ($memoryValue -lt 0) {
			$memoryDetail = "Epic minimum memory ($epicMinimumMemoryGB GB): '$memoryValue' is not a usable observation, so it stays unverified"
		} elseif ($memoryValue -lt $epicMinimumMemoryGB) {
			$memoryState = 'fail'
			$memoryDetail = "Epic minimum memory ($epicMinimumMemoryGB GB): observed $memoryValue GB is below the minimum"
		} else {
			$memoryState = 'pass'
			$memoryDetail = "Epic minimum memory ($epicMinimumMemoryGB GB): observed $memoryValue GB is at or above the minimum"
		}
	}
	$checks.Add([ordered]@{ check = 'epic_minimum_memory'; state = $memoryState; detail = $memoryDetail; required = ">= $epicMinimumMemoryGB GB" })

	# ---- Epic UE 5.8 table: Metal
	$metalState = 'unverified'
	$metalDetail = 'Epic Metal 1.2 compatibility: no observation, so this check stays unverified'
	if (-not [string]::IsNullOrWhiteSpace($Inputs.MetalSupported)) {
		$metalValue = $Inputs.MetalSupported.Trim()
		if ($metalValue -imatch '^(yes|true|1|supported)$') {
			$metalState = 'pass'
			$metalDetail = "Epic Metal 1.2 compatibility: observed '$metalValue' is Metal 1.2 compatible"
		} elseif ($metalValue -imatch '^(no|false|0|unsupported)$') {
			$metalState = 'fail'
			$metalDetail = "Epic Metal 1.2 compatibility: observed '$metalValue' is not Metal 1.2 compatible"
		} else {
			$metalDetail = "Epic Metal 1.2 compatibility: '$metalValue' is not covered by this check, so it stays unverified"
		}
	}
	$checks.Add([ordered]@{ check = 'epic_metal_compatibility'; state = $metalState; detail = $metalDetail; required = 'Metal 1.2 compatible' })

	$verdict = Get-WorstState -States @($checks | ForEach-Object { $_.state })

	$report = [ordered]@{
		schema_version = 1
		tool = 'scripts/Test-UEMacHostRequirements.ps1'
		generated_at_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
		scope = 'mac_host_eligibility_only'
		run_id = $Inputs.RunId
		inputs = [ordered]@{
			macos_version = $Inputs.MacOSVersion
			xcode_version = $Inputs.XcodeVersion
			processor_family = $Inputs.ProcessorFamily
			memory_gb = $(if ($null -ne $memoryValue) { [int]$memoryValue } else { $null })
			metal_supported = $Inputs.MetalSupported
		}
		parsed = [ordered]@{
			macos_lower_bound = $(if ($null -ne $macOs.value) { $macOs.value.ToString() } else { $null })
			macos_precision = $macOs.precision
			xcode_lower_bound = $(if ($null -ne $xcode.value) { $xcode.value.ToString() } else { $null })
			xcode_precision = $xcode.precision
			apple_macos_floor_for_xcode = $(if ($null -ne $appleFloor) { $appleFloor.ToString() } else { $null })
		}
		requirements = [ordered]@{
			epic_minimum_macos = $epicMinimumMacOS.ToString()
			epic_recommended_macos = $epicRecommendedMacOS.ToString()
			epic_minimum_xcode = $epicMinimumXcode.ToString()
			epic_recommended_xcode = $epicRecommendedXcode.ToString()
			epic_non_compatible_xcode_family = "$nonCompatibleXcodeLowerBound..$nonCompatibleXcodeUpperBoundExclusive(exclusive)"
			epic_minimum_memory_gb = $epicMinimumMemoryGB
			rule = 'verdict = intersection of the Epic UE 5.8 table and the Apple Xcode support table; neither table alone passes a host'
		}
		sources = @(
			[ordered]@{ url = $sourceEpic; referenced_on = $sourceReferencedOn; used_for = 'UE 5.8 minimum/recommended macOS, processor, memory, Metal, Xcode, and the Xcode 26.4 non-compatible note' },
			[ordered]@{ url = $sourceApple; referenced_on = $sourceReferencedOn; used_for = 'macOS version each Xcode band requires' }
		)
		accepted_uncertainty = @(
			'Epic writes "Recommended Operating System: Latest macOS Sequoia 14" and its Version History row writes "Sequoia 15"; the number (15) is used and the name/number mismatch is not adjudicated here.',
			'Epic writes "Xcode 26.4 is not compatible" without stating whether one build or the whole 26.4 family is meant; the 26.4 family is treated as non-compatible and the uncertainty is recorded here.',
			'Which vendor table is misprinted is not decided by this tool.'
		)
		checks = @($checks | ForEach-Object { $_ })
		verdict = $verdict
		unverified_scope = @(
			'Mac real build / UAT / BuildCookRun -platform=Mac / .app generation / signing / notarization',
			'Actual rendering behaviour and Metal performance on the observed host',
			'Host facts were supplied by the caller; this tool did not read them from the host'
		)
		notes = @(
			'A pass here is host eligibility against two published vendor tables, not proof that a Mac build, UAT or signed .app was produced.',
			'A missing observation stays unverified and is never rounded into pass.',
			'This tool reads no host state itself and writes only the requested report path.'
		)
	}

	return [ordered]@{
		verdict = $verdict
		checks = $checks
		report = $report
	}
}

function Write-VerdictReport {
	param(
		[string]$Path,
		$Report
	)

	$reportFull = [System.IO.Path]::GetFullPath($Path)
	if (Test-Path -LiteralPath $reportFull) {
		throw "Invalid input: report path already exists and will not be overwritten: $reportFull"
	}
	$reportParent = Split-Path -Parent $reportFull
	if (-not [string]::IsNullOrWhiteSpace($reportParent) -and -not (Test-Path -LiteralPath $reportParent -PathType Container)) {
		[System.IO.Directory]::CreateDirectory($reportParent) | Out-Null
	}

	try {
		$fileStream = [System.IO.FileStream]::new($reportFull, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
		try {
			$writer = New-Object System.IO.StreamWriter($fileStream, $utf8NoBom)
			try {
				$writer.Write((ConvertTo-Json -InputObject $Report -Depth 12))
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
	return $reportFull
}

function Exit-CodeForVerdict([string]$Verdict) {
	if ($Verdict -eq 'pass') { return 0 }
	if ($Verdict -eq 'fail') { return 1 }
	return 2
}

function Assert-True([bool]$Condition, [string]$Message) {
	if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Invoke-SelfTest {
	$failures = 0
	$groups = 0

	$fixtures = @(
		@{
			name = 'Ventura 13.5 + Xcode 26.0 is below the Epic minimum macOS'
			inputs = @{ MacOSVersion = '13.5'; XcodeVersion = '26.0' }
			expected = 'fail'
			check = 'epic_minimum_macos'
			checkState = 'fail'
			why = 'Epic UE 5.8 minimum macOS is Sonoma 14.5'
		},
		@{
			name = 'Tahoe 26.2 + Xcode 26.4.1 is inside the non-compatible 26.4 family'
			inputs = @{ MacOSVersion = '26.2'; XcodeVersion = '26.4.1' }
			expected = 'fail'
			check = 'epic_xcode_26_4_excluded'
			checkState = 'fail'
			why = 'Epic writes that Xcode 26.4 is not compatible; the family is treated as a range'
		},
		@{
			name = 'Sequoia 15.6 + Xcode 26.1.1 + M3 + 32 GB + Metal is a full pass'
			inputs = @{ MacOSVersion = '15.6'; XcodeVersion = '26.1.1'; ProcessorFamily = 'M3'; MemoryGB = 32; MetalSupported = 'yes' }
			expected = 'pass'
			check = 'epic_apple_intersection'
			checkState = 'pass'
			why = 'both vendor tables are satisfied'
		},
		@{
			name = 'an undeclared Xcode stays unverified'
			inputs = @{ MacOSVersion = '15.6' }
			expected = 'unverified'
			check = 'epic_minimum_xcode'
			checkState = 'unverified'
			why = 'no Xcode observation must not be rounded into pass'
		},
		@{
			name = 'Sonoma 14.5 + Xcode 15.4 is outside UE 5.8'
			inputs = @{ MacOSVersion = '14.5'; XcodeVersion = '15.4' }
			expected = 'fail'
			check = 'epic_minimum_xcode'
			checkState = 'fail'
			why = 'Epic UE 5.8 minimum Xcode is 26.0'
		},
		@{
			name = 'Sonoma 14.5 + Xcode 26.0 satisfies both Epic rows but not the Apple intersection'
			inputs = @{ MacOSVersion = '14.5'; XcodeVersion = '26.0' }
			expected = 'fail'
			check = 'epic_apple_intersection'
			checkState = 'fail'
			why = 'Apple requires macOS 15.6 for Xcode 26.0; the two vendor tables do not agree'
		},
		@{
			name = 'Tahoe 26.2 + Xcode 26.5 has no recorded Apple floor and stays unverified'
			inputs = @{ MacOSVersion = '26.2'; XcodeVersion = '26.5' }
			expected = 'unverified'
			check = 'epic_apple_intersection'
			checkState = 'unverified'
			why = 'no Apple OS floor is recorded for that band, so it must not pass'
		},
		@{
			name = 'Sequoia without a minor version cannot clear the Apple 15.6 floor'
			inputs = @{ MacOSVersion = 'Sequoia'; XcodeVersion = '26.1.1' }
			expected = 'unverified'
			check = 'epic_apple_intersection'
			checkState = 'unverified'
			why = '15 is only a lower bound; it may hide a version below 15.6'
		},
		@{
			name = 'Intel Mac is below the Epic processor row'
			inputs = @{ MacOSVersion = '15.6'; XcodeVersion = '26.1.1'; ProcessorFamily = 'Intel' }
			expected = 'fail'
			check = 'epic_minimum_processor'
			checkState = 'fail'
			why = 'Epic lists Apple Silicon M1/M2 as the minimum processor'
		},
		@{
			name = '8 GB memory fails the Epic memory row'
			inputs = @{ MacOSVersion = '15.6'; XcodeVersion = '26.1.1'; MemoryGB = 8 }
			expected = 'fail'
			check = 'epic_minimum_memory'
			checkState = 'fail'
			why = 'Epic lists 16 GB as the minimum memory'
		},
		@{
			name = 'a host without Metal 1.2 fails'
			inputs = @{ MacOSVersion = '15.6'; XcodeVersion = '26.1.1'; MetalSupported = 'no' }
			expected = 'fail'
			check = 'epic_metal_compatibility'
			checkState = 'fail'
			why = 'Epic lists Metal 1.2 compatible video cards'
		},
		@{
			name = 'no observations at all stay unverified'
			inputs = @{}
			expected = 'unverified'
			check = 'epic_minimum_macos'
			checkState = 'unverified'
			why = 'nothing observed must never pass'
		},
		@{
			name = 'an unreadable macOS value stays unverified instead of passing'
			inputs = @{ MacOSVersion = 'unknown'; XcodeVersion = '26.1.1' }
			expected = 'unverified'
			check = 'epic_minimum_macos'
			checkState = 'unverified'
			why = 'a declared value with no version number cannot be proven either way'
		}
	)

	foreach ($fixture in $fixtures) {
		$groups++
		$inputs = [ordered]@{
			MacOSVersion = $fixture.inputs.MacOSVersion
			XcodeVersion = $fixture.inputs.XcodeVersion
			ProcessorFamily = $fixture.inputs.ProcessorFamily
			MemoryGB = $fixture.inputs.MemoryGB
			MetalSupported = $fixture.inputs.MetalSupported
			RunId = "selftest-$groups"
		}
		$result = Get-MacHostVerdict -Inputs $inputs
		$matched = @($result.checks | Where-Object { $_.check -eq $fixture.check })
		try {
			Assert-True ($matched.Count -eq 1) "$($fixture.name): expected exactly one '$($fixture.check)' check, observed $($matched.Count)"
			Assert-True ($matched[0].state -eq $fixture.checkState) "$($fixture.name): expected $($fixture.check)=$($fixture.checkState), observed $($matched[0].state)"
			Assert-True ($result.verdict -eq $fixture.expected) "$($fixture.name): expected verdict $($fixture.expected), observed $($result.verdict)"
			Write-Output ("PASS: {0} -> {1} ({2})" -f $fixture.name, $result.verdict, $fixture.why)
		} catch {
			$failures++
			Write-Output "FAIL: $($_.Exception.Message)"
		}
	}

	# Report writing must be exclusive, record the sources, and refuse an existing path.
	$groups++
	$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ue-machost-selftest-' + [Guid]::NewGuid().ToString('N'))
	$reportPath = Join-Path $tempRoot 'evidence\mac-host.json'
	try {
		$inputs = [ordered]@{ MacOSVersion = '15.6'; XcodeVersion = '26.1.1'; ProcessorFamily = 'M3'; MemoryGB = 32; MetalSupported = 'yes'; RunId = 'selftest-report' }
		$result = Get-MacHostVerdict -Inputs $inputs
		$written = Write-VerdictReport -Path $reportPath -Report $result.report
		$parsed = Get-Content -LiteralPath $written -Raw | ConvertFrom-Json
		Assert-True ($parsed.verdict -eq 'pass') 'report round-trip keeps the verdict'
		Assert-True (@($parsed.sources).Count -eq 2) 'report records both source URLs'
		Assert-True ($parsed.sources[0].referenced_on -eq $sourceReferencedOn) 'report records the source reference date'
		Assert-True ($parsed.requirements.rule -match 'intersection') 'report states the intersection rule'
		$refused = ''
		try { $null = Write-VerdictReport -Path $reportPath -Report $result.report } catch { $refused = $_.Exception.Message }
		Assert-True ($refused.Contains('already exists')) 'an existing report path is refused instead of overwritten'
		Write-Output 'PASS: report is created exclusively, records both sources and refuses an existing path'
	} catch {
		$failures++
		Write-Output "FAIL: $($_.Exception.Message)"
	} finally {
		if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
	}

	# The tool must not launch any host probe. The probe names are assembled here so this assertion
	# cannot match its own source text.
	$groups++
	try {
		$scriptText = [System.IO.File]::ReadAllText($PSCommandPath)
		$probeNames = @(('sw' + '_vers'), ('xcode' + 'build'))
		$launchNames = @(('Start' + '-Process'), ('Process' + 'StartInfo'), ('Invoke' + '-BoundedProcess'))
		foreach ($launchName in $launchNames) {
			Assert-True (-not $scriptText.Contains($launchName)) "the tool must not contain a process launch surface ($launchName)"
		}
		foreach ($probeName in $probeNames) {
			Assert-True ($scriptText.Contains($probeName)) "the tool must document that it does not run $probeName"
			Assert-True (-not $scriptText.Contains('& ' + $probeName)) "the tool must not invoke $probeName"
		}
		Write-Output 'PASS: the tool contains no process launch surface and never invokes the host probes'
	} catch {
		$failures++
		Write-Output "FAIL: $($_.Exception.Message)"
	}

	# Windows PowerShell 5.1 reads a BOM-less UTF-8 script as ANSI: one non-ASCII byte anywhere in this
	# file turns its Japanese literals into mojibake and the parser aborts before -SelfTest can run, so
	# a green pwsh run would hide a suite that never starts under 5.1. The tool therefore keeps every
	# literal ASCII and spells the Japanese document text from code points. Both shells must start.
	$groups++
	try {
		$ownBytes = [System.IO.File]::ReadAllBytes($PSCommandPath)
		$nonAsciiCount = @($ownBytes | Where-Object { $_ -ge 0x80 }).Count
		Assert-True ($nonAsciiCount -eq 0) "the tool stays pure ASCII so Windows PowerShell 5.1 can parse it; found $nonAsciiCount non-ASCII byte(s)"
		Assert-True (-not ($ownBytes.Length -ge 3 -and $ownBytes[0] -eq 0xEF -and $ownBytes[1] -eq 0xBB -and $ownBytes[2] -eq 0xBF)) 'the tool carries no UTF-8 BOM'
		Assert-True ((ConvertFrom-CodePointText -CodePoint @(0x4E21, 0x8868, 0x306E, 0x4EA4, 0x5DEE)) -ceq $docCrossTable) 'the code-point helper reproduces the document text it matches'
		Assert-True ($qaRequiredFields.Count -eq 6) 'the QA row field list keeps all six required fields'
		Write-Output 'PASS: the tool is pure ASCII with no BOM and spells the Japanese document text from code points'
	} catch {
		$failures++
		Write-Output "FAIL: $($_.Exception.Message)"
	}

	# The docs the tool's rules come from must keep carrying every row the verdict relies on, at the
	# same versions and with the sources attached. A trimmed doc or a drifted version number fails here.
	$groups++
	try {
		$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
		$packageDoc = Join-Path $repoRoot 'docs\04-package.md'
		$qaTemplate = Join-Path $repoRoot 'templates\QA.md'
		Assert-True (Test-Path -LiteralPath $packageDoc -PathType Leaf) 'docs/04-package.md exists'
		Assert-True (Test-Path -LiteralPath $qaTemplate -PathType Leaf) 'templates/QA.md exists'
		$packageText = [System.IO.File]::ReadAllText($packageDoc)
		$qaText = [System.IO.File]::ReadAllText($qaTemplate)

		foreach ($required in @('macOS Sonoma 14.5', 'macOS Sequoia 15', '16 GB', 'Metal 1.2', '26.0', '26.1.1', 'M1/M2', 'Apple Silicon M3')) {
			Assert-True ($packageText.Contains($required)) "docs/04-package.md keeps the Epic UE 5.8 row '$required'"
		}
		Assert-True ($packageText.Contains($sourceEpic)) 'docs/04-package.md links the Epic macOS requirements page'
		Assert-True ($packageText.Contains($sourceApple)) 'docs/04-package.md links the Apple Xcode support table'
		Assert-True ($packageText.Contains($sourceReferencedOn)) 'docs/04-package.md records the source reference date'
		Assert-True ($packageText.Contains($docCrossTable)) 'docs/04-package.md states the intersection rule'
		Assert-True ($packageText.Contains('scripts/Test-UEMacHostRequirements.ps1')) 'docs/04-package.md points at the verdict tool'

		Assert-True ($qaText.Contains($qaMacHostRow)) 'templates/QA.md has a Mac host pass/fail row'
		foreach ($required in $qaRequiredFields) {
			Assert-True ($qaText.Contains($required)) "templates/QA.md Mac host row records '$required'"
		}
		Assert-True ($qaText.Contains('evidence/mac-host.json')) 'templates/QA.md names the verdict report path'
		Assert-True ($qaText.Contains($qaCross)) 'templates/QA.md states that the Mac host verdict uses both vendor tables'
		# The documented versions must be the ones this tool enforces, not a stale copy.
		Assert-True ($packageText.Contains($epicMinimumMacOS.ToString())) 'docs/04-package.md records the minimum macOS this tool enforces'
		Assert-True ($packageText.Contains($epicMinimumMemoryGB.ToString())) 'docs/04-package.md records the minimum memory this tool enforces'
		Write-Output 'PASS: docs/04-package.md and templates/QA.md keep the Epic rows, both source URLs, the reference date and the Mac host QA row'
	} catch {
		$failures++
		Write-Output "FAIL: $($_.Exception.Message)"
	}

	Write-Output ("SELFTEST GROUPS: {0} executed, {1} failed" -f $groups, $failures)
	if ($failures -gt 0) {
		Write-Output 'SELFTEST: FAIL'
	} else {
		Write-Output 'SELFTEST: all groups PASS'
	}
	# The failure count travels in a script-scope variable: capturing the function's return value
	# into a variable would swallow every PASS/FAIL line it writes to the pipeline.
	$script:selfTestFailureCount = $failures
}

if ($SelfTest) {
	Invoke-SelfTest
	if ($script:selfTestFailureCount -gt 0) { exit 1 }
	exit 0
}

$inputSet = [ordered]@{
	MacOSVersion = $MacOSVersion
	XcodeVersion = $XcodeVersion
	ProcessorFamily = $ProcessorFamily
	MemoryGB = $MemoryGB
	MetalSupported = $MetalSupported
	RunId = $RunId
}

if ([string]::IsNullOrWhiteSpace($MacOSVersion) -and [string]::IsNullOrWhiteSpace($XcodeVersion) -and
	[string]::IsNullOrWhiteSpace($ProcessorFamily) -and $null -eq $MemoryGB -and [string]::IsNullOrWhiteSpace($MetalSupported)) {
	throw 'Invalid input: no host observation was supplied. Pass at least one of -MacOSVersion, -XcodeVersion, -ProcessorFamily, -MemoryGB, -MetalSupported (observed values only; the tool does not read the host itself).'
}

$result = Get-MacHostVerdict -Inputs $inputSet
Write-Output "VERDICT: $($result.verdict)"
foreach ($check in $result.checks) {
	Write-Output ("CHECK: {0} = {1} - {2}" -f $check.check, $check.state, $check.detail)
}

if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
	$written = Write-VerdictReport -Path $ReportPath -Report $result.report
	Write-Output "REPORT: $written"
}

exit (Exit-CodeForVerdict $result.verdict)
