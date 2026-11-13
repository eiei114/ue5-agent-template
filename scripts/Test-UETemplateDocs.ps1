[CmdletBinding()]
param(
	# Defaults to the repository that contains this script. A different root is
	# accepted so the same gate can be pointed at a fixture copy; the negative
	# cases below do exactly that.
	[string]$RepositoryRoot = ''
)

# This file is kept ASCII-only so Windows PowerShell 5.1 parses it without a BOM
# and both hosts read the same source.
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
	$RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
} else {
	$RepositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
}
$productionRoot = Join-Path $RepositoryRoot 'Production'
$testId = [Guid]::NewGuid().ToString('N')
$fixtureRoot = Join-Path $productionRoot ('.docs-test-' + $testId)
$fixtureRepo = Join-Path $fixtureRoot 'repo'

# A heading identifier is either a full 40-hex commit SHA or an ISO calendar date.
# Nothing else is accepted: "Unreleased" alone cannot say which delivery a section
# describes, which is the defect this gate exists to prevent.
$headingIdentifierPattern = [regex]::new('(?<sha>\b[0-9a-f]{40}\b)|(?<date>\b\d{4}-\d{2}-\d{2}\b)')
$headingPattern = '^##\s'
$levelOnePattern = '^#\s'
# README's entry table: the second column is the file to read.
$readmeRouteRowRegex = [regex]::new('\|[^\r\n|]*\|[ \t]*CHANGELOG\.md[ \t]*\|')
# The trailing identifier of a heading, so a case can strip or replace it.
$headingTrailingIdentifierRegex = [regex]::new('\s*[-\u2014]\s*(\d{4}-\d{2}-\d{2}|[0-9a-f]{40})\s*$')

# Deliveries that must keep a level-2 section. The list is an explicit registry:
# when a delivery merges, add it here, otherwise the "section disappeared" check
# cannot see it. The five that merged with no entry at all are marked below.
$requiredSections = @(
	'DOT-2959',
	'DOT-2997',
	'DOT-3029',
	'DOT-3041',
	'DOT-3254',
	'DOT-3295',
	'DOT-3313',
	'DOT-3317',
	'DOT-3340',
	'DOT-3366',
	'DOT-3395',
	'DOT-3454',
	'UE-CI-002',
	'third-person-game recipe'
)
$previouslyUnrecorded = @('DOT-3029', 'UE-CI-002', 'DOT-3313', 'DOT-3317', 'DOT-3340')

function Assert-True([bool]$Condition, [string]$Message) {
	if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Read-TextFile([string]$Path) {
	return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
}

function Write-TextFile([string]$Path, [string]$Text) {
	[System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-Git([string]$Root, [string[]]$Arguments) {
	# Windows PowerShell 5.1 turns a native command's stderr into a terminating
	# error under `$ErrorActionPreference = 'Stop'`, so a deliberate `cat-file -e`
	# miss would abort the gate instead of being reported. Run git with a relaxed
	# preference and hand back the exit code.
	$previousPreference = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try {
		$output = @(& git -C $Root @Arguments 2>&1 | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
		$exitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $previousPreference
	}
	return [pscustomobject]@{ ExitCode = $exitCode; Lines = $output }
}

function Get-SectionBody([string[]]$Lines, [int]$HeadingIndex) {
	# Body of the section that starts at HeadingIndex: every non-blank line until
	# the next level-1 or level-2 heading.
	$body = New-Object System.Collections.Generic.List[string]
	for ($i = $HeadingIndex + 1; $i -lt $Lines.Count; $i++) {
		if ($Lines[$i] -match $headingPattern -or $Lines[$i] -match $levelOnePattern) { break }
		if (-not [string]::IsNullOrWhiteSpace($Lines[$i])) { $body.Add($Lines[$i]) }
	}
	return $body.ToArray()
}

function Get-AgentsReadFirstLines([string[]]$Lines) {
	# The read-first route is the first level-2 section of AGENTS.md, cut at the
	# second one, so a mention parked at the bottom of the file cannot satisfy it.
	$sectionCount = 0
	$routeLines = New-Object System.Collections.Generic.List[string]
	foreach ($line in $Lines) {
		if ($line -match $headingPattern) {
			$sectionCount++
			if ($sectionCount -ge 2) { break }
			continue
		}
		if ($sectionCount -eq 1) { $routeLines.Add($line) }
	}
	return $routeLines.ToArray()
}

function Get-DocsGateViolations([string]$Root) {
	$violations = New-Object System.Collections.Generic.List[string]
	$changelogPath = Join-Path $Root 'CHANGELOG.md'

	# ---- C1: the change log is reachable from the reading route ----
	if (-not (Test-Path -LiteralPath $changelogPath -PathType Leaf)) {
		$violations.Add('CHANGELOG.md: the tracked change log is missing, so no reading route can reach it')
	} else {
		$tracked = Invoke-Git $Root @('ls-files', '--error-unmatch', '--', 'CHANGELOG.md')
		if ($tracked.ExitCode -ne 0) {
			$violations.Add('CHANGELOG.md: the file exists but git does not track it, so a fresh clone cannot read it')
		}

		$readmePath = Join-Path $Root 'README.md'
		if (-not (Test-Path -LiteralPath $readmePath -PathType Leaf)) {
			$violations.Add('README.md: missing, so the entry table cannot name CHANGELOG.md')
		} elseif (-not $readmeRouteRowRegex.IsMatch((Read-TextFile $readmePath))) {
			$violations.Add('README.md: the entry table has no row whose reading target is CHANGELOG.md')
		}

		$agentsPath = Join-Path $Root 'AGENTS.md'
		if (-not (Test-Path -LiteralPath $agentsPath -PathType Leaf)) {
			$violations.Add('AGENTS.md: missing, so the read-first route cannot name CHANGELOG.md')
		} else {
			$namesChangelog = $false
			foreach ($line in (Get-AgentsReadFirstLines ((Read-TextFile $agentsPath) -split "`r?`n"))) {
				if ($line.Contains('CHANGELOG.md')) { $namesChangelog = $true; break }
			}
			if (-not $namesChangelog) {
				$violations.Add('AGENTS.md: the read-first section does not name CHANGELOG.md')
			}
		}

		# Both routes must point at the same file: two routes to two different files
		# would be two sources of truth. Inbound references are counted from tracked
		# files, which is what a fresh clone actually sees.
		$inboundFiles = @()
		$inbound = Invoke-Git $Root @('grep', '-l', '-F', 'CHANGELOG.md', '--', ':!CHANGELOG.md')
		if ($inbound.ExitCode -eq 0) {
			$inboundFiles = @($inbound.Lines | ForEach-Object { ($_ -split ':', 2)[0] })
		}
		if ($inboundFiles -notcontains 'README.md') {
			$violations.Add('README.md: no tracked file names CHANGELOG.md at the entry table route')
		}
		if ($inboundFiles -notcontains 'AGENTS.md') {
			$violations.Add('AGENTS.md: no tracked file names CHANGELOG.md at the read-first route')
		}
	}

	# ---- C2: every section heading says which delivery/version it describes ----
	if (Test-Path -LiteralPath $changelogPath -PathType Leaf) {
		$lines = (Read-TextFile $changelogPath) -split "`r?`n"
		$headingLines = New-Object System.Collections.Generic.List[string]
		$identifiers = New-Object System.Collections.Generic.List[string]
		for ($i = 0; $i -lt $lines.Count; $i++) {
			if ($lines[$i] -notmatch $headingPattern) { continue }
			$heading = $lines[$i]
			$headingLines.Add($heading)
			$tokens = $headingIdentifierPattern.Matches($heading)
			if ($tokens.Count -eq 0) {
				$violations.Add("CHANGELOG.md: heading `"$heading`" has no identifier (40-hex commit SHA or YYYY-MM-DD)")
			}
			foreach ($token in $tokens) {
				$identifier = $token.Value
				if ($token.Groups['date'].Success) {
					$parsed = [datetime]::MinValue
					$ok = [datetime]::TryParseExact($identifier, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)
					if (-not $ok) {
						$violations.Add("CHANGELOG.md: heading `"$heading`" carries $identifier, which is not a valid YYYY-MM-DD date")
					} elseif ($parsed.Date -gt (Get-Date).Date) {
						$violations.Add("CHANGELOG.md: heading `"$heading`" carries $identifier, which is later than today; take the delivery date from git log / gh pr list")
					}
				}
				if ($token.Groups['sha'].Success) {
					$identifiers.Add($identifier)
					# A SHA is checked only when it is written; a date is always
					# required. CI checks out with fetch-depth: 1, so an old merge
					# commit would not resolve there even though it does locally.
					$resolved = Invoke-Git $Root @('cat-file', '-e', "$identifier^{commit}")
					if ($resolved.ExitCode -ne 0) {
						$violations.Add("CHANGELOG.md: heading `"$heading`" names commit $identifier, which this repository cannot resolve (git cat-file -e $identifier^{commit})")
					}
				}
			}
			if ((Get-SectionBody $lines $i).Count -eq 0) {
				$violations.Add("CHANGELOG.md: heading `"$heading`" has an empty body; a section must record what changed, whether migration is needed, and the Unverified Scope")
			}
		}
		if ($headingLines.Count -eq 0) {
			$violations.Add('CHANGELOG.md: no level-2 section headings at all')
		}
		# A commit belongs to exactly one delivery, so one SHA must not describe two
		# sections. Calendar dates legitimately repeat and are not compared.
		foreach ($duplicate in @($identifiers | Group-Object | Where-Object { $_.Count -gt 1 })) {
			$violations.Add("CHANGELOG.md: commit $($duplicate.Name) is claimed by $($duplicate.Count) headings; one delivery, one section")
		}
		$headingText = $headingLines -join "`n"
		foreach ($required in $requiredSections) {
			if (-not $headingText.Contains($required)) {
				$violations.Add("CHANGELOG.md: no level-2 heading records $required; that delivery has no change log section")
			}
		}
	}

	return $violations.ToArray()
}

function Invoke-Gate([string]$Root) {
	return @(Get-DocsGateViolations $Root)
}

function Assert-GatePasses([string]$Root, [string]$Message) {
	$found = Invoke-Gate $Root
	Assert-True ($found.Count -eq 0) ($Message + ': ' + ($found -join '; '))
}

function Assert-GateFails([string]$Root, [string[]]$ExpectedFragments, [string]$Message) {
	$found = Invoke-Gate $Root
	Assert-True ($found.Count -gt 0) ("$Message did not fail the gate")
	foreach ($fragment in $ExpectedFragments) {
		$named = $false
		foreach ($violation in $found) {
			if ($violation.Contains($fragment)) { $named = $true; break }
		}
		Assert-True $named ("$Message did not name '" + $fragment + "' (gate reported: " + ($found -join '; ') + ')')
	}
}

$suiteError = $null
$originalFiles = @{}
$initialStatus = Invoke-Git $RepositoryRoot @('status', '--porcelain', '--untracked-files=all')
if ($initialStatus.ExitCode -ne 0) { throw 'Could not record the developer checkout status before testing.' }
$initialCheckoutStatus = @($initialStatus.Lines)

try {
	# ---- positive: the checkout under test satisfies the contract ----
	Assert-GatePasses $RepositoryRoot 'the CHANGELOG.md route and heading identifiers must hold on the checkout under test'
	Write-Output 'PASS: CHANGELOG.md is named by both the README entry table and the AGENTS.md read-first route, and every level-2 heading carries a resolvable identifier'

	$changelogText = Read-TextFile (Join-Path $RepositoryRoot 'CHANGELOG.md')
	$missing = @($previouslyUnrecorded | Where-Object { -not $changelogText.Contains($_) })
	Assert-True ($missing.Count -eq 0) ('the five deliveries merged with no entry now have one: ' + ($missing -join ', '))
	Write-Output 'PASS: DOT-3029, UE-CI-002, DOT-3313, DOT-3317 and DOT-3340 now have a change log entry'

	# ---- negative cases on a disposable clone ----
	# The mutations never touch the developer checkout, and each one is restored
	# before the next so a restored tree is proven silent again: the gate cannot
	# rot back into an empty assertion.
	[System.IO.Directory]::CreateDirectory($productionRoot) | Out-Null
	$cloned = Invoke-Git $RepositoryRoot @('clone', '--quiet', '--local', '--no-hardlinks', '--no-checkout', $RepositoryRoot, $fixtureRepo)
	Assert-True ($cloned.ExitCode -eq 0) ('the disposable docs fixture clone is created: ' + ($cloned.Lines -join ' '))
	$checkedOut = Invoke-Git $fixtureRepo @('checkout', '--quiet', '--detach', 'HEAD')
	Assert-True ($checkedOut.ExitCode -eq 0) ('the docs fixture clone is checked out: ' + ($checkedOut.Lines -join ' '))
	# The clone carries HEAD's content; copy the files under test so an
	# uncommitted working tree is exercised too.
	foreach ($name in 'CHANGELOG.md', 'README.md', 'AGENTS.md') {
		Copy-Item -LiteralPath (Join-Path $RepositoryRoot $name) -Destination (Join-Path $fixtureRepo $name) -Force
		$originalFiles[$name] = [System.IO.File]::ReadAllBytes((Join-Path $fixtureRepo $name))
	}
	Assert-GatePasses $fixtureRepo 'the disposable fixture clone must pass the gate before mutation'
	Write-Output 'PASS: the disposable fixture clone reproduces the passing state'

	# 1. Deleting CHANGELOG.md must fail and name the path.
	Remove-Item -LiteralPath (Join-Path $fixtureRepo 'CHANGELOG.md') -Force
	Assert-GateFails $fixtureRepo @('CHANGELOG.md: the tracked change log is missing') 'deleting CHANGELOG.md'
	Write-Output 'PASS: negative case - deleting CHANGELOG.md fails the gate and names CHANGELOG.md'
	[System.IO.File]::WriteAllBytes((Join-Path $fixtureRepo 'CHANGELOG.md'), $originalFiles['CHANGELOG.md'])
	Assert-GatePasses $fixtureRepo 'restoring CHANGELOG.md must silence the gate'
	Write-Output 'PASS: negative case - restoring CHANGELOG.md silences the gate'

	# 2. Removing the README route row must fail and name README.md.
	$readmePath = Join-Path $fixtureRepo 'README.md'
	$readmeMutated = ((Read-TextFile $readmePath) -split "`r?`n" | Where-Object { -not $readmeRouteRowRegex.IsMatch($_) }) -join "`n"
	Write-TextFile $readmePath $readmeMutated
	Assert-GateFails $fixtureRepo @('README.md: the entry table has no row whose reading target is CHANGELOG.md') 'removing the README route row'
	Write-Output 'PASS: negative case - removing the README route row fails the gate and names README.md'
	[System.IO.File]::WriteAllBytes($readmePath, $originalFiles['README.md'])
	Assert-GatePasses $fixtureRepo 'restoring the README route row must silence the gate'
	Write-Output 'PASS: negative case - restoring the README route row silences the gate'

	# 3. Removing the identifier from one heading must fail and name the heading.
	$changelogPath = Join-Path $fixtureRepo 'CHANGELOG.md'
	$strippedHeading = $null
	$changelogMutated = ((Read-TextFile $changelogPath) -split "`r?`n" | ForEach-Object {
		$line = $_
		if ($null -eq $strippedHeading -and $line -match $headingPattern -and $headingIdentifierPattern.IsMatch($line)) {
			$strippedHeading = $line
			$line = $headingTrailingIdentifierRegex.Replace($line, '')
		}
		$line
	}) -join "`n"
	Assert-True ($null -ne $strippedHeading) 'the fixture found a heading whose identifier could be stripped'
	Write-TextFile $changelogPath $changelogMutated
	Assert-GateFails $fixtureRepo @('CHANGELOG.md: heading', 'has no identifier') 'removing a heading identifier'
	Write-Output 'PASS: negative case - removing a heading identifier fails the gate and names CHANGELOG.md'
	[System.IO.File]::WriteAllBytes($changelogPath, $originalFiles['CHANGELOG.md'])
	Assert-GatePasses $fixtureRepo 'restoring the heading identifier must silence the gate'
	Write-Output 'PASS: negative case - restoring the heading identifier silences the gate'

	# 4. Writing an unresolvable 40-hex SHA must fail and name that SHA.
	$badSha = '0123456789abcdef0123456789abcdef01234567'
	$replacedHeading = $null
	$changelogMutated = ((Read-TextFile $changelogPath) -split "`r?`n" | ForEach-Object {
		$line = $_
		if ($null -eq $replacedHeading -and $line -match $headingPattern -and $headingIdentifierPattern.IsMatch($line)) {
			$replacedHeading = $line
			$line = $headingTrailingIdentifierRegex.Replace($line, " - $badSha")
		}
		$line
	}) -join "`n"
	Assert-True ($null -ne $replacedHeading) 'the fixture found a heading whose identifier could be replaced'
	Write-TextFile $changelogPath $changelogMutated
	Assert-GateFails $fixtureRepo @("names commit $badSha", 'cannot resolve') 'writing an unresolvable SHA'
	Write-Output 'PASS: negative case - an unresolvable SHA fails the gate and names the SHA'
	[System.IO.File]::WriteAllBytes($changelogPath, $originalFiles['CHANGELOG.md'])
	Assert-GatePasses $fixtureRepo 'restoring the heading identifier after the SHA case must silence the gate'
	Write-Output 'PASS: negative case - restoring the heading SHA silences the gate'

	# 5. AGENTS.md must hold the route inside its read-first section.
	#    Replacing the file name everywhere proves the check is scoped to that
	#    section rather than to any occurrence in the file.
	$agentsPath = Join-Path $fixtureRepo 'AGENTS.md'
	$agentsMutated = ((Read-TextFile $agentsPath) -split "`r?`n" | ForEach-Object { $_.Replace('CHANGELOG.md', 'the change log') }) -join "`n"
	Write-TextFile $agentsPath $agentsMutated
	Assert-GateFails $fixtureRepo @('AGENTS.md: the read-first section does not name CHANGELOG.md') 'removing the AGENTS.md route'
	Write-Output 'PASS: negative case - removing the AGENTS.md read-first route fails the gate and names AGENTS.md'
	[System.IO.File]::WriteAllBytes($agentsPath, $originalFiles['AGENTS.md'])
	Assert-GatePasses $fixtureRepo 'restoring the AGENTS.md route must silence the gate'
	Write-Output 'PASS: negative case - restoring the AGENTS.md route silences the gate'

	# 6. One delivery must not drop out of the change log silently.
	$droppedHeading = $null
	$changelogMutated = ((Read-TextFile $changelogPath) -split "`r?`n" | ForEach-Object {
		$line = $_
		if ($null -eq $droppedHeading -and $line -match $headingPattern -and $line.Contains('DOT-3029')) {
			$droppedHeading = $line
			$line = '## Unreleased placeholder 2026-11-05'
		}
		$line
	}) -join "`n"
	Assert-True ($null -ne $droppedHeading) 'the fixture found the DOT-3029 heading'
	Write-TextFile $changelogPath $changelogMutated
	Assert-GateFails $fixtureRepo @('no level-2 heading records DOT-3029') 'renaming the DOT-3029 heading'
	Write-Output 'PASS: negative case - dropping a delivery from the change log fails the gate and names the delivery'
	[System.IO.File]::WriteAllBytes($changelogPath, $originalFiles['CHANGELOG.md'])
	Assert-GatePasses $fixtureRepo 'restoring the DOT-3029 heading must silence the gate'
	Write-Output 'PASS: negative case - restoring the DOT-3029 heading silences the gate'
} catch {
	$suiteError = $_
} finally {
	if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
		Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
	}
	$cleanupProblems = New-Object System.Collections.Generic.List[string]
	if (Test-Path -LiteralPath $fixtureRoot) { $cleanupProblems.Add("fixture root still exists: $fixtureRoot") }
	if (Test-Path -LiteralPath $productionRoot -PathType Container) {
		foreach ($entry in @(Get-ChildItem -LiteralPath $productionRoot -Force)) {
			if ($entry.Name -ceq 'PLACEHOLDER.md') { continue }
			$cleanupProblems.Add("Production/$($entry.Name): unexpected entry (ignored by .gitignore, so git status does not report it)")
		}
	}
	$finalStatus = Invoke-Git $RepositoryRoot @('status', '--porcelain', '--untracked-files=all')
	$finalCheckoutStatus = @($finalStatus.Lines)
	if (($finalCheckoutStatus -join "`n") -cne ($initialCheckoutStatus -join "`n")) {
		$cleanupProblems.Add('test suite leaves the developer checkout unchanged')
		$cleanupProblems.Add('before: ' + ($initialCheckoutStatus -join ' | '))
		$cleanupProblems.Add('after: ' + ($finalCheckoutStatus -join ' | '))
	}
	if ($cleanupProblems.Count -gt 0) {
		if ($null -ne $suiteError) { Write-Output "ASSERT FAILED: $($suiteError.Exception.Message)" }
		Assert-True $false ('test suite did not leave a clean tree: ' + ($cleanupProblems -join '; '))
	}
	if ($null -ne $suiteError) { throw $suiteError }
}
