[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$productionRoot = Join-Path $repoRoot 'Production'
$guard = Join-Path $PSScriptRoot 'Test-UETemplateProvenance.ps1'
$inventoryPath = 'docs/PROVENANCE.inventory.json'
$initialCheckoutStatus = @(& git -C $repoRoot status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0) { throw 'Could not record the developer checkout status before testing.' }

$testId = [Guid]::NewGuid().ToString('N')
$fixtureRoot = Join-Path $productionRoot ('.provenance-test-' + $testId)
$gitIdentity = @('-c', 'user.name=Provenance Suite', '-c', 'user.email=provenance-suite@example.invalid', '-c', 'commit.gpgsign=false')

function Assert-True([bool]$Condition, [string]$Message) {
	if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Write-TextFile([string]$Path, [string]$Text) {
	$parent = Split-Path -Parent $Path
	[System.IO.Directory]::CreateDirectory($parent) | Out-Null
	[System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-Git([string[]]$Arguments) {
	& git @gitIdentity @Arguments 2>&1 | Out-Null
}

function New-FixtureRepo([string]$Name) {
	# A disposable repository per case: the guard is checked against a tree this suite controls, so
	# the negative cases never depend on, or disturb, the developer checkout.
	$path = Join-Path $fixtureRoot $Name
	[System.IO.Directory]::CreateDirectory($path) | Out-Null
	Invoke-Git @('-C', $path, 'init', '--quiet')
	Write-TextFile (Join-Path $path 'README.md') "# Fixture$([Environment]::NewLine)"
	Write-TextFile (Join-Path $path 'AGENTS.md') "# Fixture agent contract$([Environment]::NewLine)"
	Write-TextFile (Join-Path $path 'docs\01-start.md') "# Start$([Environment]::NewLine)"
	Write-TextFile (Join-Path $path 'scripts\New-UETemplateScaffold.ps1') "# fixture generator placeholder$([Environment]::NewLine)"
	Write-TextFile (Join-Path $path 'scripts\Test-UETemplateProvenance.ps1') ([System.IO.File]::ReadAllText($guard))
	Write-TextFile (Join-Path $path 'templates\QA.md') "# QA$([Environment]::NewLine)"
	[System.IO.Directory]::CreateDirectory((Join-Path $path 'Production')) | Out-Null
	Write-TextFile (Join-Path $path 'Production\PLACEHOLDER.md') "# placeholder$([Environment]::NewLine)"
	Write-TextFile (Join-Path $path 'docs\PROVENANCE.md') (@(
		'# Provenance',
		'',
		'[README](../README.md) and [start](01-start.md) are tracked. An [external reference](https://dev.epicgames.com/documentation/en-us/unreal-engine) is not checked.'
	) -join [Environment]::NewLine)
	Write-TextFile (Join-Path $path $inventoryPath) (@(
		'{',
		'  "schema_version": 1,',
		'  "source_document": "docs/PROVENANCE.md",',
		'  "bundled": [',
		'    "AGENTS.md",',
		'    "README.md",',
		'    "Production/PLACEHOLDER.md",',
		'    "docs/*",',
		'    "scripts/*",',
		'    "templates/*"',
		'  ],',
		'  "not_bundled": [',
		'    "Engine/*",',
		'    "Content/*",',
		'    "*.uasset"',
		'  ]',
		'}'
	) -join [Environment]::NewLine)
	Invoke-Git @('-C', $path, 'add', '--all')
	Invoke-Git @('-C', $path, 'commit', '--quiet', '-m', 'fixture')
	return $path
}

function Set-Inventory([string]$RepoPath, [string]$InventoryJson) {
	# Writes without staging: the cases below decide per case whether the inventory file is tracked.
	Write-TextFile (Join-Path $RepoPath $inventoryPath) $InventoryJson
}

function Get-Inventory([string]$RepoPath) {
	return [System.IO.File]::ReadAllText((Join-Path $RepoPath $inventoryPath))
}

function Invoke-Guard([string]$RepoPath) {
	$captured = New-Object System.Collections.Generic.List[string]
	$exitCode = $null
	try {
		& $guard -RepoRoot $RepoPath -InventoryPath $inventoryPath 2>&1 | ForEach-Object { $captured.Add([string]$_) }
		$exitCode = $LASTEXITCODE
	} catch {
		$captured.Add([string]$_.Exception.Message)
		$exitCode = -1
	}
	return [pscustomobject]@{
		ExitCode = $exitCode
		Output = ($captured -join "`n")
		Lines = @($captured | Where-Object { $_ -match '^FAIL: ' })
	}
}

function Assert-GuardFails([string]$RepoPath, [string]$Rule, [string]$DetailFragment, [string]$Message) {
	$result = Invoke-Guard $RepoPath
	Assert-True ($result.ExitCode -eq 1) ("$Message (exit code 1 expected, got $($result.ExitCode)): $($result.Output)")
	$match = @($result.Lines | Where-Object { $_ -match ('^FAIL: ' + [regex]::Escape($Rule) + ': ') -and $_.Contains($DetailFragment) })
	Assert-True ($match.Count -ge 1) ("$Message (no 'FAIL: ${Rule}: ...$DetailFragment' line): $($result.Output)")
	foreach ($line in $result.Lines) {
		# One finding per line, so a consumer can parse the verdict without ANSI/stack noise.
		Assert-True ($line -match '^FAIL: ([A-Za-z0-9]+): [^\r\n]+$') "every finding is a single 'FAIL: <rule>: <detail>' line: $line"
	}
	Assert-True ($result.Output -notmatch 'at line:|CategoryInfo') "$Message (no PowerShell stack leaked into the output)"
	foreach ($line in $result.Lines) { Write-Output "  $line" }
	return $result
}

function Assert-FixtureClean([string]$RepoPath, [string]$Message) {
	$status = @(& git -C $RepoPath status --porcelain --untracked-files=all)
	Assert-True ($LASTEXITCODE -eq 0) 'fixture checkout status is readable'
	Assert-True (($status -join '').Length -eq 0) "$Message (fixture checkout changed: $($status -join ' | '))"
}

function Get-ProductionResidue {
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
		if (-not $entry.Name.StartsWith('.provenance-test-', [System.StringComparison]::Ordinal)) { continue }
		$violations.Add("Production/$($entry.Name): unexpected entry (ignored by .gitignore, so git status does not report it)")
	}
	return $violations.ToArray()
}

$suiteError = $null
try {
	# ---------------------------------------------------------------- positive case
	$clean = New-FixtureRepo 'clean'
	$result = Invoke-Guard $clean
	Assert-True ($result.ExitCode -eq 0) "a classified tree with resolvable claims passes (exit code 0 expected, got $($result.ExitCode)): $($result.Output)"
	Assert-True ($result.Output -match 'PASS: R1') 'the passing run reports R1'
	Assert-True ($result.Output -match 'PASS: R4') 'the passing run reports R4'
	Assert-FixtureClean $clean 'the guard does not modify the checkout it inspects'
	Write-Output 'PASS: a tree whose claims match the tracked files passes without touching the checkout'

	# ---------------------------------------------------------------- R1: false "not bundled" claim
	$falseNotBundled = New-FixtureRepo 'false-not-bundled'
	Set-Inventory $falseNotBundled (@(
		'{',
		'  "schema_version": 1,',
		'  "source_document": "docs/PROVENANCE.md",',
		'  "bundled": ["AGENTS.md", "README.md", "Production/PLACEHOLDER.md", "docs/*", "templates/*"],',
		'  "not_bundled": ["scripts/*", "Engine/*", "*.uasset"]',
		'}'
	) -join [Environment]::NewLine)
	Invoke-Git @('-C', $falseNotBundled, 'add', '--all')
	Invoke-Git @('-C', $falseNotBundled, 'commit', '--quiet', '-m', 'claim a shipped directory is absent')
	Assert-GuardFails $falseNotBundled 'R1' 'scripts/New-UETemplateScaffold.ps1' 'a "script is not bundled" claim is rejected while scripts are tracked' | Out-Null
	Assert-FixtureClean $falseNotBundled 'the R1 run does not modify the checkout'
	Write-Output 'PASS: not_bundled claim that matches a tracked script is rejected with the path named'

	# ---------------------------------------------------------------- R1 with a path containing a space
	$spacedPath = New-FixtureRepo 'spaced-path'
	Write-TextFile (Join-Path $spacedPath 'docs\provenance notes and record.md') "# notes$([Environment]::NewLine)"
	Invoke-Git @('-C', $spacedPath, 'add', '--all')
	Invoke-Git @('-C', $spacedPath, 'commit', '--quiet', '-m', 'add a path containing spaces')
	Set-Inventory $spacedPath (@(
		'{',
		'  "schema_version": 1,',
		'  "source_document": "docs/PROVENANCE.md",',
		'  "bundled": ["AGENTS.md", "README.md", "Production/PLACEHOLDER.md", "docs/*", "scripts/*", "templates/*"],',
		'  "not_bundled": ["docs/provenance notes and record.md", "Engine/*", "*.uasset"]',
		'}'
	) -join [Environment]::NewLine)
	Invoke-Git @('-C', $spacedPath, 'add', '--all')
	Invoke-Git @('-C', $spacedPath, 'commit', '--quiet', '-m', 'claim a spaced path is absent')
	Assert-GuardFails $spacedPath 'R1' 'provenance notes and record.md' 'a tracked path containing spaces is matched as one path, not split into tokens' | Out-Null
	Write-Output 'PASS: a tracked path containing spaces is compared whole (git ls-files -z)'

	# ---------------------------------------------------------------- R2: dangling "bundled" claim
	$danglingBundled = New-FixtureRepo 'dangling-bundled'
	Set-Inventory $danglingBundled (@(
		'{',
		'  "schema_version": 1,',
		'  "source_document": "docs/PROVENANCE.md",',
		'  "bundled": ["AGENTS.md", "README.md", "Production/PLACEHOLDER.md", "scripts/*", "templates/*"],',
		'  "not_bundled": ["Engine/*", "Content/*", "*.uasset"]',
		'}'
	) -join [Environment]::NewLine)
	Invoke-Git @('-C', $danglingBundled, 'add', '--all')
	Invoke-Git @('-C', $danglingBundled, 'commit', '--quiet', '-m', 'drop docs from the classification')
	Assert-GuardFails $danglingBundled 'R3' 'docs' 'dropping docs/* from bundled while docs/ stays tracked is rejected' | Out-Null
	Write-Output 'PASS: dropping a bundled entry while its directory stays tracked is rejected (the area becomes unclassified)'

	# ---------------------------------------------------------------- R2: a bundled pattern that resolves to nothing
	$danglingPattern = New-FixtureRepo 'dangling-pattern'
	Set-Inventory $danglingPattern (@(
		'{',
		'  "schema_version": 1,',
		'  "source_document": "docs/PROVENANCE.md",',
		'  "bundled": ["AGENTS.md", "README.md", "Production/PLACEHOLDER.md", "docs/*", "scripts/*", "templates/*", "docs/09-missing.md"],',
		'  "not_bundled": ["Engine/*", "Content/*", "*.uasset"]',
		'}'
	) -join [Environment]::NewLine)
	Invoke-Git @('-C', $danglingPattern, 'add', '--all')
	Invoke-Git @('-C', $danglingPattern, 'commit', '--quiet', '-m', 'claim a file that was never committed is shipped')
	Assert-GuardFails $danglingPattern 'R2' 'docs/09-missing.md' 'a bundled entry naming a file the repository does not ship is rejected' | Out-Null
	Assert-FixtureClean $danglingPattern 'the R2 run does not modify the checkout'
	Write-Output 'PASS: a bundled entry that resolves to no tracked path is rejected with the pattern named'

	# ---------------------------------------------------------------- R3: unclassified new top-level area
	$unclassified = New-FixtureRepo 'unclassified'
	Write-TextFile (Join-Path $unclassified 'tools\run.ps1') "# new layer$([Environment]::NewLine)"
	Invoke-Git @('-C', $unclassified, 'add', '--all')
	Invoke-Git @('-C', $unclassified, 'commit', '--quiet', '-m', 'add tools/ without provenance')
	Assert-GuardFails $unclassified 'R3' 'tools' 'a new top-level directory added without an inventory entry is rejected' | Out-Null
	Assert-FixtureClean $unclassified 'the R3 run does not modify the checkout'
	Write-Output 'PASS: a new top-level area (tools/) that no inventory entry classifies is rejected'

	# ---------------------------------------------------------------- R4: dangling document link
	$danglingLink = New-FixtureRepo 'dangling-link'
	Set-Inventory $danglingLink (Get-Inventory $danglingLink)
	$provenancePath = Join-Path $danglingLink 'docs\PROVENANCE.md'
	Write-TextFile $provenancePath (@(
		'# Provenance',
		'',
		'[README](../README.md) is tracked.',
		'',
		'The clone and forbidden-file results are in [the verification record](verification-record.md).'
	) -join [Environment]::NewLine)
	Invoke-Git @('-C', $danglingLink, 'add', '--all')
	Invoke-Git @('-C', $danglingLink, 'commit', '--quiet', '-m', 'reference a record that was never committed')
	Assert-GuardFails $danglingLink 'R4' 'verification-record.md' 'a reference to a record the repository does not ship is rejected' | Out-Null
	Write-Output 'PASS: a relative document link that git does not track is rejected'

	# ---------------------------------------------------------------- inventory corpus problems
	$untrackedInventory = New-FixtureRepo 'untracked-inventory'
	[System.IO.File]::Delete((Join-Path $untrackedInventory $inventoryPath))
	Invoke-Git @('-C', $untrackedInventory, 'add', '--all')
	Invoke-Git @('-C', $untrackedInventory, 'commit', '--quiet', '-m', 'remove the inventory')
	Set-Inventory $untrackedInventory (Get-Inventory $clean)
	$untrackedResult = Invoke-Guard $untrackedInventory
	Assert-True ($untrackedResult.ExitCode -eq 1) "an inventory file that is not tracked fails with exit 1 (got $($untrackedResult.ExitCode)): $($untrackedResult.Output)"
	Assert-True (@($untrackedResult.Lines | Where-Object { $_ -match '^FAIL: inventory: ' -and $_.Contains($inventoryPath) }).Count -ge 1) 'the untracked inventory is named'
	Write-Output 'PASS: an untracked inventory is rejected instead of checking a file nobody ships'

	$brokenInventory = New-FixtureRepo 'broken-inventory'
	Set-Inventory $brokenInventory '{ "schema_version": 1, '
	Invoke-Git @('-C', $brokenInventory, 'add', '--all')
	Invoke-Git @('-C', $brokenInventory, 'commit', '--quiet', '-m', 'truncate the inventory')
	$brokenResult = Invoke-Guard $brokenInventory
	Assert-True ($brokenResult.ExitCode -eq 2) "an inventory that cannot be parsed fails as a guard error, not a tree violation (got $($brokenResult.ExitCode)): $($brokenResult.Output)"
	Assert-True (@($brokenResult.Lines | Where-Object { $_ -match '^FAIL: inventory: ' }).Count -ge 1) 'the unparsable inventory is named'
	Write-Output 'PASS: an unparsable inventory exits 2 so a broken guard is distinguishable from a failing tree'

	# ---------------------------------------------------------------- the real repository
	# The guard runs inside whatever checkout the suite was started from, which may legitimately be
	# mid-change (it is usually run before committing this change), so only the before/after delta
	# matters: the guard must not add or alter anything.
	$liveStatusBefore = @(& git -C $repoRoot status --porcelain --untracked-files=all)
	$live = Invoke-Guard $repoRoot
	Assert-True ($live.ExitCode -eq 0) "the repository's own PROVENANCE inventory matches its tracked tree (got $($live.ExitCode)): $($live.Output)"
	$liveStatusAfter = @(& git -C $repoRoot status --porcelain --untracked-files=all)
	Assert-True (($liveStatusAfter -join "`n") -ceq ($liveStatusBefore -join "`n")) 'the guard leaves the developer checkout unchanged'
	Write-Output 'PASS: the checked-out repository passes its own provenance guard'
	Write-Output 'PASS: every assertion group ran'
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
	if ($null -ne $suiteError) { throw $suiteError }
}
