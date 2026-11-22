[CmdletBinding()]
param()

# Gate: an assertion call in a regression suite must be a real call.
#
# PowerShell parses a second command name that appears in the middle of a command invocation as a
# plain string argument and raises no syntax error. Two `Assert-True` calls joined on one physical line
# by a tab therefore become ONE call with extra positional arguments, and the second assertion is never
# evaluated while the suite still prints PASS and exits 0 (DOT-3460). This gate parses every scripts/*.ps1
# with the PowerShell AST and reports, with path and line:
#   1. an `Assert-*` name that is not in command position (a dropped call), and
#   2. a call of an `Assert-*` helper defined in the same file that passes more positional arguments
#      than the helper declares (the same defect seen from the call site).
# The negative cases at the bottom run the gate against disposable copies, so a gate that silently
# stops matching fails here instead of passing forever.

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$scriptsRoot = Join-Path $repoRoot 'scripts'
$assertNamePattern = '^Assert-[A-Za-z]'

function Assert-True([bool]$Condition, [string]$Message) {
	if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Get-AssertCallReport([string]$Path, [string]$Text) {
	$tokens = $null
	$parseErrors = $null
	$ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$parseErrors)
	$problems = New-Object System.Collections.Generic.List[string]
	foreach ($parseError in @($parseErrors)) {
		$problems.Add("${Path}:$($parseError.Extent.StartLineNumber): parse error: $($parseError.Message)")
	}

	$commands = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
	$commandNameOffsets = @{}
	foreach ($command in $commands) {
		if ($command.CommandElements.Count -gt 0) {
			$commandNameOffsets[$command.CommandElements[0].Extent.StartOffset] = $true
		}
	}

	# Occurrences in code: bare words that look like an assert helper name. Strings and comments are
	# separate token kinds, so a message that mentions a helper name is not counted.
	$occurrences = 0
	$calls = 0
	for ($i = 0; $i -lt $tokens.Count; $i++) {
		$token = $tokens[$i]
		if ($token.Kind -ne [System.Management.Automation.Language.TokenKind]::Generic -and $token.Kind -ne [System.Management.Automation.Language.TokenKind]::Identifier) { continue }
		if ($token.Text -notmatch $assertNamePattern) { continue }
		if ($i -gt 0 -and $tokens[$i - 1].Kind -eq [System.Management.Automation.Language.TokenKind]::Function) { continue }
		$occurrences++
		if ($commandNameOffsets.ContainsKey($token.Extent.StartOffset)) {
			$calls++
		} else {
			$problems.Add("${Path}:$($token.Extent.StartLineNumber): '$($token.Text)' is not in command position, so PowerShell passes it as a string argument and the assertion never runs")
		}
	}

	# Declared positional capacity of each helper defined in this file. -1 means unbounded.
	$declared = @{}
	$parameterTypes = @{}
	foreach ($function in @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
		if ($function.Name -notmatch $assertNamePattern) { continue }
		$parameters = @()
		if ($null -ne $function.Parameters) { $parameters = @($function.Parameters) }
		elseif ($null -ne $function.Body.ParamBlock) { $parameters = @($function.Body.ParamBlock.Parameters) }
		$capacity = $parameters.Count
		foreach ($parameter in $parameters) {
			foreach ($attribute in $parameter.Attributes) {
				if ($attribute -is [System.Management.Automation.Language.AttributeAst]) {
					foreach ($named in $attribute.NamedArguments) {
						if ($named.ArgumentName -eq 'ValueFromRemainingArguments') { $capacity = -1 }
					}
				}
			}
			$isSwitch = $false
			foreach ($attribute in $parameter.Attributes) {
				if ($attribute -is [System.Management.Automation.Language.TypeConstraintAst] -and $attribute.TypeName.Name -eq 'switch') { $isSwitch = $true }
			}
			$parameterTypes[$function.Name.ToLowerInvariant() + '|' + $parameter.Name.VariablePath.UserPath.ToLowerInvariant()] = $isSwitch
		}
		if ($declared.ContainsKey($function.Name.ToLowerInvariant())) {
			$previous = $declared[$function.Name.ToLowerInvariant()]
			if ($previous -eq -1 -or $capacity -eq -1) { $capacity = -1 } elseif ($previous -gt $capacity) { $capacity = $previous }
		}
		$declared[$function.Name.ToLowerInvariant()] = $capacity
	}

	foreach ($command in $commands) {
		$name = $command.GetCommandName()
		if ($null -eq $name -or $name -notmatch $assertNamePattern) { continue }
		$key = $name.ToLowerInvariant()
		if (-not $declared.ContainsKey($key) -or $declared[$key] -eq -1) { continue }
		$positional = 0
		$unknown = $false
		for ($e = 1; $e -lt $command.CommandElements.Count; $e++) {
			$element = $command.CommandElements[$e]
			if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
				if ($null -eq $element.Argument -and $e + 1 -lt $command.CommandElements.Count) {
					$isSwitch = $parameterTypes[$key + '|' + $element.ParameterName.ToLowerInvariant()]
					if ($isSwitch -ne $true) { $e++ }
				}
				continue
			}
			if ($element -is [System.Management.Automation.Language.VariableExpressionAst] -and $element.Splatted) { $unknown = $true; continue }
			$positional++
		}
		if (-not $unknown -and $positional -gt $declared[$key]) {
			$problems.Add("${Path}:$($command.Extent.StartLineNumber): '$name' is called with $positional positional arguments but declares $($declared[$key]); the extra arguments are silently dropped")
		}
	}

	[pscustomobject]@{ Path = $Path; Occurrences = $occurrences; Calls = $calls; Problems = @($problems) }
}

$suiteError = $null
$workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('.ue-script-gate-' + [Guid]::NewGuid().ToString('N'))
try {
	$scriptFiles = @(Get-ChildItem -LiteralPath $scriptsRoot -Filter '*.ps1' -File | Sort-Object Name)
	Assert-True ($scriptFiles.Count -ge 5) "the gate scanned only $($scriptFiles.Count) script files, so it is not looking at scripts/"

	$totalOccurrences = 0
	$totalCalls = 0
	$allProblems = New-Object System.Collections.Generic.List[string]
	$reports = @{}
	foreach ($file in $scriptFiles) {
		$report = Get-AssertCallReport $file.Name ([System.IO.File]::ReadAllText($file.FullName))
		$reports[$file.Name] = $report
		$totalOccurrences += $report.Occurrences
		$totalCalls += $report.Calls
		foreach ($problem in $report.Problems) { $allProblems.Add($problem) }
	}
	Assert-True ($allProblems.Count -eq 0) ("dropped or over-argumented assertion calls: " + ($allProblems -join ' | '))
	Assert-True ($totalOccurrences -eq $totalCalls) "assert names in code ($totalOccurrences) differ from parsed calls ($totalCalls)"
	Assert-True ($reports['Test-UETemplateScaffold.ps1'].Calls -ge 70) "the scaffold suite reports only $($reports['Test-UETemplateScaffold.ps1'].Calls) assertion calls, so the gate is not counting them"
	Write-Output "PASS: every assert name in scripts/*.ps1 is a real call ($totalCalls calls in $($scriptFiles.Count) files, 0 dropped, 0 with extra positional arguments)"

	New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

	# Negative 1: join two consecutive assertions of the real scaffold suite with a tab, the exact
	# shape of the DOT-3460 defect. The gate must name the file and the physical line, and fall silent
	# again on the restored text.
	$scaffoldPath = Join-Path $scriptsRoot 'Test-UETemplateScaffold.ps1'
	$original = [System.IO.File]::ReadAllText($scaffoldPath)
	$lines = $original -split "`n"
	$secondIndex = -1
	for ($n = 1; $n -lt $lines.Count; $n++) {
		if ($lines[$n].Contains("'different project names produce different lock identifiers'")) { $secondIndex = $n; break }
	}
	Assert-True ($secondIndex -gt 0) 'the lock identifier assertion that DOT-3460 split is missing from the scaffold suite'
	Assert-True ($lines[$secondIndex - 1].TrimStart().StartsWith('Assert-True ')) 'the line before the lock identifier assertion is no longer an assertion, so the injection fixture cannot be built'
	$joinedLines = New-Object System.Collections.Generic.List[string]
	for ($n = 0; $n -lt $lines.Count; $n++) {
		if ($n -eq $secondIndex - 1) { $joinedLines.Add($lines[$n].TrimEnd("`r") + "`t" + $lines[$secondIndex].TrimStart()); continue }
		if ($n -eq $secondIndex) { continue }
		$joinedLines.Add($lines[$n])
	}
	$joinedPath = Join-Path $workRoot 'Test-UETemplateScaffold.ps1'
	[System.IO.File]::WriteAllText($joinedPath, ($joinedLines -join "`n"))
	$joinedReport = Get-AssertCallReport 'Test-UETemplateScaffold.ps1' ([System.IO.File]::ReadAllText($joinedPath))
	$expectedLine = $secondIndex  # 1-based line number of the joined line is index - 1 + 1
	# One defect is seen twice: as a name outside command position, and as 5 positional arguments
	# passed to a 2-parameter helper. Both must name the same line.
	Assert-True ($joinedReport.Problems.Count -eq 2) "the injected tab-joined assertion produced $($joinedReport.Problems.Count) problems instead of 2"
	Assert-True ($joinedReport.Problems[0].StartsWith("Test-UETemplateScaffold.ps1:${expectedLine}: 'Assert-True' is not in command position")) "the gate did not name the file and line $expectedLine of the joined assertion: $($joinedReport.Problems[0])"
	Assert-True ($joinedReport.Problems[1].StartsWith("Test-UETemplateScaffold.ps1:${expectedLine}: 'Assert-True' is called with 5 positional arguments but declares 2")) "the gate did not report the extra positional arguments on line ${expectedLine}: $($joinedReport.Problems[1])"
	Assert-True ($joinedReport.Occurrences -eq $joinedReport.Calls + 1) 'the injected join did not make the assert-name count exceed the parsed call count by one'
	Write-Output "PASS: a tab-joined pair of assertions is reported by path and line $expectedLine"

	$restoredPath = Join-Path $workRoot 'restored.ps1'
	[System.IO.File]::WriteAllText($restoredPath, $original)
	$restoredReport = Get-AssertCallReport 'Test-UETemplateScaffold.ps1' ([System.IO.File]::ReadAllText($restoredPath))
	Assert-True ($restoredReport.Problems.Count -eq 0 -and $restoredReport.Occurrences -eq $restoredReport.Calls) 'the gate still reports problems after the join is restored'
	Write-Output 'PASS: the gate is silent again once the assertions are on separate lines'

	# Negative 2: the same defect seen from the call site, with a fixture that has no joined line.
	$extraText = "function Assert-True([bool]`$Condition, [string]`$Message) { if (-not `$Condition) { throw `$Message } }`nAssert-True `$true 'ok'`nAssert-True `$true 'ok' 'dropped message'`n"
	$extraReport = Get-AssertCallReport 'extra.ps1' $extraText
	Assert-True ($extraReport.Problems.Count -eq 1 -and $extraReport.Problems[0].StartsWith("extra.ps1:3: 'Assert-True' is called with 3 positional arguments but declares 2")) "an assertion with an extra positional argument was not named by line: $($extraReport.Problems -join ' | ')"
	Write-Output 'PASS: an assertion call with more positional arguments than declared is reported by path and line'

	# Negative 3: an empty or comment-only file is not mistaken for a file with problems, and a
	# helper name that appears only in a string or comment is not counted as a dropped call.
	$quietReport = Get-AssertCallReport 'quiet.ps1' "# Assert-True is mentioned here`n`$m = 'Assert-True 1 2 3'`nWrite-Output 'Assert-True'`n"
	Assert-True ($quietReport.Problems.Count -eq 0 -and $quietReport.Occurrences -eq 0) 'a helper name inside a comment or string was counted as code'
	Write-Output 'PASS: helper names inside comments and strings are not counted as calls'
} catch {
	$suiteError = $_
} finally {
	if (Test-Path -LiteralPath $workRoot) { Remove-Item -LiteralPath $workRoot -Recurse -Force }
}

if ($null -ne $suiteError) {
	Write-Output $suiteError.Exception.Message
	exit 1
}
exit 0
