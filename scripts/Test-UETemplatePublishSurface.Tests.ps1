[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$productionRoot = Join-Path $repoRoot 'Production'
$auditor = Join-Path $PSScriptRoot 'Test-UETemplatePublishSurface.ps1'
$initialCheckoutStatus = @(& git -C $repoRoot status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0) { throw 'Could not record the developer checkout status before testing.' }
$testId = [Guid]::NewGuid().ToString('N')
$fixtureRoot = Join-Path $productionRoot ('.publish-surface-test-' + $testId)

function Assert-True([bool]$Condition, [string]$Message) {
	if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Assert-Eq([string]$Actual, [string]$Expected, [string]$Message) {
	if ($Actual -cne $Expected) { throw "ASSERT FAILED: $Message (expected [$Expected], got [$Actual])" }
}

function Write-FixtureText([string]$Path, [string]$Content) {
	$parent = Split-Path -Parent $Path
	[System.IO.Directory]::CreateDirectory($parent) | Out-Null
	[System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function New-FixtureRepo([string]$Name) {
	# A throwaway repository that mimics the template's published shape: one
	# tracked placeholder under Production/, a README with resolvable links,
	# and a .gitignore that lists the generated directories by name. It is
	# created inside Production/ so the developer checkout is untouched by
	# `git status` (Production/* is ignored) and removed in the finally block.
	$path = Join-Path $fixtureRoot $Name
	[System.IO.Directory]::CreateDirectory($path) | Out-Null
	& git -C $path init --quiet -b main
	if ($LASTEXITCODE -ne 0) { throw "Could not initialise fixture repository $Name." }
	# The line-feed fixture needs a real path that contains U+000A; Windows git
	# refuses such an index entry under protectNTFS.
	& git -C $path config core.protectNTFS false
	$ignoreLines = @(
		'Production/*',
		'!Production/PLACEHOLDER.md',
		'Out/',
		'Art/',
		'Saved/',
		# The template's own .gitignore already lists auth.json, which makes
		# the tracked-file blind spot of `git check-ignore` observable here.
		'auth.json',
		'*.zip'
	)
	# Assign first, then join: `f (join-path ...) @(...) -join "`n"` would pass the
	# array as a space-joined string and leave -join unused.
	Write-FixtureText (Join-Path $path '.gitignore') ($ignoreLines -join "`n")
	$readmeLines = @(
		'# Fixture template',
		'',
		'Read [AGENTS.md](AGENTS.md) and [the start guide](docs/01-start.md).',
		'',
		'The placeholder lives at [Production/PLACEHOLDER.md](Production/PLACEHOLDER.md).'
	)
	Write-FixtureText (Join-Path $path 'README.md') ($readmeLines -join "`n")
	Write-FixtureText (Join-Path $path 'AGENTS.md') 'Fixture agent contract.'
	Write-FixtureText (Join-Path $path 'docs\01-start.md') 'See [the readme](../README.md).'
	Write-FixtureText (Join-Path $path 'Production\PLACEHOLDER.md') 'placeholder'
	Write-FixtureText (Join-Path $path 'scripts\keep.ps1') 'Write-Output "fixture"'
	& git -C $path add -A
	& git -C $path -c user.name='fixture' -c user.email='fixture@example.invalid' commit --quiet -m 'fixture baseline'
	if ($LASTEXITCODE -ne 0) { throw "Could not commit the fixture baseline in $Name." }
	return $path
}

function Add-FixturePath([string]$Repository, [string]$RelativePath, [string]$Content) {
	$full = Join-Path $Repository ($RelativePath -replace '/', '\')
	Write-FixtureText $full $Content
}

function Commit-Fixture([string]$Repository, [string]$Message, [switch]$Force) {
	if ($Force) {
		& git -C $Repository add -A --force
	} else {
		& git -C $Repository add -A
	}
	& git -C $Repository -c user.name='fixture' -c user.email='fixture@example.invalid' commit --quiet -m $Message
	if ($LASTEXITCODE -ne 0) { throw "Could not commit '$Message' in the fixture." }
}

function Add-FixtureIndexPath([string]$Repository, [string]$RelativePath, [string]$Content) {
	# Records the literal path in the index without touching the worktree. On a
	# case-insensitive filesystem `git add` re-reads the on-disk directory names
	# and loses a differently-cased spelling, which is exactly the case this
	# fixture has to keep.
	$blob = ($Content | & git -C $Repository hash-object -w --stdin).Trim()
	if ([string]::IsNullOrWhiteSpace($blob)) { throw "Could not write the fixture blob for $RelativePath." }
	& git -C $Repository update-index --add --cacheinfo ("100644,$blob," + $RelativePath)
	if ($LASTEXITCODE -ne 0) { throw "Could not add $RelativePath to the fixture index." }
}

function Commit-FixtureIndex([string]$Repository, [string]$Message) {
	& git -C $Repository -c user.name='fixture' -c user.email='fixture@example.invalid' commit --quiet -m $Message
	if ($LASTEXITCODE -ne 0) { throw "Could not commit '$Message' in the fixture." }
}

function Invoke-NulArgumentListing([string]$Repository) {
	# Reads `git ls-files -z` as NUL-separated records, independently of the
	# auditor, so the fixture can show that a line-based read loses the path.
	$psi = New-Object System.Diagnostics.ProcessStartInfo
	$psi.FileName = 'git'
	$psi.Arguments = '-C "' + $Repository + '" ls-files -z'
	$psi.RedirectStandardOutput = $true
	$psi.RedirectStandardError = $true
	$psi.UseShellExecute = $false
	$psi.CreateNoWindow = $true
	$psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
	$process = [System.Diagnostics.Process]::Start($psi)
	$stdout = $process.StandardOutput.ReadToEnd()
	[void]$process.StandardError.ReadToEnd()
	$process.WaitForExit()
	$process.Dispose()
	if ($stdout.Length -eq 0) { return @() }
	return @($stdout -split ([string][char]0) | Where-Object { $_ -ne '' })
}

function Invoke-Audit([string]$Repository) {
	# The auditor signals its verdict with the process exit code, so the
	# caller reads `$LASTEXITCODE` right after this call. It is invoked with
	# `&` (not dot-sourced), so its `exit` ends the auditor only.
	$lines = @(& $auditor -RepoRoot $Repository)
	return @{ ExitCode = $LASTEXITCODE; Lines = @($lines) }
}

function Invoke-AuditScript([string]$ScriptPath, [string]$Repository) {
	$lines = @(& $ScriptPath -RepoRoot $Repository)
	return @{ ExitCode = $LASTEXITCODE; Lines = @($lines) }
}

function Get-AuditLine([hashtable]$Result, [string]$Prefix) {
	# Report lines are written one entry per item, so a caller can assert on
	# the exact category/path pair instead of a substring of the whole report.
	return @($Result.Lines | Where-Object { $_.StartsWith($Prefix) })
}

function Assert-AuditFails([hashtable]$Result, [string[]]$ExpectedLines, [string]$Message) {
	Assert-True ($Result.ExitCode -eq 1) "$Message (exit code should be 1, got $($Result.ExitCode))"
	foreach ($expected in $ExpectedLines) {
		Assert-True ((Get-AuditLine $Result $expected).Count -eq 1) "$Message (expected exactly one report line starting '$expected'; report: $($Result.Lines -join ' / '))"
	}
}

function Get-FixtureResidue {
	$violations = New-Object System.Collections.Generic.List[string]
	$pattern = '^(?:\.publish-surface-test-[0-9a-f]{32}|publish-surface-probe-[0-9a-f]{32})$'
	foreach ($entry in @(Get-ChildItem -LiteralPath $productionRoot -Force)) {
		if ($entry.Name -ceq 'PLACEHOLDER.md') { continue }
		if ($entry.Name -cnotmatch $pattern) { continue }
		if ($entry.Name -ceq [System.IO.Path]::GetFileName($fixtureRoot)) { continue }
		$violations.Add("Production/$($entry.Name): leftover fixture from an earlier interrupted run")
	}
	return $violations.ToArray()
}

$suiteError = $null
try {
	# ============================================== group 1: clean repository passes
	$clean = New-FixtureRepo 'clean'
	$cleanAudit = Invoke-Audit $clean
	Assert-Eq ([string]$cleanAudit.ExitCode) '0' 'a repository with no forbidden tracked path passes'
	Assert-True (@(Get-AuditLine $cleanAudit 'FAIL: ').Count -eq 0) "the clean fixture reports no FAIL line: $($cleanAudit.Lines -join ' / ')"
	Assert-True (@(Get-AuditLine $cleanAudit 'WARN: ').Count -eq 0) "the clean fixture reports no WARN line: $($cleanAudit.Lines -join ' / ')"
	Assert-True (@($cleanAudit.Lines | Where-Object { $_ -like 'SUMMARY: tracked=*' }).Count -eq 1) 'the report ends with one machine-readable summary line'
	Write-Output 'PASS: a repository whose index contains only the placeholder, docs and scripts passes with exit 0 and no false positive'

	# ====================== group 2: `git status` / `check-ignore` / path grep all pass, the audit fails
	# This is the false-pass trio the audit exists to close: three committed
	# forbidden files (offline bundle, executable helper, archive) that the
	# README itself names as normal offline-handoff artifacts.
	$binary = New-FixtureRepo 'committed-binaries'
	Add-FixturePath $binary 'ue5-agent-template.bundle' 'fixture bundle'
	Add-FixturePath $binary 'Tools/helper.exe' 'fixture exe'
	Add-FixturePath $binary 'backup.7z' 'fixture archive'
	Commit-Fixture $binary 'offline handoff artifacts'
	$binaryStatus = @(& git -C $binary status --porcelain --untracked-files=all)
	Assert-True (($binaryStatus -join '') -eq '') 'the naive `git status --porcelain --untracked-files=all` check is clean for these committed files'
	foreach ($relative in @('ue5-agent-template.bundle', 'Tools/helper.exe', 'backup.7z')) {
		& git -C $binary check-ignore -q $relative
		Assert-True ($LASTEXITCODE -ne 0) "the naive `git check-ignore` check reports '$relative' as not ignored, which reads as a deliberate document"
	}
	$productionGrep = @(& git -C $binary ls-files | Where-Object { $_ -match '^(Production|Out)/' })
	# The only line this naive check can see is the legitimate placeholder: the
	# bundle, the helper and the archive never appear in a Production/ or Out/
	# path, so the check reads as "Production/ is clean" and passes.
	Assert-True ($productionGrep.Count -eq 1 -and $productionGrep[0] -ceq 'Production/PLACEHOLDER.md') "the naive Production/Out path grep finds only the legitimate placeholder, got: $($productionGrep -join ' / ')"
	$binaryAudit = Invoke-Audit $binary
	Assert-AuditFails $binaryAudit @(
		'FAIL: distribution-binary: ue5-agent-template.bundle',
		'FAIL: distribution-binary: Tools/helper.exe',
		'FAIL: distribution-binary: backup.7z'
	) 'the audit reports every committed binary'
	Write-Output 'PASS: three committed binaries pass the git status, check-ignore and Production-grep checks while the audit exits 1 naming all three'

	# =======
	# group 3: a force-added credential that is later deleted from the worktree looks like "just a deletion"
	$credential = New-FixtureRepo 'forced-credential'
	Add-FixturePath $credential 'auth.json' '{"token":"redacted"}'
	& git -C $credential add --force auth.json
	& git -C $credential -c user.name='fixture' -c user.email='fixture@example.invalid' commit --quiet -m 'forced credential'
	if ($LASTEXITCODE -ne 0) { throw 'Could not commit the forced credential fixture.' }
	Remove-Item -LiteralPath (Join-Path $credential 'auth.json') -Force
	$credentialStatus = @(& git -C $credential status --short --untracked-files=all)
	$credentialStatusText = ($credentialStatus -join ' ')
	Assert-True ($credentialStatus.Count -eq 1 -and $credentialStatusText -match '^\s*D auth\.json$') "the worktree deletion looks like a plain deletion: $credentialStatusText"
	& git -C $credential check-ignore -q auth.json
	Assert-True ($LASTEXITCODE -ne 0) '.gitignore lists auth.json, yet `git check-ignore` reports the tracked path as not ignored, so the naive reading is "not a secret-shaped path"'
	& git -C $credential check-ignore -q --no-index auth.json
	Assert-True ($LASTEXITCODE -eq 0) 'auth.json does match the ignore pattern once the tracked-file blind spot is removed with --no-index, which is what makes the false pass a reading problem'
	$stillTracked = @(& git -C $credential ls-files | Where-Object { $_ -eq 'auth.json' })
	Assert-True ($stillTracked.Count -eq 1) 'auth.json is still in the index, so a fresh clone would publish it'
	$credentialAudit = Invoke-Audit $credential
	Assert-AuditFails $credentialAudit @(
		'FAIL: credential: auth.json',
		'FAIL: tracked-ignored: auth.json'
	) 'the audit reports the forced credential through both detection paths'
	Write-Output 'PASS: a force-added auth.json removed from the worktree passes status and check-ignore while the audit exits 1 through the credential rule and `ls-files -ci`'

	# ================================= group 4: generated projects and Out/ are reported, the placeholder is not
	$generated = New-FixtureRepo 'generated-output'
	Add-FixturePath $generated 'Production/EmberWatch_01a19290-18dc-7bcc-ba2d-f647ec88dcf3/TP_FirstPerson.uproject' '{"FileVersion":3}'
	Add-FixturePath $generated 'Out/run_01a19290/final/shot.mp4' 'fixture'
	# Force-add: that is exactly how a generated project or an output tree ends up
	# committed even though `.gitignore` lists it.
	Commit-Fixture $generated 'generated project' -Force
	$generatedAudit = Invoke-Audit $generated
	Assert-AuditFails $generatedAudit @(
		'FAIL: generation-output: Production/EmberWatch_01a19290-18dc-7bcc-ba2d-f647ec88dcf3/TP_FirstPerson.uproject',
		'FAIL: generation-output: Out/run_01a19290/final/shot.mp4'
	) 'the audit reports a committed generated project and Out/ output'
	Assert-True (@(Get-AuditLine $generatedAudit 'FAIL: generation-output: Production/PLACEHOLDER.md').Count -eq 0) 'the tracked Production/PLACEHOLDER.md is not reported'
	Assert-True (@(Get-AuditLine $generatedAudit 'FAIL: placeholder:').Count -eq 0) 'the tracked Production/PLACEHOLDER.md satisfies the placeholder check'
	Write-Output 'PASS: a committed Production/<Name>_<runid>/ and Out/ tree fail the audit while Production/PLACEHOLDER.md stays allowed'

	# ============================ group 5: a path containing a line feed survives the -z record path
	$newline = New-FixtureRepo 'newline-path'
	# `Prod` + LF + `uction/secret.bundle`: without -z a line-based read would
	# see two fragments and neither would match the extension rule.
	$newlineName = 'Prod' + [char]0x0A + 'uction/secret.bundle'
	Add-FixtureIndexPath $newline $newlineName 'fixture'
	# The index entry has no worktree file, so `git add -A` would drop it again;
	# commit the staged index directly.
	Commit-FixtureIndex $newline 'line feed path'
	$plainListing = @(& git -C $newline ls-files)
	Assert-True (@($plainListing | Where-Object { $_ -ceq $newlineName }).Count -eq 0) 'plain `git ls-files` does not return the line-feed path as one intact record'
	$nulListing = @(Invoke-NulArgumentListing $newline)
	Assert-True (@($nulListing | Where-Object { $_ -ceq $newlineName }).Count -eq 1) '`git ls-files -z` returns the line-feed path as one intact record'
	$newlineAudit = Invoke-Audit $newline
	Assert-AuditFails $newlineAudit @('FAIL: distribution-binary: Prod\nuction/secret.bundle') 'the audit reports the line-feed path with the escape made visible'
	Assert-True (@(Get-AuditLine $newlineAudit '' | Where-Object { $_.Contains([string][char]0x0A) }).Count -eq 0) 'the report keeps every entry on one line, so the line feed never splits a record'
	Write-Output 'PASS: a tracked path whose name contains a line feed is reported as one record, and plain `git ls-files` cannot represent it'

	# ======================= group 6: the verdict does not depend on core.ignorecase / `.gitignore`
	$caseSensitive = New-FixtureRepo 'case-independence'
	foreach ($relative in @('OUT/x.txt', 'SAVED/a', 'ART/a', 'PRODUCTION/Proj/TP.uproject')) {
		# Index spelling, not worktree spelling: a case-insensitive checkout
		# would otherwise normalise the directory name back to `Production`.
		Add-FixtureIndexPath $caseSensitive $relative 'fixture'
	}
	Commit-FixtureIndex $caseSensitive 'upper-case generated directories'
	& git -C $caseSensitive config core.ignorecase true
	$foldedAudit = Invoke-Audit $caseSensitive
	Assert-AuditFails $foldedAudit @(
		'FAIL: generation-output: OUT/x.txt',
		'FAIL: generation-output: SAVED/a',
		'FAIL: generation-output: ART/a',
		'FAIL: generation-output: PRODUCTION/Proj/TP.uproject'
	) 'the audit reports upper-case generated directories on a case-insensitive host'
	Assert-Eq ([string](@(Get-AuditLine $foldedAudit 'FAIL: tracked-ignored:').Count)) '4' 'the ignore-pattern cross-check also reports them on this host'
	& git -C $caseSensitive config core.ignorecase false
	# Same repository, same index, a case-sensitive matching model: this is
	# what a Linux runner sees.
	$exactAudit = Invoke-Audit $caseSensitive
	Assert-AuditFails $exactAudit @(
		'FAIL: generation-output: OUT/x.txt',
		'FAIL: generation-output: SAVED/a',
		'FAIL: generation-output: ART/a',
		'FAIL: generation-output: PRODUCTION/Proj/TP.uproject'
	) 'the audit reports the same four paths when the working tree is matched case-sensitively'
	Assert-Eq ([string](@(Get-AuditLine $exactAudit 'FAIL: tracked-ignored:').Count)) '0' 'the ignore-pattern cross-check finds nothing under core.ignorecase=false, which is why it cannot decide the verdict'
	Write-Output 'PASS: OUT/, SAVED/, ART/ and PRODUCTION/ fail on both case-insensitive and case-sensitive matching, while the `.gitignore` cross-check changes from 4 hits to 0'

	# ======================= group 7: the fresh-clone link check catches links the checkout cannot resolve
	$links = New-FixtureRepo 'links'
	$linkLines = @(
		'# Broken links',
		'',
		'- [gone](03-absent.md)',
		'- [wrong case](05-QA.md)',
		'- [escapes](../docs/01-start.md/../../../../etc/passwd)',
		'- [empty directory](nothing/)',
		'- [ok](01-start.md)',
		'- [external](https://example.invalid/x)'
	)
	Write-FixtureText (Join-Path $links 'docs\02-missing.md') ($linkLines -join "`n")
	Add-FixturePath $links 'docs/05-qa.md' 'present with a different case than the link'
	Commit-Fixture $links 'broken links'
	$linkAudit = Invoke-Audit $links
	Assert-AuditFails $linkAudit @(
		'FAIL: link: docs/02-missing.md:3 -> 03-absent.md (not tracked)',
		'FAIL: link: docs/02-missing.md:4 -> 05-QA.md (tracked only under a different letter case)',
		'FAIL: link: docs/02-missing.md:6 -> nothing/ (directory has no tracked entry)'
	) 'the audit reports missing, wrongly-cased and empty-directory links'
	Assert-True (($linkAudit.Lines -join ' ').Contains('escapes the repository root')) 'the audit reports a link that escapes the repository root'
	Assert-True (@(Get-AuditLine $linkAudit 'FAIL: link: docs/02-missing.md:7 -> 01-start.md').Count -eq 0) 'a link to a tracked sibling is not reported'
	Assert-True (@(Get-AuditLine $linkAudit 'FAIL: link: docs/02-missing.md:8').Count -eq 0) 'an external URL is not reported'
	Write-Output 'PASS: missing, wrongly-cased, escaping and empty-directory links fail the audit; resolvable and external links do not'

	# ============================ group 8: an untracked artifact warns, it does not fail the audit
	$untracked = New-FixtureRepo 'untracked-artifact'
	Add-FixturePath $untracked 'Tools/helper.exe' 'fixture exe'
	$untrackedAudit = Invoke-Audit $untracked
	Assert-Eq ([string]$untrackedAudit.ExitCode) '0' 'an untracked artifact is a warning, not a verdict'
	Assert-True (@(Get-AuditLine $untrackedAudit 'WARN: untracked-distribution-binary: Tools/helper.exe').Count -eq 1) 'the audit warns about the artifact that `git add -A` would publish'
	Assert-True (@(Get-AuditLine $untrackedAudit 'FAIL: ').Count -eq 0) 'the untracked artifact is not reported as a failure'
	Write-Output 'PASS: an untracked artifact is reported as a WARN while the exit code stays 0'

	# ============================ group 9: the tracked placeholder is required for a fresh clone
	$noPlaceholder = New-FixtureRepo 'no-placeholder'
	& git -C $noPlaceholder rm --quiet Production/PLACEHOLDER.md
	Commit-Fixture $noPlaceholder 'drop placeholder'
	$noPlaceholderAudit = Invoke-Audit $noPlaceholder
	Assert-AuditFails $noPlaceholderAudit @('FAIL: placeholder: Production/PLACEHOLDER.md is not tracked, so a fresh clone loses Production/') 'the audit requires the tracked placeholder'
	Write-Output 'PASS: a repository without the tracked Production/PLACEHOLDER.md fails the audit'

	# ============================ group 10: removing a rule turns the group 2 fixture green
	# A suite that no longer asserted on the rule would keep passing after the rule
	# was deleted. Copy the auditor, disable the distribution-binary pattern, and
	# check that the fixture which group 2 failed now passes: that proves the earlier
	# FAIL came from the rule and not from some unrelated line.
	$mutantPath = Join-Path $fixtureRoot 'mutant-auditor.ps1'
	$auditorSource = [System.IO.File]::ReadAllText($auditor)
	$binaryRule = "Pattern = '(?:\.(?:zip|bundle|7z|rar|tar|gz|tgz|bz2|xz|exe|dll|pdb|lib|so|dylib|uasset|umap|pak|utoc|ucas|mp4|mov|wav|mp3|fbx|psd))$'"
	Assert-True ($auditorSource.Contains($binaryRule)) 'the auditor still declares the distribution-binary rule this group mutates'
	$mutantSource = $auditorSource.Replace($binaryRule, "Pattern = '(?:NEVER-MATCHES-ANYTHING)$'")
	Assert-True ($mutantSource -cne $auditorSource) 'the mutant auditor actually differs from the auditor'
	Write-FixtureText $mutantPath $mutantSource
	$mutantAudit = Invoke-AuditScript $mutantPath $binary
	Assert-Eq ([string]$mutantAudit.ExitCode) '0' 'with the distribution-binary rule removed the committed-binary fixture passes, so the FAIL above depends on that rule'
	Write-Output 'PASS: deleting the distribution-binary rule makes the committed-binary fixture pass, so the assertion is not a tautology'

	# ============================ group 11: the auditor is not run-scoped to the fixture root
	# The repository under review is the checkout that holds this suite. Auditing
	# it must pass, so the gate can be used verbatim in docs/06-delivery.md.
	$selfAudit = Invoke-Audit $repoRoot
	Assert-Eq ([string]$selfAudit.ExitCode) '0' "the template repository passes its own publish-surface audit: $($selfAudit.Lines -join ' / ')"
	Assert-True (@(Get-AuditLine $selfAudit 'FAIL: ').Count -eq 0) 'the template repository reports no FAIL line'
	Write-Output 'PASS: the audit passes on this repository, so the documented command is the one the docs quote'

	# ============================ group 12: the suite leaves the developer checkout untouched
	$finalCheckoutStatus = @(& git -C $repoRoot status --porcelain --untracked-files=all)
	if ($LASTEXITCODE -ne 0) { throw 'Could not verify the developer checkout status after testing.' }
	Assert-True (($finalCheckoutStatus -join "`n") -ceq ($initialCheckoutStatus -join "`n")) 'the suite leaves the developer checkout unchanged'
	Write-Output 'PASS: `git status --porcelain --untracked-files=all` on the developer checkout is identical before and after the suite'
} catch {
	# `$_` is not the in-flight error inside a bare `finally`; capture it here so
	# a cleanup failure cannot hide the original assertion.
	$suiteError = $_
} finally {
	if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
		Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
	}
	$cleanupProblems = @(Get-FixtureResidue | ForEach-Object { "Production/ residual entry after cleanup: $_" })
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
	if ($null -ne $suiteError) { throw $suiteError }
}
