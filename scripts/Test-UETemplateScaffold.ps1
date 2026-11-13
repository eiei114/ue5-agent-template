[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$productionRoot = Join-Path $repoRoot 'Production'
$generator = Join-Path $PSScriptRoot 'New-UETemplateScaffold.ps1'
$initialCheckoutStatus = @(& git -C $repoRoot status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0) { throw 'Could not record the developer checkout status before testing.' }
$testId = [Guid]::NewGuid().ToString('N')
# The regression groups reuse this suite's long fixture naming, which already produces paths far
# beyond any portable budget. They are generator-behaviour tests, not path-budget tests, so they
# declare an unbounded budget explicitly instead of having the new budget silently shorten what
# they cover. The dedicated budget group below sets its own values.
$unboundedPathBudget = 32767
$fixtureRoot = Join-Path $productionRoot ('.scaffold-test-' + $testId)
$fixtureTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('.ue-scaffold-recipes-' + $testId)
$fixtureEngine = Join-Path $fixtureRoot 'EngineRoot'
# The provenance fixtures need their own git repositories with nested repositories, so they are
# placed outside Production/ (which the residue gate requires to hold only its placeholder) and
# outside the long developer path: the generator creates its output directory through the Win32
# API, which fails past MAX_PATH, so a nested fixture under this checkout's Production would both
# hide its own residue and hit the path budget.
$provenanceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('.ue-scaffold-provenance-' + $testId)

$deepRepoRoot = Join-Path (Join-Path $fixtureRoot 'deepfixture') 'deepclone'
$projectPrefix = "Ex_$testId"
$loopProjectName = "Lp_$testId"
$existingProjectName = "No_$testId"
$otherProjectName = "Alt_$testId"
$compatibleOnlyProjectName = "Cpo_$testId"
$changelistOnlyProjectName = "Clo_$testId"
$installAProjectName = "Ida_$testId"
$installBProjectName = "Idb_$testId"
$noChangelistProjectName = "Ncl_$testId"

$ledgerRunId = "$testId-ledger"
$ledgerProjectName = "Ld_$testId"
$emptyRunId = "$testId-empty"
$leaseRunId = "$testId-lease"
$outRunId = "$testId-out"

# The longest names the generator's ValidatePattern accepts (ProjectName 40, RunId 64).
$maxName = 'P' + ('x' * 39)
$maxRun = 'a' * 64
$maxNameOutputPath = Join-Path $productionRoot ('{0}_{1}' -f $maxName, $maxRun)
$pathBudgetMaterializedName = 'PthM_' + ('m' * 35)
$outputNames = @(
	"${projectPrefix}_$testId-a",
	"${projectPrefix}_$testId-b",
	"${loopProjectName}_$testId-a",
	"${existingProjectName}_$testId-preserved",
	"Tp_${testId}_$testId-a",
	"${otherProjectName}_$testId-c",
	"${compatibleOnlyProjectName}_$testId-a",
	"${changelistOnlyProjectName}_$testId-a",
	"${installAProjectName}_$testId-a",
	"${installBProjectName}_$testId-b",
	"${noChangelistProjectName}_$testId-a"

	"${ledgerProjectName}_$ledgerRunId",
	"${existingProjectName}_$emptyRunId",
	"${existingProjectName}_$leaseRunId",
	"${existingProjectName}_$outRunId"

	'PthB_ok1_budget',
	'PthB_eq1_budget',
	'PthB_no1_budget',
	('{0}_budget' -f ('PthM_' + ('m' * 35))),
	('{0}_{1}' -f $maxName, $maxRun),
	('{0}_{1}' -f $maxName, ('b' * 64))

	"Sz_${testId}_$testId-a"
)
$outputPaths = @($outputNames | ForEach-Object { Join-Path $productionRoot $_ })
$ledgerRoot = Join-Path (Join-Path $productionRoot '.runs') ("run_$ledgerRunId")

function Assert-True([bool]$Condition, [string]$Message) {
	if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

# Config branch names the engine resolves, read from the installed UE 5.8.4
# Engine/Source/Runtime/Core/Public/Misc/ConfigCacheIni.h:101-111
# (`ENUMERATE_KNOWN_INI_FILES`). A plugin config file reaches one of these branches by name;
# anything else is dropped with a Verbose-only log
# (Engine/Source/Runtime/Core/Private/Misc/ConfigCacheIni.cpp:7275,7294-7301,7300).
$script:KnownConfigBranches = @(
	'Engine', 'Game', 'Input', 'DeviceProfiles', 'GameUserSettings',
	'Scalability', 'RuntimeOptions', 'InstallBundle', 'Hardware', 'GameplayTags'
)

function Get-PluginConfigCarrierProblems([string]$PluginDirectory, [string]$PluginName, [string]$PlatformName) {
	# Plugin layers are {PLUGIN}/Config/Default{TYPE}.ini (TYPE = plugin name) and
	# {PLUGIN}/Config/{PLATFORM}/{PLATFORM}{TYPE}.ini (ConfigHierarchy.h:61,66); the modification
	# layers are {PLUGIN}/Config/{TYPE}.ini and {PLUGIN}/Config/{PLATFORM}/{PLATFORM}{TYPE}.ini with
	# TYPE = a config branch (ConfigHierarchy.h:79,81). The runtime derives that branch name by
	# stripping the plugin name and the platform from the file name
	# (ConfigCacheIni.cpp:7275, PluginManager.cpp:1932). A file whose name matches neither layer is
	# found on disk and then discarded, so a switch written there never reaches the branch.
	$accepted = @((('Base' + $PluginName), $PluginName, ('Default' + $PluginName)) + $script:KnownConfigBranches)
	$problems = New-Object System.Collections.Generic.List[string]
	$configDirectory = Join-Path $PluginDirectory 'Config'
	$candidates = @()
	if (Test-Path -LiteralPath $configDirectory -PathType Container) {
		$candidates += @(Get-ChildItem -LiteralPath $configDirectory -File -Force | Where-Object { $_.Extension -ieq '.ini' })
		$platformDirectory = Join-Path $configDirectory $PlatformName
		if (Test-Path -LiteralPath $platformDirectory -PathType Container) {
			$candidates += @(Get-ChildItem -LiteralPath $platformDirectory -File -Force | Where-Object { $_.Extension -ieq '.ini' })
		}
	}
	foreach ($file in $candidates) {
		$base = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
		$inPlatformDirectory = (Split-Path -Leaf $file.DirectoryName) -ieq $PlatformName
		$resolvable = $false
		if ($inPlatformDirectory -and $base.StartsWith($PlatformName, [System.StringComparison]::OrdinalIgnoreCase)) {
			$base = $base.Substring($PlatformName.Length)
		}
		foreach ($name in $accepted) {
			if ($base -ceq $name) { $resolvable = $true; break }
		}
		if (-not $resolvable) {
			$relative = $file.FullName.Substring($PluginDirectory.Length + 1).Replace('\', '/')
			$message = 'Plugins/{0}/{1}: the engine cannot resolve ''{2}'' to a config branch (known branches: {3}; plugin layers: Config/Default{0}.ini). Engine/Source/Runtime/Core/Public/Misc/ConfigCacheIni.h:101-111 and ConfigCacheIni.cpp:7275,7294-7301 drop it with a Verbose-only log, so a switch placed here never reaches the branch.' -f $PluginName, $relative, $file.Name, ($script:KnownConfigBranches -join '/')
			$problems.Add($message)
		}
	}
	return $problems.ToArray()
}

function Get-ProjectConfigCarrierProblem([string]$Path) {
	# Project layers are {PROJECT}/Config/Default{TYPE}.ini and
	# {PROJECT}/Config/{PLATFORM}/{PLATFORM}{TYPE}.ini (ConfigHierarchy.h:68,70); TYPE must be a
	# branch the engine knows, so the project carrier's file name is part of the contract too.
	$leaf = [System.IO.Path]::GetFileNameWithoutExtension($Path)
	$parent = Split-Path -Leaf (Split-Path -Parent $Path)
	if ($parent -ieq 'Config') {
		if ($leaf -match '^Default(.+)$' -and $script:KnownConfigBranches -contains $Matches[1]) { return $null }
	} elseif ($leaf -match '^Windows(.+)$' -and $script:KnownConfigBranches -contains $Matches[1]) {
		return $null
	}
	return "the project config carrier '$($Path)' is not a {PROJECT}/Config/Default{TYPE}.ini (or {PLATFORM}/{PLATFORM}{TYPE}.ini) branch the engine merges"
}

function Get-ProductionResidue {
	# .gitignore excludes Production/* from `git status --untracked-files=all`, so an ignored leftover
	# from a crashed or interrupted run is invisible to the checkout comparison at the end of the
	# suite. The repository ships exactly one file under Production/, so the directory is compared
	# directly instead of trusting git to report what it ignores. This run's own fixture root and the
	# generated project outputs are the transient entries allowed here; all of them are removed in the
	# finally block. Only names this suite creates (its fixture root and its <prefix>_<id>_<id>-* and
	# negative-case outputs, for any test id) are reported, so a developer's own generated
	# Production/<Name>_<runid>/ projects do not block the suite.
	$violations = New-Object System.Collections.Generic.List[string]
	$allowed = @('PLACEHOLDER.md', '.runs') + @([System.IO.Path]::GetFileName($fixtureRoot)) + @($outputNames)
	$suiteOwnedPattern = '^(?:\.scaffold-test-[0-9a-f]{32}|[A-Za-z]+_([0-9a-f]{32})_\1-.+|Bad-Name_[0-9a-f]{32}-bad|escape_[0-9a-f]{32})$'
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
	# The ledger directory is now part of the documented layout, so it is allowed to exist. Only a
	# ledger this suite's own naming pattern owns (run_<32 hex digits>-ledger) must not survive
	# cleanup; a developer's own run ledger is not reported.
	$runsDir = Join-Path $productionRoot '.runs'
	if (Test-Path -LiteralPath $runsDir -PathType Container) {
		foreach ($ledgerEntry in @(Get-ChildItem -LiteralPath $runsDir -Force)) {
			if ($ledgerEntry.Name -cmatch '^run_[0-9a-f]{32}-ledger$') {
				$violations.Add("Production/.runs/$($ledgerEntry.Name): leftover run ledger from an earlier suite run")
			}
		}
	}
	return $violations.ToArray()
}

function Write-FixtureJson([string]$Path, [string]$Json) {
	$parent = Split-Path -Parent $Path
	[System.IO.Directory]::CreateDirectory($parent) | Out-Null
	[System.IO.File]::WriteAllText($Path, $Json, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-Generator([string]$RecipeName, [string]$Name, [string]$Run, [string[]]$Diff) {
	# The regression groups below test the recipe/lock content, not provenance, and the suite's own
	# checkout may be a detached CI merge commit the recorded repository cannot serve. The
	# publication probe is therefore skipped here so the lock records a measured null instead of a
	# claim; the dedicated provenance group below drives the probe and the strict default.
	$generatorArguments = @{
		Recipe = $RecipeName
		ProjectName = $Name
		RunId = $Run
		EngineRoot = $fixtureEngine
		ProjectDiff = $Diff
		AllowDirtyTemplate = $true
		SkipTemplatePublishCheck = $true
	}
	& $generator @generatorArguments | Out-Null
}

function Invoke-EngineGenerator([string]$RecipeName, [string]$Name, [string]$Run, [string[]]$Diff, [string]$EngineRoot) {
	# Same reason as Invoke-Generator: these groups assert recipe/engine behaviour, and the suite's
	# checkout origin is not what they measure.
	$generatorArguments = @{
		Recipe = $RecipeName
		ProjectName = $Name
		RunId = $Run
		EngineRoot = $EngineRoot
		ProjectDiff = $Diff
		AllowDirtyTemplate = $true
		SkipTemplatePublishCheck = $true
	}
	& $generator @generatorArguments | Out-Null
}

function New-FixtureRepository([string]$SourceRoot, [string]$DestinationRoot) {
	# A self-contained copy of this checkout's tracked sources as a fresh repository, so a provenance
	# fixture owns all of its own history and can push it to a fixture remote. Cloning the developer
	# checkout instead would depend on that checkout's depth (CI fetches a single merge commit) and
	# could not be pushed to an empty remote. The file list comes from git rather than the filesystem,
	# so the fixture cannot copy its own temp directories (Production/ holds this suite's fixtures) or
	# the `.git` file that points outside the worktree, and what is measured is the working-tree content
	# of the tracked files (i.e. the scripts under test).
	[System.IO.Directory]::CreateDirectory($DestinationRoot) | Out-Null
	$trackedOutput = @(& git -C $SourceRoot ls-files)
	if ($LASTEXITCODE -ne 0) { throw 'Could not list the tracked files of the template checkout.' }
	foreach ($trackedPath in $trackedOutput) {
		$relative = ([string]$trackedPath).Trim()
		if ([string]::IsNullOrWhiteSpace($relative)) { continue }
		$source = Join-Path $SourceRoot ($relative.Replace('/', '\'))
		if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
		$target = Join-Path $DestinationRoot ($relative.Replace('/', '\'))
		[System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target)) | Out-Null
		Copy-Item -LiteralPath $source -Destination $target -Force
	}
	& git -C $DestinationRoot init --quiet
	if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the provenance fixture repository.' }
	return $DestinationRoot
}

function Update-FixtureRepository([string]$RepositoryRoot, [string]$Message) {
	& git -C $RepositoryRoot -c user.name='Scaffold Fixture' -c user.email='scaffold-fixture@example.invalid' add --all
	if ($LASTEXITCODE -ne 0) { throw "Could not stage the provenance fixture change: $Message" }
	& git -C $RepositoryRoot -c user.name='Scaffold Fixture' -c user.email='scaffold-fixture@example.invalid' commit --quiet -m $Message
	if ($LASTEXITCODE -ne 0) { throw "Could not commit the provenance fixture change: $Message" }
	return (& git -C $RepositoryRoot rev-parse HEAD).Trim()
}

function New-FixtureEngineRoot([string]$Path, [string]$BuildVersionJson, [switch]$PluginWithoutVersion) {
	# A minimal installed-engine fixture for engine build identity cases: one official template and the
	# one plugin the vertical-loop recipe requires.
	[System.IO.Directory]::CreateDirectory($Path) | Out-Null
	Write-FixtureJson (Join-Path $Path 'Engine\Build\Build.version') $BuildVersionJson
	Write-FixtureTemplate (Join-Path $Path 'Templates\TP_BlankBP') 'TP_BlankBP' 'TP_BlankBP'
	# The raw-copy recipes apply the template's own Config/TemplateDefs.ini, so the minimal engine
	# fixture has to carry a real one like an installed template does.
	Write-FixtureTemplateDefs (Join-Path $Path 'Templates\TP_BlankBP') @(
		'[/Script/GameProjectGeneration.TemplateProjectDefs]',
		'FoldersToIgnore=Media',
		'FilesToIgnore="%TEMPLATENAME%.uproject"',
		'FilesToIgnore="Config/TemplateDefs.ini"'
	)
	$pluginDescriptor = if ($PluginWithoutVersion) { '{"FileVersion":3}' } else { '{"FileVersion":3,"Version":1,"VersionName":"1.0"}' }
	Write-FixtureJson (Join-Path $Path 'Engine\Plugins\MovieScene\MovieRenderPipeline\MovieRenderPipeline.uplugin') $pluginDescriptor

function Invoke-Generator([string]$RecipeName, [string]$Name, [string]$Run, [string[]]$Diff, [int]$MaxPathLength = 32767) {
	& $generator -Recipe $RecipeName -ProjectName $Name -RunId $Run -EngineRoot $fixtureEngine -ProjectDiff $Diff -AllowDirtyTemplate -SkipTemplatePublishCheck -MaxPathLength $MaxPathLength | Out-Null
}

function Invoke-GeneratorCaptured([string]$RecipeName, [string]$Name, [string]$Run, [string[]]$Diff, [int]$MaxPathLength) {
	return (& $generator -Recipe $RecipeName -ProjectName $Name -RunId $Run -EngineRoot $fixtureEngine -ProjectDiff $Diff -AllowDirtyTemplate -MaxPathLength $MaxPathLength) -join "`n"
}

function Invoke-GeneratorNoBudget([string]$RecipeName, [string]$Name, [string]$Run, [string[]]$Diff) {
	# No -MaxPathLength at all: this is the case an agent hits by following the documented example.
	& $generator -Recipe $RecipeName -ProjectName $Name -RunId $Run -EngineRoot $fixtureEngine -ProjectDiff $Diff -AllowDirtyTemplate | Out-Null
}

function Read-FixtureLock([string]$OutputPath) {
	return [System.IO.File]::ReadAllText((Join-Path $OutputPath 'template-lock.json'))
}

function Write-FixtureTemplate([string]$TemplateRoot, [string]$TemplateName, [string]$ModuleName, [string]$DefaultEngineText) {
	# Builds an installed-engine template fixture with real Modules/Source shape so the previous
	# `Modules: []` shortcut cannot hide an unresolved project identity.
	[System.IO.Directory]::CreateDirectory($TemplateRoot) | Out-Null
	$descriptor = '{"FileVersion":3,"EngineAssociation":"","Modules":[{"Name":"' + $ModuleName + '","Type":"Runtime","LoadingPhase":"Default"}]}'
	Write-FixtureJson (Join-Path $TemplateRoot ($TemplateName + '.uproject')) $descriptor
	$sourceModule = Join-Path $TemplateRoot ('Source\' + $TemplateName)
	Write-FixtureJson (Join-Path $sourceModule ($TemplateName + '.Build.cs')) ("using UnrealBuildTool;`n`npublic class {0} : ModuleRules`n{{`n}}`n" -f $TemplateName)
	Write-FixtureJson (Join-Path $sourceModule ('Private\' + $TemplateName + 'Module.cpp')) ("#include `"CoreMinimal.h`"`n#include `"Modules/ModuleManager.h`"`n`nIMPLEMENT_PRIMARY_GAME_MODULE(FDefaultGameModuleImpl, {0}, `"{0}`");`n" -f $TemplateName)
	Write-FixtureJson (Join-Path $TemplateRoot ('Source\' + $TemplateName + 'Target.cs')) ("using UnrealBuildTool;`n`npublic class {0}Target : TargetRules`n{{`n}}`n" -f $TemplateName)
	# The installed New Project templates ship Config/DefaultEngine.ini; the online recipe appends
	# its provider/session section to that copied project file.
	if ([string]::IsNullOrWhiteSpace($DefaultEngineText)) {
		$DefaultEngineText = "[/Script/EngineSettings.GameMapsSettings]`r`nGameDefaultMap=/Engine/Maps/Templates/OpenWorld`r`n"
	}
	Write-FixtureJson (Join-Path $TemplateRoot 'Config\DefaultEngine.ini') $DefaultEngineText
}

function Write-FixtureTemplateDefs([string]$TemplateRoot, [string[]]$Lines) {
	# Every installed template ships Config/TemplateDefs.ini; the generator now reads it for the
	# raw-copy recipes too, so the fixture has to carry a real one instead of only the
	# TP_ThirdPerson fixture that the materialize group uses.
	[System.IO.Directory]::CreateDirectory((Join-Path $TemplateRoot 'Config')) | Out-Null
	[System.IO.File]::WriteAllText((Join-Path $TemplateRoot 'Config\TemplateDefs.ini'), ($Lines -join "`r`n"), [System.Text.UTF8Encoding]::new($false))
}

function Set-FixtureRecipeTemplate([string]$RepositoryRoot, [string]$RecipeName, [string]$TemplateName) {
	$recipeFile = Join-Path $RepositoryRoot ("templates\recipes\$RecipeName\recipe.json")
	$recipeData = Get-Content -Raw -LiteralPath $recipeFile | ConvertFrom-Json
	$recipeData.engine_template = $TemplateName
	Write-FixtureJson $recipeFile (ConvertTo-Json -InputObject $recipeData -Depth 10)
}

function Assert-GeneratorFails([scriptblock]$Action, [string]$Message) {
	$failed = $false
	try { & $Action } catch { $failed = $true }
	Assert-True $failed $Message
}

# templates/QA.md is the only QA template a new run copies into Out/run_<runid>/ and the delivery
# contract treats it as mandatory (AGENTS.md:14,45, docs/06-delivery.md:5). Rows that do not exist
# cannot be filled, so a missing row silently removes an acceptance item: the reviewer records
# nothing, no `unverified` cell is created, and docs/05-qa.md's "verdict + version/hash + operator +
# timestamp + evidence + unverified" set is satisfied by a template that never asked. These rows are
# therefore machine-checked here instead of trusted to reviewer discipline.
$qaTemplateRelativePath = 'templates/QA.md'
$qaRequiredRowIds = @(
	'QA-BUILD-01', 'QA-MAP-01',
	'QA-PLAY-01', 'QA-PLAY-02', 'QA-PLAY-03',
	'QA-PERF-01', 'QA-AUDIO-01',
	'QA-IMG-01', 'QA-MRQ-01', 'QA-MRQ-02',
	'QA-VISUAL-01', 'QA-VISUAL-02',
	'QA-SHIP-01', 'QA-MAC-01', 'QA-RIGHTS-01',
	'QA-NET-01', 'QA-NET-02', 'QA-NET-03', 'QA-NET-04', 'QA-NET-05',
	'QA-NET-06', 'QA-NET-07', 'QA-NET-08', 'QA-NET-09'
)
$qaOnlineRowIds = @('QA-NET-01', 'QA-NET-02', 'QA-NET-03', 'QA-NET-04', 'QA-NET-05', 'QA-NET-06', 'QA-NET-07', 'QA-NET-08', 'QA-NET-09')
# Rows this contract added. Their evidence column has to state what proves the row, because the
# missing acceptance item was a missing line to write into, not a missing sentence about it.
$qaEvidenceRequiredRowIds = @('QA-PLAY-01', 'QA-PLAY-02') + $qaOnlineRowIds
$qaAllowedVerdicts = @('pass', 'fail', 'unverified', 'non-goal')

function Get-QaTemplateRows([string]$Path) {
	$lines = @([System.IO.File]::ReadAllText($Path) -split "\r?\n")
	$rows = New-Object System.Collections.Generic.List[object]
	foreach ($line in $lines) {
		$trimmed = $line.Trim()
		if (-not $trimmed.StartsWith('|')) { continue }
		# Split on column separators only: a Markdown escape (\|) inside an evidence cell is content,
		# and splitting it away turned a complete row into a 4-cell line that the checks then ignored.
		$inner = $trimmed.Substring(1)
		if ($inner.EndsWith('|') -and -not $inner.EndsWith('\|')) { $inner = $inner.Substring(0, $inner.Length - 1) }
		$cells = @([regex]::Split($inner, '(?<!\\)\|') | ForEach-Object { $_.Trim() })
		if ($cells.Count -ne 3) { continue }
		if ($cells[1] -eq 'pass/fail/unverified/non-goal') { continue }
		if ($cells[0] -match '^:?-{2,}$' -or $cells[1] -match '^:?-{2,}$') { continue }
		$rows.Add([pscustomobject]@{ Id = ''; Item = $cells[0]; Verdict = $cells[1]; Evidence = $cells[2] })
		$idMatch = [regex]::Match($cells[0], '^\[(QA-[A-Z]+-\d{2})\]\s*(.*)$')
		if ($idMatch.Success) {
			$rows[$rows.Count - 1].Id = $idMatch.Groups[1].Value
			$rows[$rows.Count - 1].Item = $idMatch.Groups[2].Value
		}
	}
	return $rows.ToArray()
}

function Get-QaTemplateViolations([string]$Path) {
	$violations = New-Object System.Collections.Generic.List[string]
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		$violations.Add("$Path : the QA template is missing")
		return $violations.ToArray()
	}
	$text = [System.IO.File]::ReadAllText($Path)
	$lines = @($text -split "\r?\n")
	$firstLine = $lines[0].Trim()
	# The title keeps telling a reviewer that an empty cell is Unverified, and the preamble keeps
	# scoping the online rows to the one recipe that enables the Null/LAN starter. Both are matched
	# on ASCII fragments so the check stays readable to Windows PowerShell 5.1, which reads this
	# repository's BOM-less UTF-8 files as ANSI.
	if (-not ($firstLine.StartsWith('# QA') -and $firstLine.Contains('Unverified'))) {
		$violations.Add('the title must keep stating that an empty cell is Unverified')
	}
	$headerIndex = -1
	for ($i = 0; $i -lt $lines.Count; $i++) {
		if ($lines[$i].Contains('pass/fail/unverified/non-goal')) { $headerIndex = $i; break }
	}
	if ($headerIndex -lt 0) {
		$violations.Add('the table header row with the four allowed values is missing')
	} else {
		$preamble = ($lines[0..($headerIndex - 1)] -join "`n")
		if (-not $preamble.Contains('`spectator-explore`')) { $violations.Add('the preamble must name the recipe that the online rows belong to') }
		if (-not $preamble.Contains('non-goal')) { $violations.Add('the preamble must state that other recipes record non-goal') }
	}
	$rows = @(Get-QaTemplateRows $Path)
	if ($rows.Count -lt $qaRequiredRowIds.Count) {
		$violations.Add("the table carries $($rows.Count) data rows, fewer than the $($qaRequiredRowIds.Count) required acceptance rows")
	}
	$seen = @{}
	foreach ($row in $rows) {
		if ([string]::IsNullOrWhiteSpace($row.Id)) {
			$violations.Add("row '$($row.Item)' has no [QA-...] identifier, so its acceptance item cannot be tracked")
			continue
		}
		if ($seen.ContainsKey($row.Id)) { $violations.Add("duplicate row identifier $($row.Id)") } else { $seen[$row.Id] = $true }
		if ([string]::IsNullOrWhiteSpace($row.Item)) { $violations.Add("row $($row.Id) has no item text") }
		if (-not ($qaAllowedVerdicts -contains $row.Verdict)) {
			$violations.Add("row $($row.Id) uses '$($row.Verdict)' instead of one of $($qaAllowedVerdicts -join '/') on a blank template")
		}
		if ($qaOnlineRowIds -contains $row.Id) {
			if (-not $row.Item.Contains('spectator-explore')) { $violations.Add("online row $($row.Id) does not state that it is spectator-explore only") }
			if (-not $row.Item.Contains('non-goal')) { $violations.Add("online row $($row.Id) does not state the non-goal value for other recipes") }
		}
	}
	foreach ($requiredId in $qaRequiredRowIds) {
		if (-not $seen.ContainsKey($requiredId)) { $violations.Add("required acceptance row $requiredId is missing") }
	}
	# The timeout report and the cleanup after a late success are separate claims (docs/08-online-
	# foundations.md:27). One row must not cover both.
	if ($seen.ContainsKey('QA-NET-08')) {
		$timeoutRow = @($rows | Where-Object { $_.Id -eq 'QA-NET-08' })[0]
		if (-not $timeoutRow.Item.Contains('timeout')) { $violations.Add('QA-NET-08 must record the timeout occurrence') }
		if ($timeoutRow.Evidence.Contains('cleanup')) { $violations.Add('QA-NET-08 must not fold the post-timeout cleanup into the timeout occurrence row') }
	}
	if ($seen.ContainsKey('QA-NET-09')) {
		$cleanupRow = @($rows | Where-Object { $_.Id -eq 'QA-NET-09' })[0]
		if (-not $cleanupRow.Item.Contains('timeout')) { $violations.Add('QA-NET-09 must be scoped to the cleanup after a timeout') }
		if (-not $cleanupRow.Evidence.Contains('cleanup')) { $violations.Add('QA-NET-09 must name the cleanup of a late create/join in its evidence column') }
		if ($seen.ContainsKey('QA-NET-08')) {
			$otherRow = @($rows | Where-Object { $_.Id -eq 'QA-NET-08' })[0]
			if ($cleanupRow.Item -ceq $otherRow.Item) { $violations.Add('QA-NET-08 and QA-NET-09 must not share one item text; the timeout and its cleanup are separate claims') }
		}
	}
	return $violations.ToArray()
}

function Assert-QaTemplateContract([string]$Path) {
	$violations = @(Get-QaTemplateViolations $Path)
	if ($violations.Count -gt 0) { throw ('QA template contract violated: ' + ($violations -join '; ')) }
}

function New-FixtureRepository([string]$Name, [string]$Revision) {
	# An isolated clone of the committed template, with the generator under test copied in. Recipe
	# directories can then be added or broken without touching the developer checkout, and the
	# checkout-unchanged gate at the end of the suite keeps its meaning. The clones live in a short
	# throwaway directory outside the repository because a checkout under
	# Production/<fixture>/<repo>/Production/<Name>_<runid>/ would exceed the Windows path budget.
	$path = Join-Path $fixtureTempRoot $Name
	& git -C $repoRoot clone --quiet --local --no-hardlinks --no-tags --no-checkout $repoRoot $path
	if ($LASTEXITCODE -ne 0) { throw "Could not create the isolated repository fixture $Name." }
	& git -C $path checkout --quiet --detach $Revision
	if ($LASTEXITCODE -ne 0) { throw "Could not check out revision $Revision in the isolated repository fixture $Name." }
	[System.IO.Directory]::CreateDirectory((Join-Path $path 'Production')) | Out-Null
	Copy-Item -LiteralPath $generator -Destination (Join-Path $path 'scripts\New-UETemplateScaffold.ps1') -Force
	return $path
}

function Invoke-RepositoryGenerator([string]$RepositoryRoot, [string]$RecipeName, [string]$Name, [string]$Run, [string[]]$Diff) {
	$repositoryGenerator = Join-Path $RepositoryRoot 'scripts\New-UETemplateScaffold.ps1'
	& $repositoryGenerator -Recipe $RecipeName -ProjectName $Name -RunId $Run -EngineRoot $fixtureEngine -ProjectDiff $Diff -AllowDirtyTemplate | Out-Null
}

function Get-GeneratorFailure([scriptblock]$Action) {
	try { & $Action | Out-Null; return '' } catch { return $_.Exception.Message }
}

function Write-FixtureRecipe([string]$Directory, [string]$Name, [string]$Purpose, [string[]]$Plugins, [string]$EngineTemplate, [bool]$WithCapture, [bool]$WithPlay) {
	[System.IO.Directory]::CreateDirectory($Directory) | Out-Null
	$recipeJson = [ordered]@{
		schema_version = 1
		recipe = $Name
		purpose = $Purpose
		engine_template = $EngineTemplate
		required_plugins = @($Plugins)
	}
	Write-FixtureJson (Join-Path $Directory 'recipe.json') (ConvertTo-Json -InputObject $recipeJson -Depth 5)
	if ($WithCapture) { [System.IO.File]::WriteAllText((Join-Path $Directory 'Capture.md'), "# $Name capture delta`r`n", [System.Text.UTF8Encoding]::new($false)) }
	if ($WithPlay) { [System.IO.File]::WriteAllText((Join-Path $Directory 'Play.md'), "# $Name play delta`r`n", [System.Text.UTF8Encoding]::new($false)) }
}

function Get-GeneratorFailure([scriptblock]$Action) {
	# Returns the failure text instead of a bool so a negative case can assert what the agent reads.
	try { & $Action | Out-Null } catch { return $_.Exception.Message }
	return ''
}

function Assert-GeneratedProject([string]$ProjectName, [string]$Run, [string]$Message) {
	$path = Join-Path $productionRoot ('{0}_{1}' -f $ProjectName, $Run)
	Assert-True (Test-Path -LiteralPath $path -PathType Container) $Message
	Assert-True (@(Get-ChildItem -LiteralPath $path -File -Force).Count -gt 0) ($Message + ' (the project directory is not empty)')
}

$suiteError = $null
try {
	$initialProductionResidue = @(Get-ProductionResidue)
	Assert-True ($initialProductionResidue.Count -eq 0) ("Production/ holds only the tracked placeholder before testing: " + ($initialProductionResidue -join '; '))

	# Positive case: the shipped template carries every row the repository itself requires.
	Assert-QaTemplateContract (Join-Path $repoRoot $qaTemplateRelativePath)
	$qaRows = @(Get-QaTemplateRows (Join-Path $repoRoot $qaTemplateRelativePath))
	Assert-True (@($qaRows | Where-Object { $qaOnlineRowIds -contains $_.Id }).Count -eq $qaOnlineRowIds.Count) "the QA template carries all $($qaOnlineRowIds.Count) online/LAN acceptance rows"
	foreach ($required in $qaEvidenceRequiredRowIds) {
		$row = @($qaRows | Where-Object { $_.Id -eq $required })[0]
		Assert-True ([string]::IsNullOrWhiteSpace($row.Evidence) -eq $false) "QA row $required says what evidence proves it"
	}
	Write-Output 'PASS: QA template carries the repository-required acceptance rows for Play, online/LAN, and timeout cleanup'

	[System.IO.Directory]::CreateDirectory($fixtureEngine) | Out-Null
	# Epic's own Engine/Build/Build.version keeps Changelist 0 and puts the build identifier in
	# CompatibleChangelist (EpicGames/UnrealEngine, read 2026-11-03); public mirrors show the same
	# shape. The fixture uses that real shape so the suite cannot pass on a single-shape assumption.
	Write-FixtureJson (Join-Path $fixtureEngine 'Engine\Build\Build.version') '{"MajorVersion":5,"MinorVersion":8,"PatchVersion":4,"Changelist":58902052,"CompatibleChangelist":55116800,"IsLicenseeVersion":0,"IsPromotedBuild":1,"BranchName":"++UE5+Release-5.8"}'

	$firstPersonTemplate = Join-Path $fixtureEngine 'Templates\TP_FirstPerson'
	$blankTemplate = Join-Path $fixtureEngine 'Templates\TP_BlankBP'
	# Mirrors the installed TP_FirstPerson shape: the default map lives in the template's own Content and
	# references shared packs (Characters / LevelPrototyping / Input) that engine supplies separately, plus
	# the Media/ thumbnails and Config/TemplateDefs.ini the template's own ignore rules exclude.
	Write-FixtureTemplate $firstPersonTemplate 'TP_FirstPerson' 'TP_FirstPerson' ("[/Script/EngineSettings.GameMapsSettings]`r`nEditorStartupMap=/Game/FirstPerson/Lvl_FirstPerson.Lvl_FirstPerson`r`nGameDefaultMap=/Game/FirstPerson/Lvl_FirstPerson.Lvl_FirstPerson`r`nGlobalDefaultGameMode=/Game/FirstPerson/Blueprints/BP_FirstPersonGameMode.BP_FirstPersonGameMode_C`r`n")
	Write-FixtureTemplateDefs $firstPersonTemplate @(
		'[/Script/GameProjectGeneration.TemplateProjectDefs]',
		'FoldersToIgnore=Media',
		'FilesToIgnore="%TEMPLATENAME%.uproject"',
		'FilesToIgnore="%TEMPLATENAME%.png"',
		'FilesToIgnore="Config/TemplateDefs.ini"',
		'FilesToIgnore="Config/config.ini"',
		'SharedContentPacks=(MountName="Characters",DetailLevels=("High"))',
		'SharedContentPacks=(MountName="LevelPrototyping",DetailLevels=("High"))',
		'SharedContentPacks=(MountName="Input",DetailLevels=("High"))',
		'EditDetailLevelPreference="High"'
	)
	Write-FixtureJson (Join-Path $firstPersonTemplate 'Content\FirstPerson\Lvl_FirstPerson.umap') 'binary Lvl_FirstPerson'
	Write-FixtureJson (Join-Path $firstPersonTemplate 'Content\FirstPerson\Blueprints\BP_FirstPersonGameMode.uasset') 'binary BP_FirstPersonGameMode'
	Write-FixtureJson (Join-Path $firstPersonTemplate 'Media\TP_FirstPerson.png') 'thumbnail fixture'
	Write-FixtureJson (Join-Path $firstPersonTemplate 'Media\TP_FirstPerson_Preview.png') 'thumbnail fixture'
	Write-FixtureJson (Join-Path $firstPersonTemplate 'Config\config.ini') 'GameName=TP_FirstPerson'
	Write-FixtureJson (Join-Path $fixtureEngine 'Templates\TemplateResources\High\Characters\Content\Mannequins\Meshes\SK_Mannequin.uasset') 'pack Characters'
	Write-FixtureJson (Join-Path $fixtureEngine 'Templates\TemplateResources\High\Characters\Content\Mannequins\Anims\Unarmed\ABP_Unarmed.uasset') 'pack Characters'
	Write-FixtureJson (Join-Path $fixtureEngine 'Templates\TemplateResources\High\LevelPrototyping\Content\Meshes\SM_Cube.uasset') 'pack LevelPrototyping'
	Write-FixtureJson (Join-Path $fixtureEngine 'Templates\TemplateResources\High\LevelPrototyping\Content\Materials\MI_DefaultColorway.uasset') 'pack LevelPrototyping'
	Write-FixtureJson (Join-Path $fixtureEngine 'Templates\TemplateResources\High\Input\Content\Actions\IA_Jump.uasset') 'pack Input'
	Write-FixtureJson (Join-Path $fixtureEngine 'Templates\TemplateResources\High\Input\Content\IMC_Default.uasset') 'pack Input'

	# TP_BlankBP declares no SharedContentPacks and its default map is engine content, so the raw-copy
	# path is checked here for the ignore rules alone.
	Write-FixtureTemplate $blankTemplate 'TP_BlankBP' 'TP_BlankBP'
	Write-FixtureTemplateDefs $blankTemplate @(
		'[/Script/GameProjectGeneration.TemplateProjectDefs]',
		'FoldersToIgnore=Media',
		'FilesToIgnore="%TEMPLATENAME%.uproject"',
		'FilesToIgnore="%TEMPLATENAME%.png"',
		'FilesToIgnore="Config/TemplateDefs.ini"',
		'FilesToIgnore="Config/config.ini"'
	)
	Write-FixtureJson (Join-Path $blankTemplate 'Media\TP_BlankBP.png') 'thumbnail fixture'
	Write-FixtureJson (Join-Path $blankTemplate 'Media\TP_BlankBP_Preview.png') 'thumbnail fixture'

	$thirdPersonTemplate = Join-Path $fixtureEngine 'Templates\TP_ThirdPerson'
	Write-FixtureJson (Join-Path $thirdPersonTemplate 'TP_ThirdPerson.uproject') '{"FileVersion":3,"EngineAssociation":"","Modules":[{"Name":"TP_ThirdPerson","Type":"Runtime"}],"Plugins":[]}'
	Write-FixtureJson (Join-Path $thirdPersonTemplate 'Config\TemplateDefs.ini') (@(
		'[/Script/GameProjectGeneration.TemplateProjectDefs]',
		'FoldersToIgnore=Media',
		'FoldersToIgnore=Content/ThirdPerson/Animations',
		'FilesToIgnore="%TEMPLATENAME%.uproject"',
		'FilesToIgnore="Config/TemplateDefs.ini"',
		'FilesToIgnore="Config/config.ini"',
		'FolderRenames=(From="Source/%TEMPLATENAME%",To="Source/%PROJECTNAME%")',
		'FilenameReplacements=(Extensions=("cpp","h","ini","cs"),From="%TEMPLATENAME%",To="%PROJECTNAME%",bCaseSensitive=false)',
		'ReplacementsInFiles=(Extensions=("cpp","h","ini","cs"),From="%TEMPLATENAME%",To="%PROJECTNAME%",bCaseSensitive=false)',
		'SharedContentPacks=(MountName="Characters",DetailLevels=("High"))',
		'EditDetailLevelPreference="High"'
	) -join "`r`n")
	Write-FixtureJson (Join-Path $thirdPersonTemplate 'Config\config.ini') 'GameName=TP_ThirdPerson'
	Write-FixtureJson (Join-Path $thirdPersonTemplate 'Config\DefaultEngine.ini') "[/Script/EngineSettings.GameMapsSettings]`r`nGameDefaultMap=/Game/ThirdPerson/Lvl_ThirdPerson.Lvl_ThirdPerson`r`n"
	Write-FixtureJson (Join-Path $thirdPersonTemplate 'Config\DefaultGame.ini') "[/Script/EngineSettings.GeneralProjectSettings]`r`nProjectID=(A=1,B=2,C=3,D=4)`r`nProjectName=Third Person Game Template`r`n"
	Write-FixtureJson (Join-Path $thirdPersonTemplate 'Source\TP_ThirdPerson\TP_ThirdPerson.Build.cs') 'public class TP_ThirdPerson { } // TP_THIRDPERSON_API tp_thirdperson'
	# Reflected headers the wizard renames: each one's copied file name differs from the source and
	# its copied contents include the UHT header, so each must produce one class redirect.
	foreach ($reflectedClass in @('Character', 'GameMode', 'PlayerController')) {
		$reflectedSource = "TP_ThirdPerson$reflectedClass"
		Write-FixtureJson (Join-Path $thirdPersonTemplate ("Source\TP_ThirdPerson\$reflectedSource.h")) (@(
			'#include "CoreMinimal.h"',
			("#include `"{0}.generated.h`"" -f $reflectedSource),
			'UCLASS()',
			("class A{0} : public AActor {{ GENERATED_BODY() }};" -f $reflectedSource)
		) -join "`r`n")
		Write-FixtureJson (Join-Path $thirdPersonTemplate ("Source\TP_ThirdPerson\$reflectedSource.cpp")) ("#include `"{0}.h`"" -f $reflectedSource)
	}
	# Negative cases pinned in the fixture: a renamed header that is not a UObject (log category only,
	# like the installed TP_ThirdPerson.h) and a reflected header whose file name does not change
	# (every Variant_* class keeps its name and resolves through the package redirect alone).
	Write-FixtureJson (Join-Path $thirdPersonTemplate 'Source\TP_ThirdPerson\TP_ThirdPerson.h') "#include `"CoreMinimal.h`"`r`nDECLARE_LOG_CATEGORY_EXTERN(LogTP_ThirdPerson, Log, All);`r`n"
	Write-FixtureJson (Join-Path $thirdPersonTemplate 'Source\TP_ThirdPerson\Variant_Combat\CombatEnemy.h') (@(
		'#include "CoreMinimal.h"',
		'#include "CombatEnemy.generated.h"',
		'UCLASS()',
		'class ACombatEnemy : public AActor { GENERATED_BODY() };'
	) -join "`r`n")
	Write-FixtureJson (Join-Path $thirdPersonTemplate 'Source\TP_ThirdPerson\Variant_Combat\CombatEnemy.cpp') '#include "CombatEnemy.h"'
	Write-FixtureJson (Join-Path $thirdPersonTemplate 'Source\TP_ThirdPerson.Target.cs') 'ExtraModuleNames.Add("TP_ThirdPerson");'
	Write-FixtureJson (Join-Path $thirdPersonTemplate 'Content\ThirdPerson\Lvl_ThirdPerson.umap') 'binary TP_ThirdPerson'
	Write-FixtureJson (Join-Path $thirdPersonTemplate 'Content\ThirdPerson\Animations\Ignored.uasset') 'ignored'
	Write-FixtureJson (Join-Path $thirdPersonTemplate 'Media\Ignored.png') 'ignored'
	Write-FixtureJson (Join-Path $fixtureEngine 'Templates\TemplateResources\High\Characters\Content\Mannequins\SK.uasset') 'pack'

	$pluginFixtures = @(
		@{ Name = 'OnlineSubsystem'; RelativePath = 'Engine\Plugins\Online\OnlineSubsystem\OnlineSubsystem.uplugin'; Version = '1.0' },
		@{ Name = 'OnlineSubsystemNull'; RelativePath = 'Engine\Plugins\Online\OnlineSubsystemNull\OnlineSubsystemNull.uplugin'; Version = '1.0' },
		@{ Name = 'OnlineSubsystemUtils'; RelativePath = 'Engine\Plugins\Online\OnlineSubsystemUtils\OnlineSubsystemUtils.uplugin'; Version = '1.0' },
		@{ Name = 'MovieRenderPipeline'; RelativePath = 'Engine\Plugins\MovieScene\MovieRenderPipeline\MovieRenderPipeline.uplugin'; Version = '1.0' }
	)
	foreach ($plugin in $pluginFixtures) {
		Write-FixtureJson (Join-Path $fixtureEngine $plugin.RelativePath) ("{`"FileVersion`":3,`"Version`":1,`"VersionName`":`"$($plugin.Version)`"}")
	}

	$dirtyTemplateRoot = Join-Path $fixtureRoot 'DirtyTemplate'
	$templateRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
	if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($templateRevision)) {
		throw 'Could not determine the template revision for the isolated dirty-template fixture.'
	}
	& git -C $repoRoot clone --quiet --local --no-hardlinks --no-tags --no-checkout $repoRoot $dirtyTemplateRoot
	if ($LASTEXITCODE -ne 0) { throw 'Could not create the isolated dirty-template repository fixture.' }
	& git -C $dirtyTemplateRoot checkout --quiet --detach $templateRevision
	if ($LASTEXITCODE -ne 0) { throw "Could not check out revision $templateRevision in the isolated dirty-template repository fixture." }
	[System.IO.Directory]::CreateDirectory((Join-Path $dirtyTemplateRoot 'Production')) | Out-Null
	$dirtyMarker = Join-Path $dirtyTemplateRoot 'DirtyTemplate.marker'
	[System.IO.File]::WriteAllText($dirtyMarker, 'fixture only', [System.Text.UTF8Encoding]::new($false))
	$dirtyGenerator = Join-Path $dirtyTemplateRoot 'scripts\New-UETemplateScaffold.ps1'
	Copy-Item -LiteralPath $generator -Destination $dirtyGenerator -Force
	$dirtyProjectName = "Dirty_$testId"
	$dirtyOutput = Join-Path (Join-Path $dirtyTemplateRoot 'Production') "${dirtyProjectName}_dirty-rejected"
	$dirtyFailure = ''
	try {
		& $dirtyGenerator -Recipe 'spectator-explore' -ProjectName $dirtyProjectName -RunId 'dirty-rejected' -EngineRoot $fixtureEngine -ProjectDiff @() -SkipTemplatePublishCheck | Out-Null
	} catch {
		$dirtyFailure = $_.Exception.Message
	}
	Assert-True ($dirtyFailure.Contains('template working tree is dirty')) 'dirty template is rejected when AllowDirtyTemplate is omitted'
	Assert-True (-not (Test-Path -LiteralPath $dirtyOutput)) 'dirty-template rejection creates no output project'
	Assert-True ([System.IO.File]::ReadAllText($dirtyMarker) -ceq 'fixture only') 'dirty-template rejection leaves the isolated fixture marker unchanged'
	Write-Output 'PASS: dirty template is rejected using an isolated fixture without touching the developer checkout'

	# Provenance group: the lock must name the template actually used and must only claim a published
	# commit when the recorded repository can serve it. Four fixture repositories cover the states a
	# real checkout can be in: pushed head, unpushed head, no remote, and an offline bundle clone.
	$provTemplateRoot = Join-Path $provenanceRoot 'ProvTemplate'
	New-FixtureRepository -SourceRoot $repoRoot -DestinationRoot $provTemplateRoot | Out-Null
	$provTemplateRevision = Update-FixtureRepository -RepositoryRoot $provTemplateRoot -Message 'provenance fixture base'
	$provRemote = Join-Path $provenanceRoot 'ProvRemote.git'
	& git init --quiet --bare $provRemote
	if ($LASTEXITCODE -ne 0) { throw 'Could not create the provenance fixture remote.' }
	& git -C $provTemplateRoot remote add origin $provRemote
	if ($LASTEXITCODE -ne 0) { throw 'Could not attach the provenance fixture remote.' }
	& git -C $provTemplateRoot push --quiet origin HEAD:refs/heads/main
	if ($LASTEXITCODE -ne 0) { throw 'Could not publish the provenance fixture base commit.' }
	[System.IO.Directory]::CreateDirectory((Join-Path $provTemplateRoot 'Production')) | Out-Null
	$provGenerator = Join-Path $provTemplateRoot 'scripts\New-UETemplateScaffold.ps1'

	function Test-CommitRetrievable([string]$Repository, [string]$Commit, [string]$ScratchRoot) {
		$probeRepo = Join-Path $ScratchRoot ('fetch-' + [Guid]::NewGuid().ToString('N') + '.git')
		& git init --quiet --bare $probeRepo | Out-Null
		if ($LASTEXITCODE -ne 0) { throw "Could not create the provenance fetch probe repository: $probeRepo" }
		# PowerShell 5.1 raises a terminating error for a failing native command's stderr when
		# `$ErrorActionPreference = 'Stop'`, so a *expected* rejection ("not our ref") must be run
		# with the preference relaxed locally; otherwise the negative assertion would throw in 5.1
		# and silently pass in pwsh 7.
		$previousPreference = $ErrorActionPreference
		$ErrorActionPreference = 'Continue'
		try {
			& git -C $probeRepo fetch --quiet --depth 1 --no-tags $Repository $Commit 2>&1 | Out-Null
			$fetchCode = $LASTEXITCODE
		} finally {
			$ErrorActionPreference = $previousPreference
		}
		Remove-Item -LiteralPath $probeRepo -Recurse -Force -ErrorAction SilentlyContinue
		return $fetchCode -eq 0
	}
	function Get-LockProvenance([string]$ProjectRoot) {
		return [System.IO.File]::ReadAllText((Join-Path $ProjectRoot 'template-lock.json')) | ConvertFrom-Json
	}

	# (a) pushed head: the default path succeeds and the lock names the commit the fixture remote serves.
	$provPublishedName = "Pub_$testId"
	$provPublishedOutput = Join-Path (Join-Path $provTemplateRoot 'Production') "${provPublishedName}_$testId-pub"
	& $provGenerator -Recipe 'spectator-explore' -ProjectName $provPublishedName -RunId "$testId-pub" -EngineRoot $fixtureEngine -ProjectDiff @() | Out-Null
	if (-not (Test-Path -LiteralPath $provPublishedOutput -PathType Container)) { throw 'The published-commit scaffold run produced no output.' }
	$provPublishedLock = Get-LockProvenance $provPublishedOutput
	Assert-True ($provPublishedLock.template_commit -ceq $provTemplateRevision) 'published fixture: lock records the template HEAD it was generated from'
	Assert-True ($provPublishedLock.template_repository -ceq $provRemote) 'published fixture: lock records the measured origin, not a fixed repository constant'
	Assert-True ($provPublishedLock.template_repository -cne 'https://github.com/eiei114/ue5-agent-template') 'published fixture: lock does not claim the public repository it was never cloned from'
	Assert-True ($provPublishedLock.template_source_kind -ceq 'local-path') 'published fixture: lock records the source kind of the clone origin'
	Assert-True ($provPublishedLock.template_commit_published -eq $true) 'published fixture: the publication probe reports a retrievable commit'
	$fetchScratch = Join-Path $provenanceRoot 'FetchScratch'
	[System.IO.Directory]::CreateDirectory($fetchScratch) | Out-Null
	Assert-True (Test-CommitRetrievable -Repository $provPublishedLock.template_repository -Commit $provPublishedLock.template_commit -ScratchRoot $fetchScratch) 'the locked template commit can be fetched from the repository the lock names'
	Assert-True (-not (Test-CommitRetrievable -Repository $provPublishedLock.template_repository -Commit ('0' * 40) -ScratchRoot $fetchScratch)) 'the retrieval assertion rejects a well-formed but non-existent commit (the previous suite accepted an all-zero SHA)'
	# A third party must also be able to reconstruct the template from that repository and commit.
	$thirdPartyClone = Join-Path $provenanceRoot 'ThirdPartyClone'
	& git clone --quiet $provPublishedLock.template_repository $thirdPartyClone
	if ($LASTEXITCODE -ne 0) { throw 'Could not clone the repository the published lock names.' }
	& git -C $thirdPartyClone checkout --quiet --detach $provPublishedLock.template_commit
	if ($LASTEXITCODE -ne 0) { throw 'A third party could not check out the commit the published lock names.' }
	Assert-True (Test-Path -LiteralPath (Join-Path $thirdPartyClone 'scripts\New-UETemplateScaffold.ps1') -PathType Leaf) 'the commit the lock names contains the template the lock describes'
	Write-Output 'PASS: a published template commit is recorded with its measured repository and stays retrievable'

	# (b) unpushed head: default stops, and the explicit switch records published = false.
	[System.IO.File]::AppendAllText((Join-Path $provTemplateRoot 'PROVENANCE-FIXTURE.txt'), "unpublished change`n", [System.Text.UTF8Encoding]::new($false))
	$provUnpublishedRevision = Update-FixtureRepository -RepositoryRoot $provTemplateRoot -Message 'provenance fixture unpublished head'
	Assert-True (-not (Test-CommitRetrievable -Repository $provRemote -Commit $provUnpublishedRevision -ScratchRoot $fetchScratch)) 'the fixture remote genuinely cannot serve the unpushed commit'
	$provUnpublishedName = "Unp_$testId"
	$provUnpublishedDefaultOutput = Join-Path (Join-Path $provTemplateRoot 'Production') "${provUnpublishedName}_$testId-default"
	$provUnpublishedFailure = ''
	try {
		& $provGenerator -Recipe 'spectator-explore' -ProjectName $provUnpublishedName -RunId "$testId-default" -EngineRoot $fixtureEngine -ProjectDiff @() | Out-Null
	} catch {
		$provUnpublishedFailure = $_.Exception.Message
	}
	Assert-True ($provUnpublishedFailure.Contains('is not retrievable from the recorded template repository')) 'an unpushed template commit stops generation by default'
	Assert-True (-not (Test-Path -LiteralPath $provUnpublishedDefaultOutput)) 'the unpublished stop writes no project'
	$provUnpublishedAllowedOutput = Join-Path (Join-Path $provTemplateRoot 'Production') "${provUnpublishedName}_$testId-allowed"
	& $provGenerator -Recipe 'spectator-explore' -ProjectName $provUnpublishedName -RunId "$testId-allowed" -EngineRoot $fixtureEngine -ProjectDiff @() -AllowUnpublishedTemplate | Out-Null
	$provUnpublishedLock = Get-LockProvenance $provUnpublishedAllowedOutput
	Assert-True ($provUnpublishedLock.template_commit -ceq $provUnpublishedRevision) 'the explicit switch still records the real template commit'
	Assert-True ($provUnpublishedLock.template_commit_published -eq $false) 'the explicit switch records published = false instead of claiming the commit exists remotely'
	Assert-True ($null -ne $provUnpublishedLock.PSObject.Properties['template_commit_published']) 'an unpublished lock spells out template_commit_published rather than omitting it'
	Write-Output 'PASS: an unpushed template commit stops the default path and is recorded as unpublished when allowed'

	# (c) no remote: the lock must not fall back to the public repository constant.
	$provNoRemoteRoot = Join-Path $provenanceRoot 'ProvNoRemote'
	& git clone --quiet --no-hardlinks $provTemplateRoot $provNoRemoteRoot
	if ($LASTEXITCODE -ne 0) { throw 'Could not create the no-remote provenance fixture.' }
	& git -C $provNoRemoteRoot remote remove origin
	if ($LASTEXITCODE -ne 0) { throw 'Could not remove the origin of the no-remote provenance fixture.' }
	[System.IO.Directory]::CreateDirectory((Join-Path $provNoRemoteRoot 'Production')) | Out-Null
	$provNoRemoteGenerator = Join-Path $provNoRemoteRoot 'scripts\New-UETemplateScaffold.ps1'
	$provNoRemoteName = "Nor_$testId"
	$provNoRemoteDefaultOutput = Join-Path (Join-Path $provNoRemoteRoot 'Production') "${provNoRemoteName}_$testId-default"
	$provNoRemoteFailure = ''
	try {
		& $provNoRemoteGenerator -Recipe 'spectator-explore' -ProjectName $provNoRemoteName -RunId "$testId-default" -EngineRoot $fixtureEngine -ProjectDiff @() | Out-Null
	} catch {
		$provNoRemoteFailure = $_.Exception.Message
	}
	Assert-True ($provNoRemoteFailure.Contains("has no 'origin' remote")) 'a checkout without an origin stops the default path'
	Assert-True (($provNoRemoteFailure.Contains('no-remote') -or $provNoRemoteFailure.Contains('no-origin'))) 'the no-remote stop reports which source kind it saw'
	Assert-True (-not (Test-Path -LiteralPath $provNoRemoteDefaultOutput)) 'the no-remote stop writes no project'
	$provNoRemoteAllowedOutput = Join-Path (Join-Path $provNoRemoteRoot 'Production') "${provNoRemoteName}_$testId-allowed"
	& $provNoRemoteGenerator -Recipe 'spectator-explore' -ProjectName $provNoRemoteName -RunId "$testId-allowed" -EngineRoot $fixtureEngine -ProjectDiff @() -AllowUnpublishedTemplate | Out-Null
	$provNoRemoteLock = Get-LockProvenance $provNoRemoteAllowedOutput
	Assert-True ($null -ne $provNoRemoteLock.PSObject.Properties['template_repository']) 'a checkout without an origin still declares template_repository'
	Assert-True ($null -eq $provNoRemoteLock.template_repository) 'a checkout without an origin records no repository instead of the public repository constant'
	Assert-True ($provNoRemoteLock.template_source_kind -ceq 'no-remote') 'a checkout without an origin records the no-remote source kind'
	Assert-True ($null -eq $provNoRemoteLock.template_commit_published) 'an unprobeable commit is recorded as null and not as published'
	Write-Output 'PASS: a checkout without a remote records no repository and an unverified publication state'

	# (d) offline bundle clone: the lock must identify the bundle as the source, never the public repository.
	$provBundle = Join-Path $provenanceRoot 'prov-template.bundle'
	& git -C $provTemplateRoot bundle create --quiet $provBundle --all
	if ($LASTEXITCODE -ne 0) { throw 'Could not create the provenance bundle fixture.' }
	$provBundleClone = Join-Path $provenanceRoot 'ProvBundleClone'
	& git clone --quiet $provBundle $provBundleClone
	if ($LASTEXITCODE -ne 0) { throw 'Could not clone the provenance bundle fixture.' }
	[System.IO.File]::AppendAllText((Join-Path $provBundleClone 'PROVENANCE-BUNDLE.txt'), "offline change`n", [System.Text.UTF8Encoding]::new($false))
	$provBundleRevision = Update-FixtureRepository -RepositoryRoot $provBundleClone -Message 'provenance fixture offline head'
	[System.IO.Directory]::CreateDirectory((Join-Path $provBundleClone 'Production')) | Out-Null
	$provBundleGenerator = Join-Path $provBundleClone 'scripts\New-UETemplateScaffold.ps1'
	$provBundleName = "Bun_$testId"
	$provBundleDefaultOutput = Join-Path (Join-Path $provBundleClone 'Production') "${provBundleName}_$testId-default"
	$provBundleFailure = ''
	try {
		& $provBundleGenerator -Recipe 'spectator-explore' -ProjectName $provBundleName -RunId "$testId-default" -EngineRoot $fixtureEngine -ProjectDiff @() | Out-Null
	} catch {
		$provBundleFailure = $_.Exception.Message
	}
	Assert-True ($provBundleFailure.Contains('offline hand-off file')) 'a bundle clone stops the default path because a bundle cannot establish a published commit'
	Assert-True (-not (Test-Path -LiteralPath $provBundleDefaultOutput)) 'the bundle stop writes no project'
	$provBundleAllowedOutput = Join-Path (Join-Path $provBundleClone 'Production') "${provBundleName}_$testId-allowed"
	& $provBundleGenerator -Recipe 'spectator-explore' -ProjectName $provBundleName -RunId "$testId-allowed" -EngineRoot $fixtureEngine -ProjectDiff @() -AllowUnpublishedTemplate | Out-Null
	$provBundleLock = Get-LockProvenance $provBundleAllowedOutput
	Assert-True ($provBundleLock.template_source_kind -ceq 'bundle') 'a bundle clone records the bundle source kind'
	Assert-True ($provBundleLock.template_repository -ceq $provBundle) 'a bundle clone records the bundle path instead of the public repository'
	Assert-True ($provBundleLock.template_repository -cne 'https://github.com/eiei114/ue5-agent-template') 'a bundle clone does not claim the public repository'
	Assert-True ($provBundleLock.template_commit -ceq $provBundleRevision) 'a bundle clone records its own head'
	Assert-True ($null -eq $provBundleLock.template_commit_published) 'an offline bundle cannot establish publication, so the state stays null'
	Write-Output 'PASS: an offline bundle clone is recorded as a bundle with an unverified publication state'

	$projectName = $projectPrefix
	$diff = @('Map: /Game/Test/Maps/L_Set', 'Exposure: capture preset A')
	Invoke-Generator 'spectator-explore' $projectName "$testId-a" $diff
	Invoke-Generator 'spectator-explore' $projectName "$testId-b" @($diff[1], $diff[0])
	Invoke-Generator 'spectator-explore' $otherProjectName "$testId-c" $diff
	$firstOutput = $outputPaths[0]
	$secondOutput = $outputPaths[1]
	$otherOutput = $outputPaths[5]
	Assert-True (Test-Path -LiteralPath (Join-Path $firstOutput 'TP_FirstPerson.uproject')) 'game recipe copies the selected engine project template'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $firstOutput "$projectName.uproject"))) 'generated project file does not advertise a project name the template does not use'
	$firstDescriptor = [System.IO.File]::ReadAllText((Join-Path $firstOutput 'TP_FirstPerson.uproject')) | ConvertFrom-Json
	Assert-True (@($firstDescriptor.Modules).Count -eq 1 -and $firstDescriptor.Modules[0].Name -eq 'TP_FirstPerson') 'generated project descriptor keeps the template module identity'
	Assert-True (-not [string]::IsNullOrWhiteSpace([string]$firstDescriptor.EngineAssociation)) 'generated project descriptor has a non-empty EngineAssociation'
	Assert-True ([string]$firstDescriptor.EngineAssociation -eq '5.8') 'generated EngineAssociation is derived from the installed Build.version'
	foreach ($pluginName in @('MovieRenderPipeline', 'OnlineSubsystem', 'OnlineSubsystemNull', 'OnlineSubsystemUtils', 'MulticaOnlineStarter')) {
		$pluginEntries = @($firstDescriptor.Plugins | Where-Object { $_.Name -eq $pluginName })
		Assert-True ($pluginEntries.Count -eq 1 -and $pluginEntries[0].Enabled -eq $true) "game recipe enables $pluginName in the project descriptor"
	}
	Assert-True (Test-Path -LiteralPath (Join-Path $firstOutput 'Plugins\MulticaOnlineStarter\MulticaOnlineStarter.uplugin')) 'game recipe includes the Null/LAN plugin'
	$starterDescriptor = [System.IO.File]::ReadAllText((Join-Path $firstOutput 'Plugins\MulticaOnlineStarter\MulticaOnlineStarter.uplugin')) | ConvertFrom-Json
	$nullPluginEntries = @($starterDescriptor.Plugins | Where-Object { $_.Name -eq 'OnlineSubsystemNull' })
	Assert-True ($nullPluginEntries.Count -eq 1 -and $nullPluginEntries[0].Enabled -eq $true) 'online starter plugin enables OnlineSubsystemNull'
	$pluginDirectory = Join-Path $firstOutput 'Plugins\MulticaOnlineStarter'
	$projectConfigPath = Join-Path $firstOutput 'Config\DefaultEngine.ini'
	# The provider switch has to sit in a carrier whose file name the engine resolves to a branch.
	# Check the name, not the bytes: a stale assertion that only grep'd the file body passed while
	# the declared provider was thrown away by the loader (DOT-3187).
	$projectCarrierProblem = Get-ProjectConfigCarrierProblem -Path $projectConfigPath
	Assert-True ([string]::IsNullOrEmpty($projectCarrierProblem)) ('generated project config carrier resolves to an engine branch: ' + $projectCarrierProblem)
	Assert-True (Test-Path -LiteralPath $projectConfigPath -PathType Leaf) 'game recipe writes the project config carrier the scaffold appends to'
	$mismatchedCarrierProblem = Get-ProjectConfigCarrierProblem -Path (Join-Path $fixtureRoot 'MismatchedProjectCarrier\Config\Engine.ini')
	Assert-True (-not [string]::IsNullOrEmpty($mismatchedCarrierProblem)) 'a project carrier named Engine.ini instead of DefaultEngine.ini is rejected'
	$pluginConfigProblems = @(Get-PluginConfigCarrierProblems -PluginDirectory $pluginDirectory -PluginName 'MulticaOnlineStarter' -PlatformName 'Windows')
	Assert-True ($pluginConfigProblems.Count -eq 0) ('online plugin ships no config file the engine would silently drop: ' + ($pluginConfigProblems -join '; '))
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $pluginDirectory 'Config\DefaultEngine.ini'))) 'online plugin does not ship Config/DefaultEngine.ini, which the engine resolves to the unknown DefaultEngine branch'
	$pluginConfig = [System.IO.File]::ReadAllText($projectConfigPath)
	Assert-True ($pluginConfig.Contains('DefaultPlatformService=Null')) 'generated project config carrier selects the Null provider'
	$expectedSessionIdentifier = "eiei114.ue5-agent-template:$projectName"
	$otherSessionIdentifier = "eiei114.ue5-agent-template:$otherProjectName"
	Assert-True ($pluginConfig.Contains("SessionProjectIdentifier=$expectedSessionIdentifier")) 'generated project config carries the requested stable project key'
	# The raw-copy path keeps the template's own GameMode line (the fixture mirrors the installed
	# TP_FirstPerson config), so the check is that the template value survives unchanged and that the
	# scaffold appends no second override of its own.
	Assert-True ($pluginConfig.Contains('GlobalDefaultGameMode') -eq $true) 'raw copy keeps the template default GameMode line'
	$gameModeLineCount = ([regex]::Matches($pluginConfig, '(?m)^GlobalDefaultGameMode=')).Count
	Assert-True ($gameModeLineCount -eq 1) 'the generator does not add a second template-specific GameMode override'
	# Negative case: a carrier named so the engine cannot resolve it must be reported. This is the
	# defect this issue records: a body-only assertion stayed green while the declared provider was
	# thrown away by the loader, because the file name never mapped to a branch.
	$unresolvableCarrierRoot = Join-Path $fixtureRoot 'UnresolvableCarrierPlugin'
	Write-FixtureJson (Join-Path $unresolvableCarrierRoot 'Config\DefaultEngine.ini') "[OnlineSubsystem]`r`nDefaultPlatformService=Null`r`n"
	$unresolvableCarrierProblems = @(Get-PluginConfigCarrierProblems -PluginDirectory $unresolvableCarrierRoot -PluginName 'MulticaOnlineStarter' -PlatformName 'Windows')
	Assert-True ($unresolvableCarrierProblems.Count -eq 1) 'a plugin carrier the engine cannot resolve is reported instead of passing on file content'
	Assert-True ($unresolvableCarrierProblems[0].Contains('DefaultEngine.ini')) 'the carrier check names the file the engine drops'
	$resolvableCarrierRoot = Join-Path $fixtureRoot 'ResolvableCarrierPlugin'
	Write-FixtureJson (Join-Path $resolvableCarrierRoot 'Config\Engine.ini') "[OnlineSubsystem]`r`nDefaultPlatformService=Null`r`n"
	Write-FixtureJson (Join-Path $resolvableCarrierRoot 'Config\DefaultMulticaOnlineStarter.ini') "[MulticaOnlineStarter]`r`n"
	Write-FixtureJson (Join-Path $resolvableCarrierRoot 'Config\Windows\WindowsEngine.ini') "[OnlineSubsystem]`r`n"
	Assert-True (@(Get-PluginConfigCarrierProblems -PluginDirectory $resolvableCarrierRoot -PluginName 'MulticaOnlineStarter' -PlatformName 'Windows').Count -eq 0) 'Config/Engine.ini, Config/Default<PluginName>.ini and Config/Windows/WindowsEngine.ini resolve to engine branches'
	Write-Output 'PASS: plugin config carriers are checked by resolved branch name, not by file content'
	$generatedPlayPath = Join-Path $firstOutput 'Recipe\Play.md'
	Assert-True (Test-Path -LiteralPath $generatedPlayPath) 'game recipe has a play delta'
	$generatedPlay = [System.IO.File]::ReadAllText($generatedPlayPath)
	Assert-True ($generatedPlay.Contains('docs/08-online-foundations.md')) 'generated play delta points to the packaged online foundations guide'
	$onlineGuidePath = Join-Path $firstOutput 'docs\08-online-foundations.md'
	Assert-True (Test-Path -LiteralPath $onlineGuidePath) 'game recipe includes the online foundations guide referenced by its play delta'
	Assert-True ([System.IO.File]::ReadAllText($onlineGuidePath) -ceq [System.IO.File]::ReadAllText((Join-Path $repoRoot 'docs\08-online-foundations.md'))) 'generated online foundations guide matches the repository source'
	Assert-True (Test-Path -LiteralPath (Join-Path $firstOutput 'Recipe\Capture.md')) 'game recipe has a capture delta'
	Assert-True (Test-Path -LiteralPath (Join-Path $firstOutput 'Recipe\SET.md')) 'game recipe has exactly one shared set contract'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $firstOutput 'SyntheticAsset.uasset'))) 'generator does not fabricate Unreal assets'
	$firstLock = [System.IO.File]::ReadAllText((Join-Path $firstOutput 'template-lock.json'))
	$secondLock = [System.IO.File]::ReadAllText((Join-Path $secondOutput 'template-lock.json'))
	Assert-True ($firstLock -ceq $secondLock) 'identical dependencies and differences reproduce the same lock record in the same shell'
	# A lock compared across hosts or shells must be compared as JSON fields, not as bytes:
	# `ConvertTo-Json` formats differently per shell (4-space + '":  "' vs 2-space + '": "'), so the
	# same record has two different sha256 values. The semantic comparison is the contract that holds
	# across shells; this assertion fails if a future change makes two equivalent records differ in
	# a way JSON parsing cannot absorb.
	$firstSemantic = ConvertTo-Json -InputObject ($firstLock | ConvertFrom-Json) -Depth 12 -Compress
	$secondSemantic = ConvertTo-Json -InputObject ($secondLock | ConvertFrom-Json) -Depth 12 -Compress
	Assert-True ($firstSemantic -ceq $secondSemantic) 'records that differ only in formatting compare equal as parsed JSON'
	# Reformatting the same record (colon spacing, newline style) must not change its parsed value: that
	# is exactly the difference two shells introduce, so a byte-based comparison would report a false
	# mismatch while the field comparison holds.
	$reformattedLock = ($firstLock -replace '":  "', '": "') -replace "`r`n", "`n"
	Assert-True ($reformattedLock -cne $firstLock) 'the whitespace variation this assertion covers is a real byte difference'
	Assert-True ((ConvertTo-Json -InputObject ($reformattedLock | ConvertFrom-Json) -Depth 12 -Compress) -ceq $firstSemantic) 'a lock re-serialized with different whitespace keeps the same parsed value'
	$lockData = $firstLock | ConvertFrom-Json
	Assert-True ($lockData.engine_version -eq '5.8.4') 'lock records the installed engine version'
	Assert-True ($lockData.template_commit -ceq $templateRevision) 'lock records the template checkout HEAD instead of an arbitrary 40-digit string'
	# The regression groups above run with -SkipTemplatePublishCheck, so the recorded publication state
	# has to be an explicit null. A `true` here would mean the check was never skipped (or that a null
	# was read as published), and the provenance group below covers the measured states.
	Assert-True ($null -ne $lockData.PSObject.Properties['template_commit_published']) 'the lock declares template_commit_published instead of omitting the field'
	Assert-True ($null -eq $lockData.template_commit_published) 'a skipped publication probe is recorded as null, never as published'
	Assert-True ($lockData.plugins.MulticaOnlineStarter -eq '1.0.1') 'lock records the project plugin version'
	Assert-True ($lockData.project_differences.Count -eq 2) 'lock records normalized project-specific differences'
	Assert-True ($lockData.schema_version -ge 4) 'lock declares at least the template-provenance schema version'
	Assert-True ($lockData.engine_changelist -eq 55116800) 'lock records the effective changelist UE derives from CompatibleChangelist'
	Assert-True ($lockData.engine_changelist_source -eq 'CompatibleChangelist') 'lock names CompatibleChangelist as the effective changelist source'
	Assert-True ($lockData.engine_changelist_raw -eq 58902052) 'lock keeps the raw Changelist exactly as the engine reported it'
	Assert-True ($lockData.engine_compatible_changelist -eq 55116800) 'lock records CompatibleChangelist'
	Assert-True ($lockData.engine_is_licensee_version -eq 0) 'lock records IsLicenseeVersion'
	Assert-True ($lockData.engine_is_promoted_build -eq 1) 'lock records IsPromotedBuild'
	Assert-True ($lockData.engine_branch_name -eq '++UE5+Release-5.8') 'lock records BranchName'
	Assert-True ($lockData.identity.project_file -eq 'TP_FirstPerson.uproject') 'lock records the generated project file name'
	Assert-True (@($lockData.identity.project_modules) -join ',' -eq 'TP_FirstPerson') 'lock records the generated project module identity'
	Assert-True ($lockData.identity.engine_association -eq '5.8') 'lock records the generated engine association'
	Assert-True ($lockData.online_session_identifier -ceq $expectedSessionIdentifier) 'lock records the same session identifier as the effective plugin config'
	$secondLockData = $secondLock | ConvertFrom-Json
	Assert-True ($secondLockData.online_session_identifier -ceq $expectedSessionIdentifier) 'copies of the same project keep a stable session identifier across run IDs'
	$otherPluginConfig = [System.IO.File]::ReadAllText((Join-Path $otherOutput 'Config\DefaultEngine.ini'))
	$otherLockData = [System.IO.File]::ReadAllText((Join-Path $otherOutput 'template-lock.json')) | ConvertFrom-Json
	Assert-True ($otherPluginConfig.Contains("SessionProjectIdentifier=$otherSessionIdentifier")) 'a different project name writes its own effective session identifier'
	Assert-True ($otherLockData.online_session_identifier -ceq $otherSessionIdentifier -and $otherSessionIdentifier -cne $expectedSessionIdentifier) 'different project names produce different lock identifiers'
	# The raw-copy path must honour the template's own Config/TemplateDefs.ini. Without it the project
	# opens on a default map whose shared packs (Characters / LevelPrototyping / Input) are absent while
	# the generator still prints success, and the template-only Media/ thumbnails plus TemplateDefs.ini
	# itself leak into the output.
	foreach ($packName in @('Characters', 'LevelPrototyping', 'Input')) {
		Assert-True (Test-Path -LiteralPath (Join-Path $firstOutput "Content\$packName") -PathType Container) "raw copy installs the declared shared content pack $packName"
	}
	Assert-True (Test-Path -LiteralPath (Join-Path $firstOutput 'Content\Characters\Mannequins\Meshes\SK_Mannequin.uasset') -PathType Leaf) 'raw copy installs the pack payload under Content/<Mount>'
	Assert-True (Test-Path -LiteralPath (Join-Path $firstOutput 'Content\LevelPrototyping\Meshes\SM_Cube.uasset') -PathType Leaf) 'raw copy installs the LevelPrototyping pack'
	Assert-True (Test-Path -LiteralPath (Join-Path $firstOutput 'Content\Input\Actions\IA_Jump.uasset') -PathType Leaf) 'raw copy installs the Input pack'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $firstOutput 'Media'))) 'raw copy honours FoldersToIgnore for Media'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $firstOutput 'Config\TemplateDefs.ini'))) 'raw copy honours FilesToIgnore for Config/TemplateDefs.ini'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $firstOutput 'Config\config.ini'))) 'raw copy honours FilesToIgnore for Config/config.ini'
	Assert-True (Test-Path -LiteralPath (Join-Path $firstOutput 'Content\FirstPerson\Lvl_FirstPerson.umap')) 'the raw-copied project contains the map its own config opens'
	Assert-True (@($lockData.shared_content_packs) -join ',' -ceq 'Characters,LevelPrototyping,Input') 'lock records the shared content packs copied into the project'
	Assert-True ($lockData.shared_content_pack_detail_levels.Characters -ceq 'High' -and $lockData.shared_content_pack_detail_levels.Input -ceq 'High') 'lock records the detail level each pack was mounted from'
	Assert-True ($lockData.template_defs_ignore_rules.folders_to_ignore -eq 1) 'lock records how many folder ignore rules the template declared'
	Assert-True ($lockData.template_defs_ignore_rules.files_to_ignore -eq 4) 'lock records how many file ignore rules the template declared'
	$otherLockPacks = @($otherLockData.shared_content_packs) -join ','
	Assert-True ($otherLockPacks -ceq 'Characters,LevelPrototyping,Input') 'the pack list does not depend on the project name'
	Write-Output 'PASS: raw-copy recipe applies TemplateDefs.ini ignore rules and mounts shared content packs'
	Write-Output 'PASS: game+capture recipe, official template copy, online plugin, and deterministic lock'

	Invoke-Generator 'vertical-loop' $loopProjectName "$testId-a" @('capture: 1080x1920')
	$loopOutput = $outputPaths[2]
	Assert-True (Test-Path -LiteralPath (Join-Path $loopOutput 'TP_BlankBP.uproject')) 'video-only recipe copies the blank engine template'
	$loopDescriptor = [System.IO.File]::ReadAllText((Join-Path $loopOutput 'TP_BlankBP.uproject')) | ConvertFrom-Json
	Assert-True (@($loopDescriptor.Modules).Count -eq 1 -and $loopDescriptor.Modules[0].Name -eq 'TP_BlankBP') 'video-only recipe keeps the template module identity'
	Assert-True ([string]$loopDescriptor.EngineAssociation -eq '5.8') 'video-only recipe writes a derived EngineAssociation'
	$loopLock = [System.IO.File]::ReadAllText((Join-Path $loopOutput 'template-lock.json')) | ConvertFrom-Json
	Assert-True ($loopLock.engine_changelist -eq 55116800) 'video-only lock records the effective engine changelist'
	Assert-True ($loopLock.identity.project_file -eq 'TP_BlankBP.uproject') 'video-only lock records the generated project file name'
	Assert-True ($loopLock.identity.engine_association -eq '5.8') 'video-only lock records the engine association'
	$movieRenderPlugins = @($loopDescriptor.Plugins | Where-Object { $_.Name -eq 'MovieRenderPipeline' })
	Assert-True ($movieRenderPlugins.Count -eq 1 -and $movieRenderPlugins[0].Enabled -eq $true) 'video-only recipe enables MovieRenderPipeline in the project descriptor'
	Assert-True (Test-Path -LiteralPath (Join-Path $loopOutput 'Recipe\Capture.md')) 'video-only recipe has capture instructions'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $loopOutput 'Recipe\Play.md'))) 'video-only recipe does not add a play delta'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $loopOutput 'Plugins\MulticaOnlineStarter'))) 'video-only recipe does not add online gameplay code'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $loopOutput 'Media'))) 'video-only recipe honours the blank template FoldersToIgnore for Media'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $loopOutput 'Config\TemplateDefs.ini'))) 'video-only recipe honours the blank template FilesToIgnore'
	Assert-True (@($loopLock.shared_content_packs).Count -eq 0) 'a template without SharedContentPacks records an empty pack list instead of an invented one'
	Write-Output 'PASS: capture-only vertical-loop recipe'

	$tpName = "Tp_$testId"
	Invoke-Generator 'third-person-game' $tpName "$testId-a" @('Variant: Combat')
	$tpOutput = $outputPaths[4]
	Assert-True (Test-Path -LiteralPath (Join-Path $tpOutput "$tpName.uproject")) 'materialized recipe writes <ProjectName>.uproject'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $tpOutput 'TP_ThirdPerson.uproject'))) 'materialized recipe does not keep the template project file name'
	$tpDescriptor = [System.IO.File]::ReadAllText((Join-Path $tpOutput "$tpName.uproject")) | ConvertFrom-Json
	Assert-True ($tpDescriptor.Modules[0].Name -ceq $tpName) 'materialized recipe renames the C++ module'
	Assert-True ($tpDescriptor.EngineAssociation -eq '5.8') 'materialized recipe associates the installed engine version'
	$buildCs = Join-Path $tpOutput "Source\$tpName\$tpName.Build.cs"
	Assert-True (Test-Path -LiteralPath $buildCs) 'materialized recipe renames the source folder and file names'
	$buildText = [System.IO.File]::ReadAllText($buildCs)
	Assert-True ($buildText.Contains("class $tpName ") -and $buildText.Contains($tpName.ToUpperInvariant() + '_API') -and $buildText.Contains($tpName.ToLowerInvariant()) -and -not $buildText.Contains('TP_ThirdPerson')) 'materialized recipe replaces template names in source text with case rules'
	Assert-True ([System.IO.File]::ReadAllText((Join-Path $tpOutput "Source\$tpName.Target.cs")).Contains("`"$tpName`"")) 'materialized recipe renames target files'
	Assert-True ([System.IO.File]::ReadAllText((Join-Path $tpOutput 'Content\ThirdPerson\Lvl_ThirdPerson.umap')) -ceq 'binary TP_ThirdPerson') 'materialized recipe copies binary content unchanged'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $tpOutput 'Content\ThirdPerson\Animations'))) 'materialized recipe honors FoldersToIgnore'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $tpOutput 'Media'))) 'materialized recipe skips Media'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $tpOutput 'Config\TemplateDefs.ini'))) 'materialized recipe honors FilesToIgnore'
	Assert-True (Test-Path -LiteralPath (Join-Path $tpOutput 'Content\Characters\Mannequins\SK.uasset')) 'materialized recipe installs shared content packs'
	$tpEngineIni = [System.IO.File]::ReadAllText((Join-Path $tpOutput 'Config\DefaultEngine.ini'))
	Assert-True ($tpEngineIni.Contains("+PackageRedirects=(OldName=`"/Script/TP_ThirdPerson`",NewName=`"/Script/$tpName`")")) 'materialized recipe redirects template Blueprints to the new module'
	# The wizard writes +ActiveClassRedirects for every renamed UObject header; without them the
	# renamed classes keep an unreachable old name inside the byte-copied Blueprints.
	$classRedirectMatches = [regex]::Matches($tpEngineIni, '(?m)^\+ActiveClassRedirects=\(OldClassName="([^"]+)",NewClassName="([^"]+)"\)[ \t]*\r?$')
	$classRedirectPairs = @{}
	foreach ($match in $classRedirectMatches) { $classRedirectPairs[$match.Groups[1].Value] = $match.Groups[2].Value }
	Assert-True ($classRedirectMatches.Count -eq 3) 'materialized recipe writes exactly one class redirect per renamed reflected class'
	foreach ($reflectedClass in @('Character', 'GameMode', 'PlayerController')) {
		$oldClassName = "TP_ThirdPerson$reflectedClass"
		$newClassName = "${tpName}$reflectedClass"
		Assert-True ($classRedirectPairs.ContainsKey($oldClassName) -and $classRedirectPairs[$oldClassName] -ceq $newClassName) "class redirect maps $oldClassName to the generated class name"
	}
	Assert-True (-not $classRedirectPairs.ContainsKey('TP_ThirdPerson')) 'a renamed header without the UHT include produces no class redirect'
	Assert-True (-not $classRedirectPairs.ContainsKey('CombatEnemy')) 'a reflected header whose file name does not change produces no class redirect'
	$engineSectionIndex = $tpEngineIni.IndexOf('[/Script/Engine.Engine]', [System.StringComparison]::Ordinal)
	$firstClassRedirectIndex = $tpEngineIni.IndexOf('+ActiveClassRedirects=', [System.StringComparison]::Ordinal)
	$coreRedirectsIndex = $tpEngineIni.IndexOf('[CoreRedirects]', [System.StringComparison]::Ordinal)
	Assert-True ($engineSectionIndex -ge 0 -and $firstClassRedirectIndex -gt $engineSectionIndex) 'class redirects live in [/Script/Engine.Engine] like the wizard writes them'
	Assert-True ($coreRedirectsIndex -gt $firstClassRedirectIndex) 'the package redirect section is appended after the class redirects, not replaced'
	$materializedStdout = & $generator -Recipe 'third-person-game' -ProjectName "Sz_$testId" -RunId "$testId-a" -EngineRoot $fixtureEngine -ProjectDiff @() -AllowDirtyTemplate
	$sizeOutput = $outputPaths[6]
	Assert-True (($materializedStdout -join "`n") -match '(?m)^Class redirects: TP_ThirdPersonCharacter -> Sz_') 'the generator reports the class redirects it wrote'
	Assert-True (Test-Path -LiteralPath (Join-Path $sizeOutput 'Config\DefaultEngine.ini')) 'the reporting generator wrote its output'
	$tpGameIni = [System.IO.File]::ReadAllText((Join-Path $tpOutput 'Config\DefaultGame.ini'))
	Assert-True ($tpGameIni.Contains("ProjectName=$tpName") -and -not $tpGameIni.Contains('ProjectID=(A=1,B=2,C=3,D=4)')) 'materialized recipe gives the project its own name and ID'
	Assert-True (Test-Path -LiteralPath (Join-Path $tpOutput 'Recipe\Play.md')) 'third-person recipe has a play delta'
	Assert-True ((([System.IO.File]::ReadAllText((Join-Path $tpOutput 'template-lock.json'))) | ConvertFrom-Json).engine_template -eq 'TP_ThirdPerson') 'lock records the third-person engine template'
	Assert-GeneratorFails { Invoke-Generator 'third-person-game' 'Bad-Name' "$testId-bad" @() } 'materialized recipe rejects non-identifier project names'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $productionRoot "Bad-Name_$testId-bad"))) 'invalid materialized project name creates no output'
	Write-Output 'PASS: third-person recipe materializes the official template like the New Project wizard'

	Assert-GeneratorFails { Invoke-Generator 'spectator-explore' "..\escape_$testId" 'path-test' @() } 'path traversal project name is rejected'
	Assert-GeneratorFails { Invoke-Generator 'spectator-explore' "TestExplore_$testId" '..\escape' @() } 'path traversal run ID is rejected'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $productionRoot "escape_$testId"))) 'path traversal did not create an out-of-scope directory'
	Write-Output 'PASS: path traversal rejected before output creation'

	# Recipe layer group (DOT-3118): the selectable recipes are data. The suite proves this by adding
	# and breaking recipe directories in an isolated clone of the committed template, so the checked-in
	# recipes stay untouched and the checkout-unchanged gate keeps its meaning.
	$recipeRepo = New-FixtureRepository 'RecipeLayer' $templateRevision
	$recipeRepoProduction = Join-Path $recipeRepo 'Production'
	$fixtureGenre = 'Fixture-Genre'
	$fixtureCapture = 'fixture-capture'
	Write-FixtureRecipe (Join-Path $recipeRepo "templates\recipes\$fixtureGenre") $fixtureGenre 'game-and-capture' @('MovieRenderPipeline', 'MulticaOnlineStarter') 'TP_FirstPerson' $true $true
	Write-FixtureRecipe (Join-Path $recipeRepo "templates\recipes\$fixtureCapture") $fixtureCapture 'capture-only' @('MovieRenderPipeline') 'TP_FirstPerson' $true $false
	$genreName = "Rx_$testId"
	$genreRun = "$testId-genre"
	$captureName = "Rc_$testId"
	$captureRun = "$testId-capture"
	$genreOutput = Join-Path $recipeRepoProduction "${genreName}_$genreRun"
	$captureOutput = Join-Path $recipeRepoProduction "${captureName}_$captureRun"
	Invoke-RepositoryGenerator $recipeRepo $fixtureGenre $genreName $genreRun @('Layer: added genre recipe')
	Invoke-RepositoryGenerator $recipeRepo $fixtureCapture $captureName $captureRun @('Layer: added capture-only recipe')
	Assert-True (Test-Path -LiteralPath (Join-Path $genreOutput 'Recipe\Play.md')) 'a recipe directory added without touching the generator generates a project and ships its own play delta'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $captureOutput 'Recipe\Play.md'))) 'a recipe directory without Play.md generates a project without a play delta'
	Assert-True (Test-Path -LiteralPath (Join-Path $genreOutput 'Plugins\MulticaOnlineStarter\MulticaOnlineStarter.uplugin')) 'declaring MulticaOnlineStarter in required_plugins ships the plugin payload'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $captureOutput 'Plugins\MulticaOnlineStarter'))) 'not declaring MulticaOnlineStarter ships no plugin payload'
	$genreLock = [System.IO.File]::ReadAllText((Join-Path $genreOutput 'template-lock.json')) | ConvertFrom-Json
	$captureLock = [System.IO.File]::ReadAllText((Join-Path $captureOutput 'template-lock.json')) | ConvertFrom-Json
	Assert-True ($genreLock.recipe -ceq $fixtureGenre) 'lock records the recipe directory that was actually synthesized'
	Assert-True ($genreLock.purpose -ceq 'game-and-capture') 'lock records the purpose the recipe declares'
	Assert-True (@($genreLock.plugins.PSObject.Properties).Count -eq 2 -and $genreLock.plugins.MulticaOnlineStarter -eq '1.0.1') 'lock records every declared plugin version'
	Assert-True ($captureLock.recipe -ceq $fixtureCapture -and @($captureLock.plugins.PSObject.Properties).Count -eq 1) 'a capture-only fixture recipe locks only its one declared plugin'
	Assert-True ($captureLock.online_session_identifier -eq $null) 'a recipe without the online plugin records no session identifier'
	$genreDescriptor = [System.IO.File]::ReadAllText((Join-Path $genreOutput 'TP_FirstPerson.uproject')) | ConvertFrom-Json
	Assert-True (@($genreDescriptor.Plugins | Where-Object { $_.Name -eq 'MulticaOnlineStarter' }).Count -eq 1) 'the project descriptor enables exactly the plugins the recipe declares'
	Write-Output 'PASS: a recipe directory added on its own generates a project, and Play.md / required_plugins drive the composition'

	# Same declared data, different purpose: the purpose is recorded in the lock and in the copied
	# recipe.json only. Composition (file set, plugins, play delta) must not move, so an agent cannot
	# get two different project trees for the same dependency set. Two generated files are expected to
	# differ and are excluded from the byte comparison by name: `Recipe/recipe.json` (the recipe data is
	# copied verbatim, so its `purpose` field differs) and `template-lock.json` (records the purpose).
	# Everything else, including the file set itself, is compared byte-for-byte.
	$purposeOutput = Join-Path $recipeRepoProduction "${captureName}_$testId-purpose"
	$purposeRecipePath = Join-Path $recipeRepo "templates\recipes\$fixtureCapture\recipe.json"
	$purposeData = [System.IO.File]::ReadAllText($purposeRecipePath) | ConvertFrom-Json
	$purposeData.purpose = 'game-and-capture'
	Write-FixtureJson $purposeRecipePath (ConvertTo-Json -InputObject $purposeData -Depth 10)
	Invoke-RepositoryGenerator $recipeRepo $fixtureCapture $captureName "$testId-purpose" @('Layer: purpose only')
	$purposeExpectedDifferences = @('Recipe/recipe.json', 'template-lock.json')
	$captureFiles = @(Get-ChildItem -LiteralPath $captureOutput -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($captureOutput.Length + 1).Replace('\', '/') } | Sort-Object)
	$purposeFiles = @(Get-ChildItem -LiteralPath $purposeOutput -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($purposeOutput.Length + 1).Replace('\', '/') } | Sort-Object)
	Assert-True (($captureFiles -join ',') -ceq ($purposeFiles -join ',')) 'changing only purpose leaves the generated file set (composition) identical'
	$compositionFiles = @($captureFiles | Where-Object { $purposeExpectedDifferences -notcontains $_ })
	Assert-True ($compositionFiles.Count -eq ($captureFiles.Count - $purposeExpectedDifferences.Count)) 'only the two documented files carry the purpose change'
	foreach ($relative in $compositionFiles) {
		$captureHash = (Get-FileHash -LiteralPath (Join-Path $captureOutput $relative) -Algorithm SHA256).Hash
		$purposeHash = (Get-FileHash -LiteralPath (Join-Path $purposeOutput $relative) -Algorithm SHA256).Hash
		Assert-True ($captureHash -ceq $purposeHash) "changing only purpose leaves the composition file $relative byte-identical"
	}
	foreach ($relative in $purposeExpectedDifferences) {
		Assert-True ((Get-FileHash -LiteralPath (Join-Path $captureOutput $relative) -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath (Join-Path $purposeOutput $relative) -Algorithm SHA256).Hash) "changing only purpose does change $relative, as documented"
	}
	$purposeCopiedRecipe = [System.IO.File]::ReadAllText((Join-Path $purposeOutput 'Recipe\recipe.json')) | ConvertFrom-Json
	Assert-True ($purposeCopiedRecipe.purpose -ceq 'game-and-capture') 'the copied Recipe/recipe.json carries the edited purpose verbatim'
	$purposeLock = [System.IO.File]::ReadAllText((Join-Path $purposeOutput 'template-lock.json')) | ConvertFrom-Json
	Assert-True ($purposeLock.purpose -ceq 'game-and-capture' -and $captureLock.purpose -ceq 'capture-only') 'the differing purpose is visible in the lock'
	Write-Output 'PASS: purpose does not change composition; only the lock purpose and the copied recipe.json change'

	# required_plugins is the single truth for the plugin payload: removing the online plugin from an
	# existing recipe must remove Plugins/, the descriptor entry and the lock entry together.
	$recipeJsonPath = Join-Path $recipeRepo 'templates\recipes\spectator-explore\recipe.json'
	$spectatorData = [System.IO.File]::ReadAllText($recipeJsonPath) | ConvertFrom-Json
	$spectatorData.required_plugins = @($spectatorData.required_plugins | Where-Object { $_ -ne 'MulticaOnlineStarter' })
	Write-FixtureJson $recipeJsonPath (ConvertTo-Json -InputObject $spectatorData -Depth 10)
	$noOnlineName = "Rn_$testId"
	$noOnlineRun = "$testId-no-online"
	$noOnlineOutput = Join-Path $recipeRepoProduction "${noOnlineName}_$noOnlineRun"
	Invoke-RepositoryGenerator $recipeRepo 'spectator-explore' $noOnlineName $noOnlineRun @('Layer: plugin removed')
	$noOnlineLock = [System.IO.File]::ReadAllText((Join-Path $noOnlineOutput 'template-lock.json')) | ConvertFrom-Json
	$noOnlineDescriptor = [System.IO.File]::ReadAllText((Join-Path $noOnlineOutput 'TP_FirstPerson.uproject')) | ConvertFrom-Json
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $noOnlineOutput 'Plugins\MulticaOnlineStarter'))) 'removing MulticaOnlineStarter from required_plugins ships no plugin payload'
	Assert-True ($noOnlineLock.plugins.MulticaOnlineStarter -eq $null) 'removing a declared plugin removes it from the lock'
	Assert-True (@($noOnlineDescriptor.Plugins | Where-Object { $_.Name -eq 'MulticaOnlineStarter' }).Count -eq 0) 'removing a declared plugin removes it from the project descriptor'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $noOnlineOutput 'docs\08-online-foundations.md'))) 'a recipe without the online plugin ships no online guide'
	$loopRecipePath = Join-Path $recipeRepo 'templates\recipes\vertical-loop\recipe.json'
	$loopData = [System.IO.File]::ReadAllText($loopRecipePath) | ConvertFrom-Json
	$loopData.required_plugins = @($loopData.required_plugins) + @('MulticaOnlineStarter')
	Write-FixtureJson $loopRecipePath (ConvertTo-Json -InputObject $loopData -Depth 10)
	$withOnlineName = "Ro_$testId"
	$withOnlineRun = "$testId-with-online"
	$withOnlineOutput = Join-Path $recipeRepoProduction "${withOnlineName}_$withOnlineRun"
	Invoke-RepositoryGenerator $recipeRepo 'vertical-loop' $withOnlineName $withOnlineRun @('Layer: plugin added')
	Assert-True (Test-Path -LiteralPath (Join-Path $withOnlineOutput 'Plugins\MulticaOnlineStarter\MulticaOnlineStarter.uplugin')) 'adding MulticaOnlineStarter to a capture-only recipe ships the plugin payload'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $withOnlineOutput 'Recipe\Play.md'))) 'adding a plugin does not add a play delta the recipe does not ship'
	# Restore the committed vertical-loop data so the regression group below measures the shipped recipe.
	Copy-Item -LiteralPath (Join-Path $repoRoot 'templates\recipes\vertical-loop\recipe.json') -Destination $loopRecipePath -Force
	Write-Output 'PASS: required_plugins drives the plugin payload, the descriptor and the lock together'

	# Stop conditions: every mismatch must refuse before the output directory exists, and none of them
	# may record an unknown value as an empty string.
	$mismatchDir = Join-Path $recipeRepo 'templates\recipes\fixture-mismatch'
	Write-FixtureRecipe $mismatchDir $fixtureCapture 'capture-only' @('MovieRenderPipeline') 'TP_FirstPerson' $true $false
	$mismatchName = "Rm_$testId"
	$mismatchFailure = Get-GeneratorFailure { Invoke-RepositoryGenerator $recipeRepo 'fixture-mismatch' $mismatchName "$testId-mismatch" @() }
	Assert-True ($mismatchFailure.Contains('both names must match')) 'a recipe.json naming another recipe stops generation'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $recipeRepoProduction "${mismatchName}_$testId-mismatch"))) 'a recipe identity mismatch creates no output directory'
	$missingFieldDir = Join-Path $recipeRepo 'templates\recipes\fixture-missing-field'
	Write-FixtureRecipe $missingFieldDir 'fixture-missing-field' 'capture-only' @('MovieRenderPipeline') 'TP_FirstPerson' $true $false
	$missingFieldJson = [System.IO.File]::ReadAllText((Join-Path $missingFieldDir 'recipe.json')) | ConvertFrom-Json
	$missingFieldJson.PSObject.Properties.Remove('purpose')
	Write-FixtureJson (Join-Path $missingFieldDir 'recipe.json') (ConvertTo-Json -InputObject $missingFieldJson -Depth 10)
	$missingFieldName = "Rf_$testId"
	$missingFieldFailure = Get-GeneratorFailure { Invoke-RepositoryGenerator $recipeRepo 'fixture-missing-field' $missingFieldName "$testId-missing-field" @() }
	Assert-True ($missingFieldFailure.Contains('must declare purpose')) 'a recipe.json without purpose stops generation instead of writing an empty value'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $recipeRepoProduction "${missingFieldName}_$testId-missing-field"))) 'a missing recipe field creates no output directory'
	$unknownPluginDir = Join-Path $recipeRepo 'templates\recipes\fixture-unknown-plugin'
	Write-FixtureRecipe $unknownPluginDir 'fixture-unknown-plugin' 'capture-only' @('MovieRenderPipeline', 'NotARealPlugin') 'TP_FirstPerson' $true $false
	$unknownPluginName = "Ru_$testId"
	$unknownPluginFailure = Get-GeneratorFailure { Invoke-RepositoryGenerator $recipeRepo 'fixture-unknown-plugin' $unknownPluginName "$testId-unknown-plugin" @() }
	Assert-True ($unknownPluginFailure.Contains("requires the plugin 'NotARealPlugin'")) 'a recipe.json naming an unknown plugin stops generation'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $recipeRepoProduction "${unknownPluginName}_$testId-unknown-plugin"))) 'an unknown declared plugin creates no output directory'
	$noCaptureDir = Join-Path $recipeRepo 'templates\recipes\fixture-no-capture'
	Write-FixtureRecipe $noCaptureDir 'fixture-no-capture' 'capture-only' @('MovieRenderPipeline') 'TP_FirstPerson' $false $false
	$noCaptureName = "RB_$testId"
	$noCaptureFailure = Get-GeneratorFailure { Invoke-RepositoryGenerator $recipeRepo 'fixture-no-capture' $noCaptureName "$testId-no-capture" @() }
	Assert-True ($noCaptureFailure.Contains('does not ship Capture.md')) 'a recipe without Capture.md stops generation'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $recipeRepoProduction "${noCaptureName}_$testId-no-capture"))) 'a recipe without Capture.md creates no output directory'
	$missingRecipeName = "Rz_$testId"
	$missingRecipeFailure = Get-GeneratorFailure { Invoke-RepositoryGenerator $recipeRepo 'does-not-exist' $missingRecipeName "$testId-missing-recipe" @() }
	Assert-True ($missingRecipeFailure.Contains('Unknown recipe')) 'an unknown recipe name stops generation and names the data file it looked for'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $recipeRepoProduction "${missingRecipeName}_$testId-missing-recipe"))) 'an unknown recipe name creates no output directory'
	# templates/recipes/common is a shared payload directory, not a selectable recipe. The failure
	# message must not advertise it as a choice, because choosing it fails with the same message.
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $recipeRepo 'templates\recipes\common\recipe.json') -PathType Leaf)) 'the shared templates/recipes/common directory ships no recipe.json'
	$commonFailure = Get-GeneratorFailure { Invoke-RepositoryGenerator $recipeRepo 'common' "Rh_$testId" "$testId-common" @() }
	Assert-True ($commonFailure.Contains('Unknown recipe')) 'the shared payload directory is not accepted as a recipe name'
	$listedRecipes = @($commonFailure.Substring($commonFailure.IndexOf('pick one of: ') + 'pick one of: '.Length).Replace('. Nothing was generated.', '').Split(',') | ForEach-Object { $_.Trim() })
	Assert-True (-not ($listedRecipes -contains 'common')) ('the selectable-recipe list omits the directory that ships no recipe.json, observed: ' + ($listedRecipes -join ', '))
	Assert-True ($listedRecipes -contains 'spectator-explore' -and $listedRecipes -contains 'vertical-loop') ('the selectable-recipe list names only directories carrying recipe.json, observed: ' + ($listedRecipes -join ', '))
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $recipeRepoProduction "Rh_${testId}_${testId}-common"))) 'choosing a directory without recipe.json creates no output directory'
	Write-Output 'PASS: recipe data mismatches stop generation before any output directory exists'

	# Regression: the two original recipes keep the exact tree they had before the data-driven rewrite.
	$spectatorData.required_plugins = @('MovieRenderPipeline', 'OnlineSubsystem', 'OnlineSubsystemNull', 'OnlineSubsystemUtils', 'MulticaOnlineStarter')
	Write-FixtureJson $recipeJsonPath (ConvertTo-Json -InputObject $spectatorData -Depth 10)
	$regressionName = "Rg_$testId"
	$regressionRun = "$testId-regression"
	$regressionOutput = Join-Path $recipeRepoProduction "${regressionName}_$regressionRun"
	Invoke-RepositoryGenerator $recipeRepo 'spectator-explore' $regressionName $regressionRun @()
	$loopRegressionName = "Rl_$testId"
	$loopRegressionRun = "$testId-loop-regression"
	$loopRegressionOutput = Join-Path $recipeRepoProduction "${loopRegressionName}_$loopRegressionRun"
	Invoke-RepositoryGenerator $recipeRepo 'vertical-loop' $loopRegressionName $loopRegressionRun @()
	[string[]]$recipeFiles = @(Get-ChildItem -LiteralPath (Join-Path $regressionOutput 'Recipe') -File -Force | Select-Object -ExpandProperty Name)
	[Array]::Sort($recipeFiles, [System.StringComparer]::Ordinal)
	Assert-True (($recipeFiles -join ',') -ceq 'Capture.md,Play.md,SET.md,recipe.json') ('the original game recipe still ships exactly Capture/Play/SET/recipe, observed: ' + ($recipeFiles -join ','))
	[string[]]$loopRecipeFiles = @(Get-ChildItem -LiteralPath (Join-Path $loopRegressionOutput 'Recipe') -File -Force | Select-Object -ExpandProperty Name)
	[Array]::Sort($loopRecipeFiles, [System.StringComparer]::Ordinal)
	Assert-True (($loopRecipeFiles -join ',') -ceq 'Capture.md,SET.md,recipe.json') ('the original video recipe still ships exactly Capture/SET/recipe, observed: ' + ($loopRecipeFiles -join ','))
	$regressionLock = [System.IO.File]::ReadAllText((Join-Path $regressionOutput 'template-lock.json')) | ConvertFrom-Json
	Assert-True ($regressionLock.recipe -ceq 'spectator-explore' -and $regressionLock.purpose -ceq 'game-and-capture') 'the original game recipe keeps its recorded recipe and purpose'
	Assert-True ((@($regressionLock.plugins.PSObject.Properties.Name) -join ',') -ceq 'MovieRenderPipeline,MulticaOnlineStarter,OnlineSubsystem,OnlineSubsystemNull,OnlineSubsystemUtils') ('the original game recipe keeps its recorded plugin set, observed: ' + (@($regressionLock.plugins.PSObject.Properties.Name) -join ','))
	Assert-True (Test-Path -LiteralPath (Join-Path $regressionOutput 'Plugins\MulticaOnlineStarter')) 'the original game recipe still ships the online plugin'
	Assert-True (Test-Path -LiteralPath (Join-Path $regressionOutput 'docs\08-online-foundations.md')) 'the original game recipe still ships the online guide'
	$loopRegressionLock = [System.IO.File]::ReadAllText((Join-Path $loopRegressionOutput 'template-lock.json')) | ConvertFrom-Json
	Assert-True ($loopRegressionLock.recipe -ceq 'vertical-loop' -and (@($loopRegressionLock.plugins.PSObject.Properties.Name) -join ',') -ceq 'MovieRenderPipeline') 'the original video recipe keeps its recorded recipe and single plugin'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $loopRegressionOutput 'Plugins'))) 'the original video recipe still ships no plugin payload'
	Write-Output 'PASS: the original two recipes keep their recorded recipe, purpose, plugin set and recipe files'

	# Engine build identity cases (UE-LOCK-001). Each case runs the shipped generator against its own
	# installed-engine fixture, because the effective changelist, the optional fields and the plugin
	# version all come from the engine tree.
	#
	# Epic's own shape: Changelist 0 with the identifier in CompatibleChangelist (mirrors of 4.18/4.22/4.26
	# show the same). UE's rule then yields 0, so the lock must not pretend otherwise; it records the
	# derived value, the raw Changelist and the CompatibleChangelist next to each other.
	$compatibleOnlyEngine = Join-Path $fixtureRoot 'CompatibleOnlyEngineRoot'
	New-FixtureEngineRoot $compatibleOnlyEngine '{"MajorVersion":5,"MinorVersion":8,"PatchVersion":4,"Changelist":0,"CompatibleChangelist":44201111,"IsLicenseeVersion":1}' -PluginWithoutVersion
	Invoke-EngineGenerator 'vertical-loop' $compatibleOnlyProjectName "$testId-a" @() $compatibleOnlyEngine
	$compatibleOnlyOutput = $outputPaths[6]
	$compatibleOnlyLock = Read-FixtureLock $compatibleOnlyOutput | ConvertFrom-Json
	Assert-True ($compatibleOnlyLock.engine_changelist -eq 0) 'a Build.version with Changelist 0 records the value the engine''s rule derives, not CompatibleChangelist'
	Assert-True ($compatibleOnlyLock.engine_changelist_source -eq 'Changelist') 'the derived changelist names the field the rule used'
	Assert-True ($compatibleOnlyLock.engine_compatible_changelist -eq 44201111) 'the build identifier that lives in CompatibleChangelist is recorded instead of ignored'
	Assert-True ($compatibleOnlyLock.engine_changelist_raw -eq 0) 'the raw Changelist is recorded exactly as the engine reported it'
	Assert-True ($compatibleOnlyLock.engine_is_licensee_version -eq 1) 'lock records the licensee flag of this install'
	Assert-True ($null -eq $compatibleOnlyLock.engine_is_promoted_build) 'a missing IsPromotedBuild is recorded as null, not as 0'
	Assert-True ($null -eq $compatibleOnlyLock.engine_branch_name) 'a missing BranchName is recorded as null, not as an empty string'
	Assert-True ($null -eq $compatibleOnlyLock.plugins.MovieRenderPipeline) 'a plugin that declares no version is recorded as null, not as an empty string'
	Assert-True ($null -ne $compatibleOnlyLock.plugins.PSObject.Properties['MovieRenderPipeline']) 'the plugin without a declared version is still named in the lock'
	Write-Output 'PASS: optional engine build fields distinguish unknown (null) from a reported zero'

	$changelistOnlyEngine = Join-Path $fixtureRoot 'ChangelistOnlyEngineRoot'
	New-FixtureEngineRoot $changelistOnlyEngine '{"MajorVersion":5,"MinorVersion":8,"PatchVersion":4,"Changelist":58902052}'
	Invoke-EngineGenerator 'vertical-loop' $changelistOnlyProjectName "$testId-a" @() $changelistOnlyEngine
	$changelistOnlyOutput = $outputPaths[7]
	$changelistOnlyLock = Read-FixtureLock $changelistOnlyOutput | ConvertFrom-Json
	Assert-True ($changelistOnlyLock.engine_changelist -eq 58902052) 'a Build.version with only Changelist records that changelist'
	Assert-True ($changelistOnlyLock.engine_changelist_source -eq 'Changelist') 'the effective changelist names Changelist as its source'
	Assert-True ($null -eq $changelistOnlyLock.engine_compatible_changelist) 'a missing CompatibleChangelist is recorded as null, not as 0'
	Assert-True ($changelistOnlyLock.plugins.MovieRenderPipeline -eq '1.0') 'a plugin that declares a version records it'
	Write-Output 'PASS: a Build.version with only Changelist still records its build identity'

	# The baseline wrote the same lock for both: Changelist 0 in both installs, CompatibleChangelist
	# never read. The lock has to separate them through the raw fields it now records.
	$installAEngine = Join-Path $fixtureRoot 'InstallAEngineRoot'
	$installBEngine = Join-Path $fixtureRoot 'InstallBEngineRoot'
	New-FixtureEngineRoot $installAEngine '{"MajorVersion":5,"MinorVersion":8,"PatchVersion":4,"Changelist":0,"CompatibleChangelist":58902052}'
	New-FixtureEngineRoot $installBEngine '{"MajorVersion":5,"MinorVersion":8,"PatchVersion":4,"Changelist":0,"CompatibleChangelist":44201111,"IsLicenseeVersion":1}'
	Invoke-EngineGenerator 'vertical-loop' $installAProjectName "$testId-a" @() $installAEngine
	Invoke-EngineGenerator 'vertical-loop' $installBProjectName "$testId-b" @() $installBEngine
	$installAOutput = $outputPaths[8]
	$installBOutput = $outputPaths[9]
	$installALockText = Read-FixtureLock $installAOutput
	$installBLockText = Read-FixtureLock $installBOutput
	$installALock = $installALockText | ConvertFrom-Json
	$installBLock = $installBLockText | ConvertFrom-Json
	Assert-True ($installALock.engine_version -eq $installBLock.engine_version) 'the two installs agree on the engine version so only the build identity can separate them'
	Assert-True ($installALock.engine_compatible_changelist -ne $installBLock.engine_compatible_changelist) 'two installs whose CompatibleChangelist differs record different build identifiers'
	Assert-True ($installALockText -cne $installBLockText) 'two different engine installs do not produce byte-identical locks'
	Write-Output 'PASS: two different engine installs do not produce the same lock record'

	# Negative cases: a Build.version whose version fields are absent. `[string]$null` is '', so the
	# baseline concatenated nothing and still reported success with '.8' or '5.8.'. The generator has
	# to stop instead of inventing a value.
	# ProjectName is capped at 40 characters, so the case labels stay short.
	$missingFieldCases = @(
		@{ Label = 'Maj'; Expected = 'numeric MajorVersion'; Json = '{"MinorVersion":8,"PatchVersion":4,"Changelist":58902052}' },
		@{ Label = 'Min'; Expected = 'numeric MinorVersion'; Json = '{"MajorVersion":5,"PatchVersion":4,"Changelist":58902052}' },
		@{ Label = 'Pat'; Expected = 'numeric PatchVersion'; Json = '{"MajorVersion":5,"MinorVersion":8,"Changelist":58902052}' },
		@{ Label = 'Num'; Expected = 'numeric PatchVersion'; Json = '{"MajorVersion":5,"MinorVersion":8,"PatchVersion":"4a","Changelist":58902052}' },
		@{ Label = 'Cl'; Expected = 'numeric Changelist'; Json = '{"MajorVersion":5,"MinorVersion":8,"PatchVersion":4,"Changelist":"unknown"}' }
	)
	foreach ($missingCase in $missingFieldCases) {
		$caseEngine = Join-Path $fixtureRoot ('Missing' + $missingCase.Label + 'EngineRoot')
		New-FixtureEngineRoot $caseEngine $missingCase.Json
		$caseProjectName = "Mf$($missingCase.Label)_$testId"
		$caseOutput = Join-Path $productionRoot ("{0}_{1}-mf" -f $caseProjectName, $testId)
		$caseFailure = ''
		try {
			Invoke-EngineGenerator 'vertical-loop' $caseProjectName "$testId-mf" @() $caseEngine
		} catch {
			$caseFailure = $_.Exception.Message
		}
		Assert-True ($caseFailure.Contains($missingCase.Expected)) ('a Build.version without ' + $missingCase.Label + ' stops the generator instead of writing a fabricated value')
		Assert-True (-not (Test-Path -LiteralPath $caseOutput)) ('a Build.version without ' + $missingCase.Label + ' writes no project')
	}
	Write-Output 'PASS: missing or non-numeric version fields stop generation instead of fabricating an empty version string'

	# A Build.version that omits Changelist entirely. UE's own parser leaves the field at 0 when the
	# file omits it, but an absent key is not the same evidence as a written 0: writing 0 would claim
	# the engine said something it never said. The lock records null for both the raw and derived values.
	$noChangelistEngine = Join-Path $fixtureRoot 'NoChangelistEngineRoot'
	New-FixtureEngineRoot $noChangelistEngine '{"MajorVersion":5,"MinorVersion":8,"PatchVersion":4,"CompatibleChangelist":44201111}'
	Invoke-EngineGenerator 'vertical-loop' $noChangelistProjectName "$testId-a" @() $noChangelistEngine
	$noChangelistOutput = $outputPaths[10]
	$noChangelistLock = Read-FixtureLock $noChangelistOutput | ConvertFrom-Json
	Assert-True ($null -ne $noChangelistLock.PSObject.Properties['engine_changelist']) 'the lock always carries the engine_changelist key'
	Assert-True ($null -eq $noChangelistLock.engine_changelist) 'a Build.version without Changelist records an unknown effective changelist, not 0'
	Assert-True ($null -eq $noChangelistLock.engine_changelist_raw) 'a Build.version without Changelist records an unknown raw changelist, not 0'
	Assert-True ($null -eq $noChangelistLock.engine_changelist_source) 'an unknown effective changelist names no source field'
	Assert-True ($noChangelistLock.engine_compatible_changelist -eq 44201111) 'the CompatibleChangelist that was present is still recorded'
	Assert-True ($noChangelistLock.engine_version -eq '5.8.4') 'the version string is complete when every version field exists'
	Write-Output 'PASS: a Build.version without Changelist records unknown as null instead of 0'

	# Path-length budget group. The repository records 260 characters as a failure it already hit
	# (docs/08-online-foundations.md:47), so the generator must stop before the exclusive mkdir when
	# the planned tree exceeds the budget. The fixture lives under the developer's checkout, whose
	# absolute root is far longer than a recorded working location, so the success cases declare the
	# measured length instead of hard-coding a number, and the stop cases drive the length by
	# cloning the repository one level deeper (clone-root depth) and by using the longest names the
	# generator accepts.
	foreach ($budgetPath in @($maxNameOutputPath)) {
		if (Test-Path -LiteralPath $budgetPath -PathType Container) {
			Remove-Item -LiteralPath $budgetPath -Recurse -Force
		}
	}
	$budgetProbeOutput = Invoke-GeneratorCaptured 'spectator-explore' 'PthB_ok1' 'budget' @() $unboundedPathBudget
	$measuredMatch = [regex]::Match($budgetProbeOutput, 'longest planned path (\d+) characters, (\d+) characters of headroom')
	Assert-True ($measuredMatch.Success) 'the generator reports the longest planned path and its headroom on success'
	$measuredLongest = [int]$measuredMatch.Groups[1].Value
	$measuredHeadroom = [int]$measuredMatch.Groups[2].Value
	Assert-True ($measuredHeadroom -eq ($unboundedPathBudget - $measuredLongest)) 'the reported headroom is the declared budget minus the measured longest path'
	Assert-True (Test-Path -LiteralPath (Join-Path $outputPaths[6] 'template-lock.json')) 'an unbounded budget still generates the project'

	Invoke-Generator 'spectator-explore' 'PthB_eq1' 'budget' @() $measuredLongest
	$equalBudgetOutput = Join-Path $productionRoot 'PthB_eq1_budget'
	Assert-True (Test-Path -LiteralPath (Join-Path $equalBudgetOutput 'template-lock.json')) 'a budget exactly equal to the longest planned path still generates the project'
	Assert-True (Test-Path -LiteralPath (Join-Path $equalBudgetOutput 'Plugins\MulticaOnlineStarter\MulticaOnlineStarter.uplugin')) 'the budget check does not drop the online plugin payload'

	$tightBudget = $measuredLongest - 1
	$budgetFailure = ''
	try { Invoke-Generator 'spectator-explore' 'PthB_no1' 'budget' @() $tightBudget } catch { $budgetFailure = $_.Exception.Message }
	Assert-True ($budgetFailure.Contains([string]$measuredLongest)) 'the budget stop names the measured longest path length'
	Assert-True ($budgetFailure.Contains("{0}-character budget" -f $tightBudget)) 'the budget stop names the budget it compared against'
	Assert-True ($budgetFailure.Contains('over the')) 'the budget stop states how far the tree exceeds the budget'
	Assert-True ($budgetFailure.Contains('shallower directory')) 'the budget stop suggests a concrete way to shorten the path'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $productionRoot 'PthB_no1_budget'))) 'a budget stop happens before the exclusive mkdir, so no output directory exists'

	# Default budget (no -MaxPathLength), driven by the longest names the generator accepts. This is
	# the case an agent hits by following the documented example with a full GUID run ID. Whether it
	# stops depends on how deep this checkout is, so the expectation is derived from the measured
	# length instead of assuming the developer's path.
	$maxNameProbeRun = ('b' * 64)
	$maxNameProbe = (& $generator -Recipe 'spectator-explore' -ProjectName $maxName -RunId $maxNameProbeRun -EngineRoot $fixtureEngine -ProjectDiff @() -AllowDirtyTemplate -MaxPathLength $unboundedPathBudget) -join "`n"
	$maxNameProbePath = Join-Path $productionRoot ('{0}_{1}' -f $maxName, $maxNameProbeRun)
	if (Test-Path -LiteralPath $maxNameProbePath -PathType Container) { Remove-Item -LiteralPath $maxNameProbePath -Recurse -Force }
	$maxNameMatch = [regex]::Match($maxNameProbe, 'longest planned path (\d+) characters')
	Assert-True ($maxNameMatch.Success) 'the longest-name probe reports its measured longest path'
	$maxNameLongest = [int]$maxNameMatch.Groups[1].Value
	$maxNameFailure = ''
	$maxNameCreated = $false
	try {
		Invoke-GeneratorNoBudget 'spectator-explore' $maxName $maxRun @()
		$maxNameCreated = $true
	} catch { $maxNameFailure = $_.Exception.Message }
	if ($maxNameLongest -gt 260) {
		Assert-True ($maxNameFailure.Contains('260-character budget')) 'the default budget is 260 characters and stops a full-length name in this checkout'
		Assert-True ($maxNameFailure.Contains($maxNameOutputPath)) 'the default-budget stop names the output directory it refused to create'
		Assert-True (-not (Test-Path -LiteralPath $maxNameOutputPath)) 'the default-budget stop creates no output directory'
	} else {
		Assert-True ($maxNameCreated) 'a checkout so short that even the longest names fit still generates with the default budget'
	}

	# Same default budget, but the depth comes from the clone root instead of the names. The extra
	# depth is computed from the length the success case reported, so this fixture keeps working when
	# the tree or the developer's checkout path changes. Only the directory depth differs between the
	# stop below and the success right after it.
	$relativeLongest = $measuredLongest - ($outputPaths[6].Length + 1)
	$deepOutputName = 'PthB_dk1_dk'
	$deepRootLengthNeeded = 259 - $relativeLongest - ($deepOutputName.Length + '\Production'.Length) + 1
	$deepRootLengthNeeded = [Math]::Max($deepRootLengthNeeded, $fixtureRoot.Length + 120)
	$deepSegment = 'd' * ($deepRootLengthNeeded - $fixtureRoot.Length - 1)
	$deepParent = Join-Path $fixtureRoot $deepSegment
	[System.IO.Directory]::CreateDirectory($deepParent) | Out-Null
	& git -C $repoRoot clone --quiet --local --no-hardlinks --no-tags --no-checkout $repoRoot $deepRepoRoot
	if ($LASTEXITCODE -ne 0) { throw 'Could not create the isolated deep-path repository fixture.' }
	& git -C $deepRepoRoot checkout --quiet --detach $templateRevision
	if ($LASTEXITCODE -ne 0) { throw "Could not check out revision $templateRevision in the isolated deep-path repository fixture." }
	[System.IO.Directory]::CreateDirectory((Join-Path $deepRepoRoot 'Production')) | Out-Null
	$deepGenerator = Join-Path $deepRepoRoot 'scripts\New-UETemplateScaffold.ps1'
	Copy-Item -LiteralPath $generator -Destination $deepGenerator -Force
	$deepStopFailure = ''
	try {
		& $deepGenerator -Recipe 'spectator-explore' -ProjectName 'PthB_dk1' -RunId 'dk' -EngineRoot $fixtureEngine -ProjectDiff @() -AllowDirtyTemplate | Out-Null
	} catch { $deepStopFailure = $_.Exception.Message }
	Assert-True ($deepStopFailure.Contains('260-character budget')) 'a deeper clone root stops the default-budget run without changing the generated tree'
	Assert-True ($deepStopFailure.Contains($deepRepoRoot)) 'the deep-root stop names the checkout root that made the tree too long'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path (Join-Path $deepRepoRoot 'Production') $deepOutputName))) 'the deep-root stop creates no output directory'
	$deepSuccessOutput = (& $deepGenerator -Recipe 'spectator-explore' -ProjectName 'PthB_dk1' -RunId 'dk' -EngineRoot $fixtureEngine -ProjectDiff @() -AllowDirtyTemplate -MaxPathLength $unboundedPathBudget) -join "`n"
	$deepMatch = [regex]::Match($deepSuccessOutput, 'longest planned path (\d+) characters')
	Assert-True ($deepMatch.Success) 'the deep-root run reports its measured longest path when the budget allows it'
	Assert-True ([int]$deepMatch.Groups[1].Value -gt 260) 'the deeper clone root really exceeds 260 characters for the same tree'
	Assert-True (Test-Path -LiteralPath (Join-Path (Join-Path $deepRepoRoot 'Production') ($deepOutputName + '\template-lock.json'))) 'an explicitly raised budget still generates the project at the deeper root'

	# The measured value must equal the tree that actually lands on disk, including the recipe that
	# rewrites paths through TemplateDefs.ini (folder renames change the relative lengths).
	$materializedOutput = (& $generator -Recipe 'third-person-game' -ProjectName $pathBudgetMaterializedName -RunId 'budget' -EngineRoot $fixtureEngine -ProjectDiff @() -AllowDirtyTemplate -MaxPathLength $unboundedPathBudget) -join "`n"
	$materializedMatch = [regex]::Match($materializedOutput, 'longest planned path (\d+) characters')
	Assert-True ($materializedMatch.Success) 'the materializing recipe reports its measured longest path too'
	$materializedDir = Join-Path $productionRoot ('{0}_budget' -f $pathBudgetMaterializedName)
	$actualLongest = (Get-ChildItem -LiteralPath $materializedDir -Recurse -File -Force | ForEach-Object { $_.FullName.Length } | Measure-Object -Maximum).Maximum
	Assert-True ([int]$materializedMatch.Groups[1].Value -eq $actualLongest) 'the measured longest path equals the longest file actually written for a materializing recipe'
	Write-Output 'PASS: path-length budget stops before output creation and reports the measured longest path'

	# Negative case: Build.version carries a non-numeric version field. Deriving 5.8 from it would
	# write a fragment such as '.8' into the descriptor and the lock and then report success, so the
	# generator must stop before copying and leave no output behind.
	$badVersionRepoRoot = Join-Path $fixtureRoot 'BadVersionTemplate'
	& git -C $repoRoot clone --quiet --local --no-hardlinks --no-tags --no-checkout $repoRoot $badVersionRepoRoot
	if ($LASTEXITCODE -ne 0) { throw 'Could not create the isolated bad-Build.version repository fixture.' }
	& git -C $badVersionRepoRoot checkout --quiet --detach $templateRevision
	if ($LASTEXITCODE -ne 0) { throw "Could not check out revision $templateRevision in the isolated bad-Build.version repository fixture." }
	[System.IO.Directory]::CreateDirectory((Join-Path $badVersionRepoRoot 'Production')) | Out-Null
	$badVersionGenerator = Join-Path $badVersionRepoRoot 'scripts\New-UETemplateScaffold.ps1'
	Copy-Item -LiteralPath $generator -Destination $badVersionGenerator -Force
	$badVersionEngine = Join-Path $fixtureRoot 'BadVersionEngineRoot'
	New-FixtureEngineRoot $badVersionEngine '{"MajorVersion":"","MinorVersion":8,"PatchVersion":4,"Changelist":58902052}'
	$badVersionProjectName = "BadVer_$testId"
	$badVersionOutput = Join-Path (Join-Path $badVersionRepoRoot 'Production') "${badVersionProjectName}_badver"
	$badVersionFailure = ''
	try {
		& $badVersionGenerator -Recipe 'vertical-loop' -ProjectName $badVersionProjectName -RunId 'badver' -EngineRoot $badVersionEngine -ProjectDiff @() -AllowDirtyTemplate -SkipTemplatePublishCheck | Out-Null
	} catch {
		$badVersionFailure = $_.Exception.Message
	}
	Assert-True ($badVersionFailure.Contains('does not define a numeric MajorVersion')) 'a non-numeric Build.version field stops the generator instead of deriving a fragment'
	Assert-True (-not (Test-Path -LiteralPath $badVersionOutput)) 'bad Build.version stop writes no project'
	Write-Output 'PASS: non-numeric Build.version fields stop generation instead of writing a partial EngineAssociation'

	# Negative case: the template project file names a module that its Source/ tree does not
	# contain. The generator must stop instead of emitting a raw copy with an unresolved identity.
	$driftTemplateName = 'TP_IdentityDrift'
	$driftTemplateRoot = Join-Path $fixtureEngine ('Templates\' + $driftTemplateName)
	Write-FixtureTemplate $driftTemplateRoot $driftTemplateName 'IdentityDriftModule'
	$driftRepoRoot = Join-Path $fixtureRoot 'IdentityDriftTemplate'
	& git -C $repoRoot clone --quiet --local --no-hardlinks --no-tags --no-checkout $repoRoot $driftRepoRoot
	if ($LASTEXITCODE -ne 0) { throw 'Could not create the isolated identity-drift repository fixture.' }
	& git -C $driftRepoRoot checkout --quiet --detach $templateRevision
	if ($LASTEXITCODE -ne 0) { throw "Could not check out revision $templateRevision in the isolated identity-drift repository fixture." }
	[System.IO.Directory]::CreateDirectory((Join-Path $driftRepoRoot 'Production')) | Out-Null
	$driftGenerator = Join-Path $driftRepoRoot 'scripts\New-UETemplateScaffold.ps1'
	Copy-Item -LiteralPath $generator -Destination $driftGenerator -Force
	Set-FixtureRecipeTemplate $driftRepoRoot 'vertical-loop' $driftTemplateName
	$driftProjectName = "Drift_$testId"
	$driftOutput = Join-Path (Join-Path $driftRepoRoot 'Production') "${driftProjectName}_drift"
	$driftFailure = ''
	try {
		& $driftGenerator -Recipe 'vertical-loop' -ProjectName $driftProjectName -RunId 'drift' -EngineRoot $fixtureEngine -ProjectDiff @() -AllowDirtyTemplate -SkipTemplatePublishCheck | Out-Null
	} catch {
		$driftFailure = $_.Exception.Message
	}
	Assert-True ($driftFailure.Contains('Project identity check stopped')) 'unresolved project identity stops the generator'
	Assert-True ($driftFailure.Contains('Source/TP_IdentityDrift/TP_IdentityDrift.Build.cs')) 'the stop names the unmatched source path instead of guessing'
	Assert-True (-not (Test-Path -LiteralPath $driftOutput)) 'identity stop writes no raw-copied project'
	Write-Output 'PASS: unresolvable project identity stops generation instead of emitting a raw copy'

	# Negative case: the QA row check must fail when a row is dropped, so it cannot report PASS on a
	# template that silently stopped asking for an acceptance item. The copy lives inside the fixture
	# root, which the residue check already allows and the finally block removes.
	$qaSource = Join-Path $repoRoot $qaTemplateRelativePath
	$qaFixtureDirectory = Join-Path $fixtureRoot 'QaTemplate'
	[System.IO.Directory]::CreateDirectory($qaFixtureDirectory) | Out-Null
	$qaCopyPath = Join-Path $qaFixtureDirectory 'QA.md'
	[System.IO.File]::WriteAllText($qaCopyPath, [System.IO.File]::ReadAllText($qaSource), [System.Text.UTF8Encoding]::new($false))
	Assert-QaTemplateContract $qaCopyPath
	Write-Output 'PASS: an unmodified QA template copy satisfies the row contract'

	$qaMissingRowFailures = @()
	foreach ($droppedId in @('QA-NET-02', 'QA-NET-09', 'QA-PLAY-01', 'QA-BUILD-01')) {
		$mutated = @([System.IO.File]::ReadAllText($qaSource) -split "\r?\n" | Where-Object { $_ -notmatch ("\[" + $droppedId + "\]") })
		[System.IO.File]::WriteAllText($qaCopyPath, ($mutated -join "`n"), [System.Text.UTF8Encoding]::new($false))
		$droppedFailure = ''
		try { Assert-QaTemplateContract $qaCopyPath } catch { $droppedFailure = $_.Exception.Message }
		Assert-True ($droppedFailure.Contains($droppedId)) "dropping row $droppedId is reported by name instead of passing silently"
		$qaMissingRowFailures += $droppedId
	}
	Assert-True ($qaMissingRowFailures.Count -eq 4) 'four independent required rows each fail the row check when dropped'

	$mutated = @([System.IO.File]::ReadAllText($qaSource) -split "\r?\n" | ForEach-Object {
		if ($_ -match '^\| \[QA-MRQ-01\]') { $_ -replace '\| unverified \|', '| ok |' } else { $_ }
	})
	[System.IO.File]::WriteAllText($qaCopyPath, ($mutated -join "`n"), [System.Text.UTF8Encoding]::new($false))
	$verdictFailure = ''
	try { Assert-QaTemplateContract $qaCopyPath } catch { $verdictFailure = $_.Exception.Message }
	Assert-True ($verdictFailure.Contains("row QA-MRQ-01 uses 'ok'")) 'a value outside pass/fail/unverified/non-goal is rejected instead of counting as a recorded verdict'

	# A Markdown escape inside an evidence cell is cell content, not a column separator. Splitting on it
	# turned a complete row into a wider line that the row checks then skipped, so a reviewer writing
	# `a \| b` in the evidence column would have lost the row from the contract.
	$escapedPipeCopy = @([System.IO.File]::ReadAllText($qaSource) -split "\r?\n" | ForEach-Object {
		if ($_ -match '^\| \[QA-NET-02\]') { $_.TrimEnd().TrimEnd('|').TrimEnd() + ' escaped \| separator inside one cell |' } else { $_ }
	})
	[System.IO.File]::WriteAllText($qaCopyPath, ($escapedPipeCopy -join "`n"), [System.Text.UTF8Encoding]::new($false))
	Assert-QaTemplateContract $qaCopyPath
	$escapedRows = @(Get-QaTemplateRows $qaCopyPath)
	Assert-True (@($escapedRows | Where-Object { $_.Id -eq 'QA-NET-02' }).Count -eq 1) 'an escaped pipe in an evidence cell does not remove the row from the row list'
	Assert-True (@($escapedRows | Where-Object { $_.Id -eq 'QA-NET-02' })[0].Evidence.Contains('escaped \| separator')) 'the escaped pipe stays in the evidence cell'

	[System.IO.File]::WriteAllText($qaCopyPath, [System.IO.File]::ReadAllText($qaSource), [System.Text.UTF8Encoding]::new($false))
	Assert-QaTemplateContract $qaCopyPath
	Write-Output 'PASS: dropping a QA acceptance row fails the row contract and names the missing row'

	# The generated project's own Config declares the map it opens. If that map is only available
	# through a declared shared content pack, the pack copy has to happen before the check; if it is
	# missing altogether the generator must stop instead of printing `Created ...` over a project
	# whose first documented step (open, press Play) lands on an unresolved map.
	$packMapTemplateName = 'TP_PackMapDrift'
	$packMapTemplateRoot = Join-Path $fixtureEngine ('Templates\' + $packMapTemplateName)
	Write-FixtureTemplate $packMapTemplateRoot $packMapTemplateName 'TP_PackMapDrift' ("[/Script/EngineSettings.GameMapsSettings]`r`nGameDefaultMap=/Game/LevelPrototyping/Lvl_Prototype.Lvl_Prototype`r`nEditorStartupMap=/Game/LevelPrototyping/Lvl_Prototype.Lvl_Prototype`r`n")
	Write-FixtureTemplateDefs $packMapTemplateRoot @(
		'[/Script/GameProjectGeneration.TemplateProjectDefs]',
		'FoldersToIgnore=Media',
		'FilesToIgnore="%TEMPLATENAME%.uproject"',
		'FilesToIgnore="Config/TemplateDefs.ini"',
		'EditDetailLevelPreference="High"'
	)
	Write-FixtureJson (Join-Path $fixtureEngine 'Templates\TemplateResources\High\LevelPrototyping\Content\Lvl_Prototype.umap') 'binary Lvl_Prototype'
	$packMapRepoRoot = Join-Path $fixtureRoot 'PackMapDriftTemplate'
	& git -C $repoRoot clone --quiet --local --no-hardlinks --no-tags --no-checkout $repoRoot $packMapRepoRoot
	if ($LASTEXITCODE -ne 0) { throw 'Could not create the isolated pack-map repository fixture.' }
	& git -C $packMapRepoRoot checkout --quiet --detach $templateRevision
	if ($LASTEXITCODE -ne 0) { throw "Could not check out revision $templateRevision in the isolated pack-map repository fixture." }
	[System.IO.Directory]::CreateDirectory((Join-Path $packMapRepoRoot 'Production')) | Out-Null
	$packMapGenerator = Join-Path $packMapRepoRoot 'scripts\New-UETemplateScaffold.ps1'
	Copy-Item -LiteralPath $generator -Destination $packMapGenerator -Force
	Set-FixtureRecipeTemplate $packMapRepoRoot 'vertical-loop' $packMapTemplateName

	# Positive half: declare the pack that carries the default map and generation has to succeed with
	# the map present in the output.
	[System.IO.File]::AppendAllText((Join-Path $packMapTemplateRoot 'Config\TemplateDefs.ini'), "`r`nSharedContentPacks=(MountName=`"LevelPrototyping`",DetailLevels=(`"High`"))`r`n", [System.Text.UTF8Encoding]::new($false))
	$packMapProjectName = "PackMap_$testId"
	$packMapOutput = Join-Path (Join-Path $packMapRepoRoot 'Production') "${packMapProjectName}_ok"
	& $packMapGenerator -Recipe 'vertical-loop' -ProjectName $packMapProjectName -RunId 'ok' -EngineRoot $fixtureEngine -ProjectDiff @() -AllowDirtyTemplate | Out-Null
	Assert-True (Test-Path -LiteralPath (Join-Path $packMapOutput 'Content\LevelPrototyping\Lvl_Prototype.umap')) 'the default map check accepts a map provided by a declared shared content pack'
	Assert-True ((([System.IO.File]::ReadAllText((Join-Path $packMapOutput 'template-lock.json'))) | ConvertFrom-Json).shared_content_packs -contains 'LevelPrototyping') 'lock records the pack that supplied the default map'
	Write-Output 'PASS: default map resolution accepts pack-provided maps'

	# Negative half: the same template with the pack declaration removed. The map is now nowhere in the
	# output, so the generator must stop before writing the lock and reporting success.
	$packMapDefsPath = Join-Path $packMapTemplateRoot 'Config\TemplateDefs.ini'
	$packMapDefsText = [System.IO.File]::ReadAllText($packMapDefsPath)
	[System.IO.File]::WriteAllText($packMapDefsPath, ($packMapDefsText -replace '(?m)^SharedContentPacks=.*$', ''), [System.Text.UTF8Encoding]::new($false))
	$missingMapProjectName = "NoMap_$testId"
	$missingMapFailure = ''
	try {
		& $packMapGenerator -Recipe 'vertical-loop' -ProjectName $missingMapProjectName -RunId 'missing-map' -EngineRoot $fixtureEngine -ProjectDiff @() -AllowDirtyTemplate | Out-Null
	} catch {
		$missingMapFailure = $_.Exception.Message
	}
	$missingMapOutput = Join-Path (Join-Path $packMapRepoRoot 'Production') "${missingMapProjectName}_missing-map"
	Assert-True ($missingMapFailure.Contains('Default map check stopped')) 'a declared default map missing from the output stops the generator'
	Assert-True ($missingMapFailure.Contains('/Game/LevelPrototyping/Lvl_Prototype')) 'the stop names the declared map package path'
	Assert-True ($missingMapFailure.Contains('Content/LevelPrototyping/Lvl_Prototype.umap')) 'the stop names the missing asset path instead of guessing'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $missingMapOutput 'template-lock.json'))) 'the default map stop happens before the lock is written, so success is never recorded'
	Write-Output 'PASS: a missing default map stops generation instead of reporting success'

	$playerCountGate = Join-Path $PSScriptRoot 'Test-MulticaOnlinePlayerCountContract.ps1'
	$playerCountFindings = @(& $playerCountGate -RepositoryRoot $repoRoot)
	Assert-True ($LASTEXITCODE -eq 0) ('the online player-count contract gate passes (the Logout path excludes the leaving controller and keeps the engine predicate): ' + ($playerCountFindings -join '; '))
	Write-Output 'PASS: online player count excludes the leaving controller and keeps the engine player predicate'

	$existingOutput = $outputPaths[3]
	[System.IO.Directory]::CreateDirectory($existingOutput) | Out-Null
	$sentinel = Join-Path $existingOutput 'KEEP.txt'
	[System.IO.File]::WriteAllText($sentinel, 'untouched', [System.Text.UTF8Encoding]::new($false))
	Assert-GeneratorFails { Invoke-Generator 'spectator-explore' $existingProjectName "$testId-preserved" @() } 'existing output is rejected'
	Assert-True ([System.IO.File]::ReadAllText($sentinel) -ceq 'untouched') 'existing output content is not overwritten'
	Write-Output 'PASS: exclusive output-directory creation preserves existing content'

	# Ordering contract (UE-FIRSTRUN-001): the documented first run writes preflight and lease to
	# Production/.runs/run_<runid>/, outside the generated project. Before the fix, every documented
	# route occupied Production/<Name>_<runid>/ first and the generator stopped with one message that
	# did not say why, so the first run could not finish at all.
	$placement = 'preflight-lease-placement: Production/.runs/run_<runid>/'
	$architectureText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'docs\07-architecture.md'))
	Assert-True ($architectureText.Contains($placement)) 'docs/07-architecture.md states the single preflight/lease placement as a machine-readable line'
	foreach ($docPath in @('AGENTS.md', 'README.md', 'docs\01-start.md')) {
		$docText = [System.IO.File]::ReadAllText((Join-Path $repoRoot $docPath))
		Assert-True ($docText.Contains('Production/.runs/run_<runid>/')) "$docPath points at the same preflight/lease placement as docs/07-architecture.md"
		Assert-True ($docText.Contains('Production/<Name>_<runid>/')) "$docPath still names the generated project directory as a separate path"
	}
	$startText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'docs\01-start.md'))
	# The suite must stay ASCII-only (Windows PowerShell 5.1 reads BOM-less scripts in the system
	# code page), so the documents are checked through ASCII markers rather than their prose: every
	# mention of the tracked QA template has to name the ledger destination on the same line, and the
	# lease rule has to name the generated project directory it must not create.
	$templateMentions = @($startText -split "`n" | Where-Object { $_.Contains('`templates/QA.md`') })
	Assert-True ($templateMentions.Count -gt 0) 'docs/01-start.md still refers to templates/QA.md as the record template'
	foreach ($mention in $templateMentions) {
		Assert-True ($mention.Contains('Production/.runs/run_<runid>/preflight.md')) 'every templates/QA.md mention in docs/01-start.md names the copy destination Production/.runs/run_<runid>/preflight.md'
	}
	Assert-True ($startText.Contains('Production/<Name>_<runid>/') -and $startText.Contains('Production/.runs/run_<runid>/')) 'docs/01-start.md keeps the generated project directory and the ledger directory as different paths'
	$agentsText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'AGENTS.md'))
	$tree = [regex]::Match($agentsText, '(?s)```text\r?\n(.*?)```').Groups[1].Value
	Assert-True ($tree.Contains('.runs/run_<runid>/')) 'AGENTS.md folder diagram has the ledger directory'
	$treeLeaseLine = @($tree -split "`n" | Where-Object { $_.Contains('LEASE.json') })
	Assert-True ($treeLeaseLine.Count -eq 1) 'AGENTS.md folder diagram lists the lease file exactly once'
	$leaseIndent = $treeLeaseLine[0].Length - $treeLeaseLine[0].TrimStart().Length
	$ledgerIndent = (@($tree -split "`n" | Where-Object { $_.Contains('.runs/run_<runid>/') })[0]).Length - (@($tree -split "`n" | Where-Object { $_.Contains('.runs/run_<runid>/') })[0]).TrimStart().Length
	Assert-True ($leaseIndent -gt $ledgerIndent) 'AGENTS.md folder diagram nests LEASE.json inside Production/.runs/run_<runid>/, not inside the generated project'
	$projectLine = @($tree -split "`n" | Where-Object { $_.Contains('<Name>_<runid>/') })
	Assert-True ($projectLine.Count -eq 1) 'AGENTS.md folder diagram lists the generated project directory once'
	Assert-True (@($tree -split "`n" | Where-Object { $_.Contains('Out/run_<runid>/') }).Count -eq 1) 'AGENTS.md folder diagram keeps Out/ inside the generated project'
	$startLeaseLines = @($startText -split "`n" | Where-Object { $_.Contains('LEASE.json') })
	foreach ($rule in $startLeaseLines) {
		Assert-True ($rule.Contains('Production/.runs/run_<runid>/')) 'docs/01-start.md places the lease in Production/.runs/run_<runid>/, outside the generated project'
	}
	Assert-True (-not ($startText -split "`n" | Where-Object { $_.Contains('`templates/QA.md`') -and -not $_.Contains('Production/.runs/run_<runid>/preflight.md') }).Count -gt 0) 'docs/01-start.md never treats the tracked template as the record destination'
	Write-Output 'PASS: preflight/lease placement is stated once and referenced by AGENTS.md, README.md and docs/01-start.md'

	# The documented order actually completes: copy the QA template into the ledger directory, leave a
	# lease there, then generate. The generated project directory is created only by the generator.
	$ledgerProjectNameRun = $ledgerRunId
	[System.IO.Directory]::CreateDirectory($ledgerRoot) | Out-Null
	$preflightPath = Join-Path $ledgerRoot 'preflight.md'
	[System.IO.File]::WriteAllText($preflightPath, [System.IO.File]::ReadAllText((Join-Path $repoRoot 'templates\QA.md')), [System.Text.UTF8Encoding]::new($false))
	$leasePath = Join-Path $ledgerRoot 'LEASE.json'
	$leaseCreate = [System.IO.File]::Open($leasePath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
	try {
		$leaseBytes = [System.Text.UTF8Encoding]::new($false).GetBytes('{"run":"' + $ledgerProjectNameRun + '","host":"test","nonce":"fixture"}')
		$leaseCreate.Write($leaseBytes, 0, $leaseBytes.Length)
	} finally { $leaseCreate.Dispose() }
	Assert-True (Test-Path -LiteralPath $preflightPath -PathType Leaf) 'the preflight record exists in the ledger directory before generation'
	Assert-True (Test-Path -LiteralPath $leasePath -PathType Leaf) 'the lease exists in the ledger directory before generation'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $productionRoot ("${ledgerProjectName}_$ledgerProjectNameRun")))) 'the generated project directory does not exist before generation'
	$statusBeforeLedgerRun = @(& git -C $repoRoot status --porcelain --untracked-files=all)
	Assert-True (($statusBeforeLedgerRun -join '') -notmatch 'Production/') 'preflight and lease in Production/.runs/ keep the template working tree clean'
	Invoke-Generator 'vertical-loop' $ledgerProjectName $ledgerProjectNameRun @()
	Assert-GeneratedProject $ledgerProjectName $ledgerProjectNameRun 'the documented preflight -> lease -> generation order completes with a generated project'
	Assert-True ([System.IO.File]::ReadAllText($preflightPath) -ceq [System.IO.File]::ReadAllText((Join-Path $repoRoot 'templates\QA.md'))) 'the ledger preflight record is left unchanged by generation'
	Assert-True ([System.IO.File]::ReadAllText((Join-Path (Join-Path $productionRoot ("${ledgerProjectName}_$ledgerProjectNameRun")) 'template-lock.json')) -match '"engine_template":\s*"TP_BlankBP"') 'the generated project records its engine template'
	Write-Output 'PASS: preflight and lease recorded outside the generated project still allow generation (exit 0)'

	# Ordering errors must be distinguishable from a real existing project: an empty directory, a
	# lease-only directory, and an Out/-only directory all used to produce the same message.
	$emptyOutput = Join-Path $productionRoot ("${existingProjectName}_$emptyRunId")
	[System.IO.Directory]::CreateDirectory($emptyOutput) | Out-Null
	$emptyFailure = Get-GeneratorFailure { Invoke-Generator 'spectator-explore' $existingProjectName $emptyRunId @() }
	Assert-True ($emptyFailure.Contains('Ordering error') -or $emptyFailure.Contains('ordering error')) 'an empty output directory is reported as an ordering error'
	Assert-True ($emptyFailure.Contains('Production/.runs/run_<runid>/')) 'the empty-directory message names the correct preflight/lease placement'
	Assert-True (-not $emptyFailure.Contains('An existing output is present')) 'the empty directory is not reported as an existing project'
	Write-Output 'PASS: an empty generated-project directory is reported as an ordering error, not an existing project'

	$leaseOnlyOutput = Join-Path $productionRoot ("${existingProjectName}_$leaseRunId")
	[System.IO.Directory]::CreateDirectory($leaseOnlyOutput) | Out-Null
	[System.IO.File]::WriteAllText((Join-Path $leaseOnlyOutput 'LEASE.json'), '{"run":"fixture"}', [System.Text.UTF8Encoding]::new($false))
	$leaseOnlyFailure = Get-GeneratorFailure { Invoke-Generator 'spectator-explore' $existingProjectName $leaseRunId @() }
	Assert-True ($leaseOnlyFailure.Contains('ordering error')) 'a lease-only output directory is reported as an ordering error'
	Assert-True ($leaseOnlyFailure.Contains('LEASE.json')) 'the lease-only message lists the bookkeeping entry it found'
	Assert-True ([System.IO.File]::ReadAllText((Join-Path $leaseOnlyOutput 'LEASE.json')) -ceq '{"run":"fixture"}') 'the ordering-error refusal leaves the lease file untouched'
	Write-Output 'PASS: a lease-only generated-project directory is reported as an ordering error without deleting the lease'

	$outOnlyOutput = Join-Path $productionRoot ("${existingProjectName}_$outRunId")
	[System.IO.Directory]::CreateDirectory((Join-Path $outOnlyOutput 'Out\run_fixture')) | Out-Null
	[System.IO.File]::WriteAllText((Join-Path $outOnlyOutput 'Out\run_fixture\QA.md'), 'fixture', [System.Text.UTF8Encoding]::new($false))
	$outOnlyFailure = Get-GeneratorFailure { Invoke-Generator 'spectator-explore' $existingProjectName $outRunId @() }
	Assert-True ($outOnlyFailure.Contains('ordering error')) 'an Out/-only output directory is reported as an ordering error'
	Assert-True ($outOnlyFailure.Contains('Out')) 'the Out/-only message lists the bookkeeping entry it found'
	Assert-True (Test-Path -LiteralPath (Join-Path $outOnlyOutput 'Out\run_fixture\QA.md') -PathType Leaf) 'the ordering-error refusal does not delete the existing Out/ content'
	Write-Output 'PASS: an Out/-only generated-project directory is reported as an ordering error without deleting content'

	# The clean-tree contract is unchanged: editing the tracked QA template still stops generation.
	$cleanTreeRepoRoot = Join-Path $fixtureRoot 'CleanTreeTemplate'
	& git -C $repoRoot clone --quiet --local --no-hardlinks --no-tags --no-checkout $repoRoot $cleanTreeRepoRoot
	if ($LASTEXITCODE -ne 0) { throw 'Could not create the isolated clean-tree repository fixture.' }
	& git -C $cleanTreeRepoRoot checkout --quiet --detach $templateRevision
	if ($LASTEXITCODE -ne 0) { throw "Could not check out revision $templateRevision in the isolated clean-tree repository fixture." }
	[System.IO.Directory]::CreateDirectory((Join-Path $cleanTreeRepoRoot 'Production')) | Out-Null
	$cleanTreeGenerator = Join-Path $cleanTreeRepoRoot 'scripts\New-UETemplateScaffold.ps1'
	Copy-Item -LiteralPath $generator -Destination $cleanTreeGenerator -Force
	$qaTemplatePath = Join-Path $cleanTreeRepoRoot 'templates\QA.md'
	[System.IO.File]::AppendAllText($qaTemplatePath, [Environment]::NewLine + 'preflight recorded in place (fixture)' + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
	$cleanTreeProjectName = "QaEdit_$testId"
	$cleanTreeOutput = Join-Path (Join-Path $cleanTreeRepoRoot 'Production') "${cleanTreeProjectName}_qatemplate"
	$cleanTreeFailure = ''
	try {
		& $cleanTreeGenerator -Recipe 'vertical-loop' -ProjectName $cleanTreeProjectName -RunId 'qatemplate' -EngineRoot $fixtureEngine -ProjectDiff @() | Out-Null
	} catch {
		$cleanTreeFailure = $_.Exception.Message
	}
	Assert-True ($cleanTreeFailure.Contains('template working tree is dirty')) 'editing templates/QA.md still stops generation through the clean-tree gate'
	Assert-True (-not (Test-Path -LiteralPath $cleanTreeOutput)) 'the clean-tree refusal writes no project'
	Write-Output 'PASS: editing the tracked QA template still stops generation (clean-tree contract preserved)'
} catch {
	# `$_` is not the in-flight error inside a bare `finally`; capture it here so a cleanup failure
	# cannot hide the original assertion.
	$suiteError = $_
} finally {
	foreach ($path in $outputPaths) {
		if (Test-Path -LiteralPath $path -PathType Container) {
			Remove-Item -LiteralPath $path -Recurse -Force
		}
	}
	if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
		Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
	}
	if (Test-Path -LiteralPath $fixtureTempRoot -PathType Container) {
		Remove-Item -LiteralPath $fixtureTempRoot -Recurse -Force
 	}

	if (Test-Path -LiteralPath $ledgerRoot -PathType Container) {
		Remove-Item -LiteralPath $ledgerRoot -Recurse -Force
	}
	$runsRoot = Split-Path -Parent $ledgerRoot
	if ((Test-Path -LiteralPath $runsRoot -PathType Container) -and (@(Get-ChildItem -LiteralPath $runsRoot -Force).Count -eq 0)) {
		Remove-Item -LiteralPath $runsRoot -Force
	}

	if (Test-Path -LiteralPath $provenanceRoot -PathType Container) {
		Remove-Item -LiteralPath $provenanceRoot -Recurse -Force
	}
	if (Test-Path -LiteralPath $provenanceRoot) { $cleanupProblems += "provenance fixture root still exists: $provenanceRoot" }
	$cleanupProblems = @(Get-ProductionResidue | ForEach-Object { "Production/ residual entry after cleanup: $_" })
	# Both roots are checked AFTER the residue assignment above: appending to $cleanupProblems before it
	# would be discarded by that assignment, which is exactly how this temp-root leak check went dead.
	if (Test-Path -LiteralPath $fixtureTempRoot) { $cleanupProblems += "recipe fixture root still exists: $fixtureTempRoot" }
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
