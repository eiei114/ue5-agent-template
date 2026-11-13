[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$productionRoot = Join-Path $repoRoot 'Production'
$auditor = Join-Path $PSScriptRoot 'Measure-UECreditsInventory.ps1'
$creditsTemplate = Join-Path $repoRoot 'templates\CREDITS.md'
$initialCheckoutStatus = @(& git -C $repoRoot status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0) { throw 'Could not record the developer checkout status before testing.' }
$testId = [Guid]::NewGuid().ToString('N')
$fixtureRoot = Join-Path $productionRoot ('.credits-test-' + $testId)
$workPrefix = "Cr_$testId"
$workNames = @(
	"${workPrefix}_full",
	"${workPrefix}_empty",
	"${workPrefix}_named",
	"${workPrefix}_legacy",
	"${workPrefix}_nocredits",
	"${workPrefix}_ambig",
	"${workPrefix}_example"
)
$workPaths = @($workNames | ForEach-Object { Join-Path $productionRoot $_ })

function Assert-True([bool]$Condition, [string]$Message) {
	if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Write-FixtureText([string]$Path, [string]$Text) {
	$parent = Split-Path -Parent $Path
	[System.IO.Directory]::CreateDirectory($parent) | Out-Null
	[System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Add-AssetGroup([string]$ContentRoot, [string]$GroupName, [int]$Count) {
	# Self-made placeholder bytes: no engine .uasset/.umap is copied into the repository.
	for ($i = 0; $i -lt $Count; $i++) {
		$relative = if ($GroupName -eq '(content-root)') { 'Asset_{0:D5}.uasset' -f $i } else { '{0}/{0}_{1:D5}.uasset' -f $GroupName, $i }
		Write-FixtureText (Join-Path $ContentRoot $relative.Replace('/', '\')) ("fixture asset {0}" -f $i)
	}
}

function Add-AssetGroupMixed([string]$ContentRoot, [string]$GroupName, [int]$UmapCount) {
	for ($i = 0; $i -lt $UmapCount; $i++) {
		Write-FixtureText (Join-Path $ContentRoot ('{0}/{0}_{1:D5}.umap' -f $GroupName, $i)) ("fixture map {0}" -f $i)
	}
}

function Invoke-Auditor([string]$TargetPath) {
	# Same in-process invocation style as Test-UERenderArtifacts.ps1: capture the helper's
	# real exit code instead of a PowerShell return value.
	$captured = New-Object System.Collections.Generic.List[string]
	$exitCode = $null
	try {
		& $auditor -Target $TargetPath 2>&1 | ForEach-Object { $captured.Add([string]$_) }
		$exitCode = $LASTEXITCODE
	} catch {
		$captured.Add('THREW: ' + $_.Exception.Message)
		$exitCode = 3
	}
	return [pscustomobject]@{ ExitCode = $exitCode; Output = ($captured -join "`n") }
}

function New-Work([string]$Root, [string]$RunId) {
	# AGENTS.md layout: Content/ and the .uproject sit in the project root, CREDITS.md sits in
	# Out/run_<runid>/ one directory below.
	$deliveryDir = Join-Path (Join-Path $Root 'Out') ('run_' + $RunId)
	[System.IO.Directory]::CreateDirectory($deliveryDir) | Out-Null
	[System.IO.File]::WriteAllText((Join-Path $Root 'TP_ThirdPerson.uproject'), '{"FileVersion":3}', [System.Text.UTF8Encoding]::new($false))
	return $deliveryDir
}

function Get-ProductionResidue {
	# Production/* is gitignored, so `git status --untracked-files=all` cannot see leftovers.
	$violations = New-Object System.Collections.Generic.List[string]
	$allowed = @('PLACEHOLDER.md') + @([System.IO.Path]::GetFileName($fixtureRoot)) + @($workNames)
	$suiteOwnedPattern = '^(?:\.credits-test-[0-9a-f]{32}|Cr_[0-9a-f]{32}_.+)$'
	if (-not (Test-Path -LiteralPath $productionRoot -PathType Container)) {
		$violations.Add('Production/: the directory is missing')
		return $violations.ToArray()
	}
	if (-not (Test-Path -LiteralPath (Join-Path $productionRoot 'PLACEHOLDER.md') -PathType Leaf)) {
		$violations.Add('Production/PLACEHOLDER.md: the tracked placeholder is missing')
	}
	foreach ($entry in @(Get-ChildItem -LiteralPath $productionRoot -Force)) {
		if ($allowed -contains $entry.Name) { continue }
		if ($entry.Name -cnotmatch $suiteOwnedPattern) { continue }
		$violations.Add("Production/$($entry.Name): unexpected entry (ignored by .gitignore, so git status does not report it)")
	}
	return $violations.ToArray()
}

$suiteError = $null
try {
	$initialProductionResidue = @(Get-ProductionResidue)
	Assert-True ($initialProductionResidue.Count -eq 0) ("Production/ holds only the tracked placeholder before testing: " + ($initialProductionResidue -join '; '))
	[System.IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null

	# (a)(b)(c) The measured third-person-game shape: 587 template assets plus 128 + 9 + 29 from
	# the Characters / Input / LevelPrototyping shared content packs, shipped while the credits
	# template still only claims that nothing was used.
	$fullRoot = $workPaths[0]
	$fullContent = Join-Path $fullRoot 'Content'
	Add-AssetGroupMixed $fullContent 'ThirdPerson' 587
	Add-AssetGroup $fullContent 'Characters' 128
	Add-AssetGroup $fullContent 'Input' 9
	Add-AssetGroup $fullContent 'LevelPrototyping' 29
	$fullDelivery = New-Work $fullRoot 'a'
	Copy-Item -LiteralPath $creditsTemplate -Destination (Join-Path $fullDelivery 'CREDITS.md')

	$fullProjectAudit = Invoke-Auditor $fullRoot
	Assert-True ($fullProjectAudit.ExitCode -eq 1) 'placeholder CREDITS with 753 shipped assets fails when the project root is audited'
	Assert-True ($fullProjectAudit.Output -match 'states no origin') 'the failure says the credits state no origin'
	Assert-True ($fullProjectAudit.Output -match 'assets total=753') 'the audit counts every shipped asset in Content/'
	Write-Output 'PASS: 753 assets + placeholder CREDITS fails from the project root (case a)'

	$fullDeliveryAudit = Invoke-Auditor $fullDelivery
	Assert-True ($fullDeliveryAudit.ExitCode -eq 1) 'auditing the delivery directory must not report a 0-asset PASS for a work that ships 753 assets'
	Assert-True ($fullDeliveryAudit.Output -match 'assets total=753') 'the delivery-directory audit resolves the Content/ one level above'
	Assert-True ($fullDeliveryAudit.ExitCode -eq $fullProjectAudit.ExitCode -and $fullDeliveryAudit.Output -eq $fullProjectAudit.Output) 'the delivery directory and the project root reach the same conclusion'
	Write-Output 'PASS: the same work fails from the delivery directory instead of passing with 0 assets (case b)'

	$noCreditsRoot = $workPaths[4]
	Add-AssetGroup (Join-Path $noCreditsRoot 'Content') 'ThirdPerson' 3
	New-Work $noCreditsRoot 'b' | Out-Null
	$noCreditsAudit = Invoke-Auditor $noCreditsRoot
	Assert-True ($noCreditsAudit.ExitCode -eq 2) 'a work with assets but no CREDITS.md is an input defect, not a pass'
	Assert-True ($noCreditsAudit.Output -match 'CREDITS\.md not found') 'the missing-credits failure says what is missing'
	Assert-True ($noCreditsAudit.ExitCode -ne 0) 'a missing CREDITS.md never reports a pass (case c)'
	Write-Output 'PASS: a missing CREDITS.md is a non-passing input defect (case c)'

	# (d) vertical-loop shape: the generated project has no Content/ at all.
	$emptyRoot = $workPaths[1]
	$emptyDelivery = New-Work $emptyRoot 'c'
	Copy-Item -LiteralPath $creditsTemplate -Destination (Join-Path $emptyDelivery 'CREDITS.md')
	[System.IO.File]::WriteAllText((Join-Path $emptyRoot 'TP_BlankBP.uproject'), '{"FileVersion":3}', [System.Text.UTF8Encoding]::new($false))
	$emptyProjectAudit = Invoke-Auditor $emptyRoot
	$emptyDeliveryAudit = Invoke-Auditor $emptyDelivery
	Assert-True ($emptyProjectAudit.ExitCode -eq 0) 'a work that ships no assets passes with the untouched credits placeholder'
	Assert-True ($emptyDeliveryAudit.ExitCode -eq 0) 'the empty work also passes from its delivery directory'
	Assert-True ($emptyProjectAudit.Output -match 'assets total=0') 'the empty work is reported as 0 assets'
	Assert-True ($emptyDeliveryAudit.ExitCode -eq $emptyProjectAudit.ExitCode) 'the empty work reaches the same conclusion from both targets (case d)'
	Write-Output 'PASS: a work with no Content/ still passes (no false positive, case d)'

	# (e) A credits record that names every shipped group with a stated origin passes.
	$namedRoot = $workPaths[2]
	$namedContent = Join-Path $namedRoot 'Content'
	Add-AssetGroupMixed $namedContent 'ThirdPerson' 40
	Add-AssetGroupMixed $namedContent 'Variant_Combat' 7
	Add-AssetGroup $namedContent 'Characters' 12
	Add-AssetGroup $namedContent 'Input' 3
	Add-AssetGroup $namedContent 'LevelPrototyping' 5
	$namedDelivery = New-Work $namedRoot 'd'
	$namedCredits = @(
		'# CREDITS (recording a source is not a permission)',
		'',
		'| Asset | origin | bundle | Author | Source URL | license/date | price/credit | used | changed | scope | project path |',
		'|---|---|---|---|---|---|---|---|---|---|---|',
		'| TP_ThirdPerson template content | engine-template | generated-only | Epic Games | unknown | unknown | 0 | used | none | unknown | Content/ThirdPerson, Content/Variant_Combat |',
		'| Characters pack | shared-content-pack | generated-only | Epic Games | unknown | unknown | 0 | used | none | unknown | Content/Characters |',
		'| Input pack | shared-content-pack | generated-only | Epic Games | unknown | unknown | 0 | used | none | unknown | Content/Input |',
		'| LevelPrototyping pack | shared-content-pack | generated-only | Epic Games | unknown | unknown | 0 | used | none | unknown | Content/LevelPrototyping |'
	) -join "`n"
	[System.IO.File]::WriteAllText((Join-Path $namedDelivery 'CREDITS.md'), $namedCredits, [System.Text.UTF8Encoding]::new($false))
	$namedProjectAudit = Invoke-Auditor $namedRoot
	$namedDeliveryAudit = Invoke-Auditor $namedDelivery
	Assert-True ($namedProjectAudit.ExitCode -eq 0) 'a credits record naming every shipped group passes from the project root'
	Assert-True ($namedDeliveryAudit.ExitCode -eq 0) 'the same credits record also passes from the delivery directory'
	Assert-True ($namedDeliveryAudit.Output -eq $namedProjectAudit.Output) 'the compliant work reaches the same conclusion from both targets (case e)'
	Assert-True ($namedDeliveryAudit.Output -match 'stated_origin_rows=4') 'the audit counts the rows that state an origin'
	Write-Output 'PASS: a credits record that names every shipped group passes (case e)'

	# The worked example that templates/CREDITS.md ships has to pass on the measured
	# third-person-game shape by itself. World partition adds __ExternalActors__ and
	# __ExternalObjects__ as their own top-level Content groups, so an example that only lists
	# the template and pack directories documents an incomplete record.
	$exampleRoot = $workPaths[6]
	$exampleContent = Join-Path $exampleRoot 'Content'
	Add-AssetGroupMixed $exampleContent 'ThirdPerson' 5
	Add-AssetGroupMixed $exampleContent 'Variant_Combat' 31
	Add-AssetGroupMixed $exampleContent 'Variant_Platforming' 11
	Add-AssetGroupMixed $exampleContent 'Variant_SideScrolling' 19
	Add-AssetGroup $exampleContent 'Characters' 128
	Add-AssetGroup $exampleContent 'Input' 9
	Add-AssetGroup $exampleContent 'LevelPrototyping' 29
	Add-AssetGroup $exampleContent '__ExternalActors__' 479
	Add-AssetGroup $exampleContent '__ExternalObjects__' 42
	$exampleDelivery = New-Work $exampleRoot 'f'
	$fencedLines = New-Object System.Collections.Generic.List[string]
	$inFence = $false
	foreach ($line in [System.IO.File]::ReadAllLines($creditsTemplate)) {
		$trimmed = $line.Trim()
		if (-not $inFence) {
			if ($trimmed -eq '```markdown') { $inFence = $true }
			continue
		}
		if ($trimmed.StartsWith('```')) { break }
		$fencedLines.Add($line)
	}
	Assert-True ($fencedLines.Count -gt 0) 'templates/CREDITS.md carries a fenced worked example'
	[System.IO.File]::WriteAllText((Join-Path $exampleDelivery 'CREDITS.md'), ($fencedLines -join "`n"), [System.Text.UTF8Encoding]::new($false))
	$exampleProjectAudit = Invoke-Auditor $exampleRoot
	$exampleDeliveryAudit = Invoke-Auditor $exampleDelivery
	Assert-True ($exampleProjectAudit.ExitCode -eq 0) 'the worked example in templates/CREDITS.md passes on the measured third-person shape'
	Assert-True ($exampleDeliveryAudit.ExitCode -eq 0) 'the worked example also passes from the delivery directory'
	Assert-True ($exampleProjectAudit.Output -match 'assets total=753') 'the worked example covers all 753 measured assets'
	Assert-True ($exampleProjectAudit.Output -match 'groups=9') 'the worked example covers the 9 measured groups'
	Assert-True ($exampleDeliveryAudit.Output -eq $exampleProjectAudit.Output) 'the worked example reaches the same conclusion from both targets'
	Write-Output 'PASS: the worked example shipped in templates/CREDITS.md passes on the measured third-person shape'

	# A record that names the template group but omits one shared content pack still fails, so a
	# partially filled table cannot cover the shipped Content/.
	$partialDelivery = New-Work (Join-Path $fixtureRoot 'PartialWork') 'partial'
	$partialContent = Join-Path (Join-Path $fixtureRoot 'PartialWork') 'Content'
	Add-AssetGroupMixed $partialContent 'ThirdPerson' 3
	Add-AssetGroup $partialContent 'Input' 2
	$partialCredits = @(
		'| Asset | origin | bundle | project path |',
		'|---|---|---|---|',
		'| TP_ThirdPerson template content | engine-template | generated-only | Content/ThirdPerson |'
	) -join "`n"
	[System.IO.File]::WriteAllText((Join-Path $partialDelivery 'CREDITS.md'), $partialCredits, [System.Text.UTF8Encoding]::new($false))
	$partialAudit = Invoke-Auditor (Join-Path $fixtureRoot 'PartialWork')
	Assert-True ($partialAudit.ExitCode -eq 1) 'a credits record that omits one shipped content group fails'
	Assert-True ($partialAudit.Output -match 'Content group "Input"') 'the omission is reported by group name'
	Write-Output 'PASS: a partial credits record fails on the group it omits'

	# Legacy record: the previous 9-column table has no origin column, so it cannot explain
	# engine-shipped content even when an author filled in every cell.
	$legacyRoot = $workPaths[3]
	Add-AssetGroupMixed (Join-Path $legacyRoot 'Content') 'ThirdPerson' 6
	$legacyDelivery = New-Work $legacyRoot 'e'
	$legacyCredits = @(
		'| Asset | Author | Source URL | license/date | price/credit | used | changed | scope | project path |',
		'|---|---|---|---|---|---|---|---|---|',
		'| ThirdPerson template content | Epic Games | unknown | unknown | 0 | used | none | unknown | Content/ThirdPerson |'
	) -join "`n"
	[System.IO.File]::WriteAllText((Join-Path $legacyDelivery 'CREDITS.md'), $legacyCredits, [System.Text.UTF8Encoding]::new($false))
	$legacyAudit = Invoke-Auditor $legacyRoot
	Assert-True ($legacyAudit.ExitCode -eq 1) 'a legacy 9-column credits table cannot explain engine-shipped content'
	Assert-True ($legacyAudit.Output -match 'states no origin') 'the legacy failure says the origin is missing'
	Write-Output 'PASS: a legacy credits table without the origin column cannot pass'

	# Ambiguous input: two Content/ directories are reachable, so the auditor must refuse to guess.
	$ambigRoot = $workPaths[5]
	Add-AssetGroup (Join-Path $ambigRoot 'Content') 'ThirdPerson' 1
	Add-AssetGroup (Join-Path $ambigRoot 'Delivery\Content') 'ThirdPerson' 1
	Copy-Item -LiteralPath $creditsTemplate -Destination (Join-Path $ambigRoot 'CREDITS.md')
	$missingAudit = Invoke-Auditor (Join-Path $ambigRoot 'CREDITS.md')
	Assert-True ($missingAudit.ExitCode -eq 2) 'a missing audit target is an input defect'
	$ambigDirAudit = Invoke-Auditor (Join-Path $ambigRoot 'Delivery')
	Assert-True ($ambigDirAudit.ExitCode -eq 2) 'two reachable Content/ directories are an input defect, not a pass'
	Assert-True ($ambigDirAudit.Output -match 'more than one Content/') 'the ambiguous-input failure says what is ambiguous'
	Write-Output 'PASS: ambiguous or missing audit inputs exit 2 instead of passing'
} catch {
	$suiteError = $_
} finally {
	foreach ($path in $workPaths) {
		if (Test-Path -LiteralPath $path -PathType Container) { Remove-Item -LiteralPath $path -Recurse -Force }
	}
	if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
		Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
	}
	$cleanupProblems = @(Get-ProductionResidue | ForEach-Object { "Production/ residual entry after cleanup: $_" })
	if (Test-Path -LiteralPath $fixtureRoot) { $cleanupProblems += "fixture root still exists: $fixtureRoot" }
	$finalCheckoutStatus = @(& git -C $repoRoot status --porcelain --untracked-files=all)
	if ($LASTEXITCODE -ne 0) { throw 'Could not verify the developer checkout status after testing.' }
	if (($finalCheckoutStatus -join "`n") -cne ($initialCheckoutStatus -join "`n")) {
		$cleanupProblems += 'test suite leaves the developer checkout unchanged (case f)'
		$cleanupProblems += ('before: ' + ($initialCheckoutStatus -join ' | '))
		$cleanupProblems += ('after: ' + ($finalCheckoutStatus -join ' | '))
	}
	if ($cleanupProblems.Count -gt 0) {
		if ($null -ne $suiteError) { Write-Output "ASSERT FAILED: $($suiteError.Exception.Message)" }
		Assert-True $false ('test suite did not leave a clean tree: ' + ($cleanupProblems -join '; '))
	}
	if ($null -ne $suiteError) { throw $suiteError }
}
