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

# The fixtures are isolated git clones that each hold their own Production/ and a generated project,
# so the deepest path the suite creates is the fixture root plus roughly 80 characters. A developer
# checkout that is already deep (for example an agent workspace under %USERPROFILE%) pushes that past
# the Win32 path limit, the generator stops with 'Could not exclusively create the output directory
# (Win32 206)', and the suite reports the fixture layout as a generator defect. Keep the fixture under
# Production/ while it fits; fall back to the system temp directory when it does not. This is harness
# hygiene only: the generator's own long-path behaviour is DOT-3132's scope, not this suite's.
$fixtureRootPathBudget = 160
$productionFixtureRoot = Join-Path $productionRoot ('.scaffold-test-' + $testId)
$fixtureRoot = if ($productionFixtureRoot.Length -le $fixtureRootPathBudget) {
	$productionFixtureRoot
} else {
	Join-Path ([System.IO.Path]::GetTempPath()) ('ue-agent-template-scaffold-' + $testId)
}
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
$maxName = 'P' + $testId + ('x' * 7)
$maxRun = $testId + ('a' * 32)
$maxNameOutputPath = Join-Path $productionRoot ('{0}_{1}' -f $maxName, $maxRun)
$pathBudgetMaterializedName = 'PthM_' + $testId + 'mmm'

$midFailName = "Mid_$testId"
$lateFailName = "Late_$testId"
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

	("PthB_ok1_$testId"),
	("PthB_eq1_$testId"),
	("PthB_no1_$testId"),
	(('{0}_' + $testId) -f ('PthM_' + $testId + 'mmm')),
	('{0}_{1}' -f $maxName, $maxRun),
	('{0}_{1}' -f $maxName, ($testId + ('b' * 32)))

	"Sz_${testId}_$testId-a"

	"${midFailName}_$testId-retry"
)
$outputPaths = @($outputNames | ForEach-Object { Join-Path $productionRoot $_ })
$ledgerRoot = Join-Path (Join-Path $productionRoot '.runs') ("run_$ledgerRunId")

function Assert-True([bool]$Condition, [string]$Message) {
	if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Get-StagingResidue([string]$Root, [string]$Run) {
	# Staging names carry the run id, so a leftover is attributable to the run that failed to clean up.
	return @(Get-ChildItem -LiteralPath $Root -Force -Filter ('.stage-{0}-*' -f $Run) | ForEach-Object { $_.Name })
}

function Assert-NoStagingResidue([string]$Root, [string]$Run) {
	$residue = @(Get-StagingResidue -Root $Root -Run $Run)
	Assert-True ($residue.Count -eq 0) "a stopped run removes its own staging directory (found: $($residue -join ', '))"
}

function Invoke-GeneratorAt([string]$GeneratorPath, [string]$EngineRootPath, [string]$RecipeName, [string]$Name, [string]$Run, [string[]]$Diff) {
	& $GeneratorPath -Recipe $RecipeName -ProjectName $Name -RunId $Run -EngineRoot $EngineRootPath -ProjectDiff $Diff -AllowDirtyTemplate -MaxPathLength 32767 -SkipTemplatePublishCheck | Out-Null
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
	# A crashed run can also leave its own staging directory behind. That is not a published project,
	# but it is still residue this suite must not tolerate, and `git status` cannot see it either.
	$stagingPattern = '^\.stage-[A-Za-z0-9_-]*' + [regex]::Escape($testId) + '[A-Za-z0-9_-]*-[0-9a-f]{32}$'
	if (-not (Test-Path -LiteralPath $productionRoot -PathType Container)) {
		$violations.Add('Production/: the directory is missing')
		return $violations.ToArray()
	}
	if (-not (Test-Path -LiteralPath (Join-Path $productionRoot 'PLACEHOLDER.md') -PathType Leaf)) {
		$violations.Add('Production/PLACEHOLDER.md: the tracked placeholder is missing')
	}
	foreach ($entry in @(Get-ChildItem -LiteralPath $productionRoot -Force)) {
		if ($allowed -contains $entry.Name) { continue }
		if ($entry.Name -cnotmatch $suiteOwnedPattern -and $entry.Name -cnotmatch $stagingPattern) { continue }
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
        MaxPathLength = 32767
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
        MaxPathLength = 32767
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
}


function Invoke-Generator([string]$RecipeName, [string]$Name, [string]$Run, [string[]]$Diff, [int]$MaxPathLength = 32767) {
	& $generator -Recipe $RecipeName -ProjectName $Name -RunId $Run -EngineRoot $fixtureEngine -ProjectDiff $Diff -AllowDirtyTemplate -SkipTemplatePublishCheck -MaxPathLength $MaxPathLength | Out-Null
}

function Invoke-GeneratorCaptured([string]$RecipeName, [string]$Name, [string]$Run, [string[]]$Diff, [int]$MaxPathLength) {
	return (& $generator -Recipe $RecipeName -ProjectName $Name -RunId $Run -EngineRoot $fixtureEngine -ProjectDiff $Diff -AllowDirtyTemplate -SkipTemplatePublishCheck -MaxPathLength $MaxPathLength) -join "`n"
}

function Invoke-GeneratorNoBudget([string]$RecipeName, [string]$Name, [string]$Run, [string[]]$Diff) {
	# No -MaxPathLength at all: this is the case an agent hits by following the documented example.
	& $generator -Recipe $RecipeName -ProjectName $Name -RunId $Run -EngineRoot $fixtureEngine -ProjectDiff $Diff -AllowDirtyTemplate -SkipTemplatePublishCheck | Out-Null
}

function Read-FixtureLock([string]$OutputPath) {
	return [System.IO.File]::ReadAllText((Join-Path $OutputPath 'template-lock.json'))

}

function Invoke-ScaffoldGenerator {
	# Same invocation, but keeps the warning stream and the thrown message so a group can assert on what
	# the generator reported instead of only on exit 0.
	param(
		[string]$GeneratorPath,
		[string]$RecipeName,
		[string]$Name,
		[string]$RunId,
		[string]$EngineRoot,
		[string[]]$Diff = @()
	)
	$found = @()
	$failure = ''
	try {
		# 3>&1 keeps warning records as objects so a group can assert on what the generator reported;
		# without it the warning stream is only displayed.
		$found = @(& $GeneratorPath -Recipe $RecipeName -ProjectName $Name -RunId $RunId -EngineRoot $EngineRoot -ProjectDiff $Diff -AllowDirtyTemplate -MaxPathLength 32767 -SkipTemplatePublishCheck 3>&1)
	} catch {
		$failure = $_.Exception.Message
	}
	return [pscustomobject]@{
		Failure  = $failure
		Output   = @($found | Where-Object { $_ -is [string] } | ForEach-Object { [string]$_ })
		Warnings = @($found | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
	}
}

function Write-FixtureRulesTemplate([string]$TemplateRoot, [string]$TemplateName, [string[]]$DefsLines) {
	# A materialize fixture with real Modules/Source shape, one C++ module, a .ini whose file name and
	# contents are distinguishable, and a .cfg the rules never declare.
	[System.IO.Directory]::CreateDirectory($TemplateRoot) | Out-Null
	Write-FixtureJson (Join-Path $TemplateRoot ($TemplateName + '.uproject')) ('{"FileVersion":3,"EngineAssociation":"","Modules":[{"Name":"' + $TemplateName + '","Type":"Runtime"}],"Plugins":[]}')
	[System.IO.Directory]::CreateDirectory((Join-Path $TemplateRoot 'Config')) | Out-Null
	[System.IO.File]::WriteAllText((Join-Path $TemplateRoot 'Config\TemplateDefs.ini'), (($DefsLines -join "`r`n") + "`r`n"), [System.Text.UTF8Encoding]::new($false))
	Write-FixtureJson (Join-Path $TemplateRoot ('Source\' + $TemplateName + '\' + $TemplateName + '.Build.cs')) ('public class {0} : ModuleRules {{ }} // {0}_API' -f $TemplateName)
	Write-FixtureJson (Join-Path $TemplateRoot ('Source\' + $TemplateName + '\Private\' + $TemplateName + '.cpp')) ('// {0} module impl' -f $TemplateName)
	Write-FixtureJson (Join-Path $TemplateRoot ('Config\' + $TemplateName + '.ini')) ('Setting={0} {1} {2}' -f $TemplateName, $TemplateName.ToUpperInvariant(), $TemplateName.ToLowerInvariant())
	Write-FixtureJson (Join-Path $TemplateRoot 'Config\Extra.cfg') 'Marker=Zzz_NoSuchSymbol'
	Write-FixtureJson (Join-Path $TemplateRoot 'Config\DefaultEngine.ini') "[/Script/EngineSettings.GameMapsSettings]`r`nGameDefaultMap=/Engine/Maps/Templates/Template_Default.Template_Default`r`n"
	Write-FixtureJson (Join-Path $TemplateRoot 'Config\DefaultGame.ini') "[/Script/EngineSettings.GeneralProjectSettings]`r`nProjectID=(A=1,B=2,C=3,D=4)`r`nProjectName=Rules Template`r`n"
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

function New-RecipeFixtureRepository([string]$Name, [string]$Revision) {
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
	& $repositoryGenerator -Recipe $RecipeName -ProjectName $Name -RunId $Run -EngineRoot $fixtureEngine -ProjectDiff $Diff -AllowDirtyTemplate -MaxPathLength 32767 -SkipTemplatePublishCheck | Out-Null
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

function Add-SetDifference($Problems, $Actual, $Expected, [string]$MissingMessage, [string]$ExtraMessage) {
	foreach ($item in $Expected) {
		if (-not ($Actual -contains $item)) { $Problems.Add(($MissingMessage -f $item)) }
	}
	foreach ($item in $Actual) {
		if (-not ($Expected -contains $item)) { $Problems.Add(($ExtraMessage -f $item)) }
	}
}

function Get-DeliveryContractProblems {
	# Resolves the delivery set that docs/06-delivery.md declares: every deliverable it names must appear
	# in the AGENTS.md folder contract, every template it points at must exist, and the receipt fields that
	# bind the delivered README to one build must be defined. The repository is passed in so the suite can
	# point this gate at an isolated fixture and prove it fails when templates/README.md is removed.
	param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
	$problems = New-Object System.Collections.Generic.List[string]
	$requiredDeliverables = @('README.md', 'CREDITS.md', 'QA.md', 'DELIVERY.json', 'SHA256SUMS.txt')
	$requiredTemplates = @('templates/README.md', 'templates/CREDITS.md', 'templates/QA.md', 'templates/DELIVERY.json')
	$deliveryDoc = Join-Path $RepositoryRoot 'docs\06-delivery.md'
	$agentsFile = Join-Path $RepositoryRoot 'AGENTS.md'
	$qaTemplate = Join-Path $RepositoryRoot 'templates\QA.md'
	$deliveryTemplate = Join-Path $RepositoryRoot 'templates\DELIVERY.json'
	if (-not (Test-Path -LiteralPath $deliveryDoc -PathType Leaf)) {
		$problems.Add('docs/06-delivery.md: the delivery set document is missing')
		return $problems.ToArray()
	}
	$documentedNames = New-Object System.Collections.Generic.List[string]
	$documentedTemplates = New-Object System.Collections.Generic.List[string]
	foreach ($line in [System.IO.File]::ReadAllLines($deliveryDoc)) {
		$trimmedLine = $line.Trim()
		if (-not $trimmedLine.StartsWith('|')) { continue }
		$cells = @($trimmedLine.Trim('|').Split('|') | ForEach-Object { $_.Trim() })
		if ($cells.Count -lt 2) { continue }
		$separatorOnly = $true
		foreach ($cell in $cells) {
			if ($cell -notmatch '^[-: ]{3,}$') { $separatorOnly = $false; break }
		}
		if ($separatorOnly) { continue }
		$rowNames = New-Object System.Collections.Generic.List[string]
		$rowTemplates = New-Object System.Collections.Generic.List[string]
		foreach ($cell in $cells) {
			foreach ($token in @([regex]::Matches($cell, '[^`\s]+') | ForEach-Object { $_.Value })) {
				if ($token -match '^templates/[A-Za-z0-9._/-]+$') { $documentedTemplates.Add($token); $rowTemplates.Add($token) }
				elseif ($token -match '^[A-Za-z0-9_.-]+\.(md|json|txt)$') { $documentedNames.Add($token); $rowNames.Add($token) }
			}
		}
		foreach ($template in $rowTemplates) {
			$templateName = [IO.Path]::GetFileName($template)
			if ($rowNames -notcontains $templateName) { $problems.Add("docs/06-delivery.md: the row that points at $template does not place $templateName") }
		}
	}
	Add-SetDifference $problems $documentedNames $requiredDeliverables 'docs/06-delivery.md: the delivery set does not name {0}' 'docs/06-delivery.md: names {0}, which is not part of the delivery set'
	Add-SetDifference $problems $documentedTemplates $requiredTemplates 'docs/06-delivery.md: the delivery set does not point {0} at a template' 'docs/06-delivery.md: points at {0}, which is not a delivery template'
	foreach ($templateRef in $requiredTemplates) {
		$templatePath = Join-Path $RepositoryRoot ($templateRef.Replace('/', '\'))
		if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
			$problems.Add(($templateRef + ': the delivery set names it but the file is missing'))
		}
	}
	$listingTokens = $null
	if (-not (Test-Path -LiteralPath $agentsFile -PathType Leaf)) {
		$problems.Add('AGENTS.md: missing')
	} else {
		foreach ($line in [System.IO.File]::ReadAllLines($agentsFile)) {
			$trimmedLine = $line.Trim()
			if ($trimmedLine -match '^[A-Za-z0-9_.-]+\.md(\s+[A-Za-z0-9_.-]+\.(md|json|txt))*\s*$' -and $trimmedLine.Contains('SHA256SUMS.txt')) {
				$listingTokens = @($trimmedLine -split '\s+')
				break
			}
		}
	}
	if ($null -eq $listingTokens) {
		$problems.Add('AGENTS.md: the Out/run_<runid>/ delivery listing is missing')
	} else {
		Add-SetDifference $problems $listingTokens $requiredDeliverables 'AGENTS.md: the Out/run_<runid>/ listing does not include {0}' 'AGENTS.md: the Out/run_<runid>/ listing includes {0}, which the delivery set does not name'
	}
	if (-not (Test-Path -LiteralPath $deliveryTemplate -PathType Leaf)) {
		$problems.Add('templates/DELIVERY.json: the delivery manifest template is missing')
	} else {
		$deliveryData = $null
		try { $deliveryData = [System.IO.File]::ReadAllText($deliveryTemplate) | ConvertFrom-Json } catch { $problems.Add('templates/DELIVERY.json: not valid JSON (' + $_.Exception.Message + ')') }
		if ($null -eq $deliveryData) { $problems.Add('templates/DELIVERY.json: empty or null manifest') }
		if ($null -ne $deliveryData) {
			$requiredFields = @($deliveryData.artifact_required_fields)
			if (-not ($requiredFields -contains 'kind')) { $problems.Add('templates/DELIVERY.json: artifact_required_fields does not require the kind field') }
			$kinds = @($deliveryData.artifact_kind_vocabulary)
			if ($kinds.Count -eq 0) { $problems.Add('templates/DELIVERY.json: artifact_kind_vocabulary does not define any kind value') }
			elseif (-not ($kinds -contains 'readme')) { $problems.Add('templates/DELIVERY.json: artifact_kind_vocabulary does not define the readme kind') }
			if ($null -eq $deliveryData.readme_receipt) {
				$problems.Add('templates/DELIVERY.json: readme_receipt is missing')
			} else {
				$receiptFields = @($deliveryData.readme_receipt.PSObject.Properties.Name)
				if ($deliveryData.readme_receipt.required -ne $true) { $problems.Add('templates/DELIVERY.json: readme_receipt must remain required') }
				foreach ($receiptField in @('filename', 'sha256', 'version_sha256')) {
					if (-not ($receiptFields -contains $receiptField)) { $problems.Add('templates/DELIVERY.json: readme_receipt does not carry ' + $receiptField) }
				}
			}
		}
	}
	if (-not (Test-Path -LiteralPath $qaTemplate -PathType Leaf)) {
		$problems.Add('templates/QA.md: the QA template is missing')
	} else {
		$readmeRow = $false
		foreach ($line in [System.IO.File]::ReadAllLines($qaTemplate)) {
			$trimmedLine = $line.Trim()
			if ($trimmedLine.StartsWith('|') -and $trimmedLine.Contains('README') -and $trimmedLine.Contains('readme_receipt') -and $trimmedLine.Contains('SHA')) { $readmeRow = $true; break }
		}
		if (-not $readmeRow) { $problems.Add('templates/QA.md: no row checks that the delivered README points at the same build') }
	}
	return $problems.ToArray()

}

function Get-GeneratorFailure([scriptblock]$Action) {
	# Returns the exact stop message, so a negative case can prove *which* guard fired instead of
	# only that something failed.
	try { & $Action; return '' } catch { return $_.Exception.Message }
}

function Get-DirectoryFileSet([string]$Path) {
	# path=sha256 pairs, sorted: proves a directory a failed run must not touch kept its exact file set.
	@(Get-ChildItem -LiteralPath $Path -Recurse -File -Force | ForEach-Object {
		$_.FullName.Substring($Path.Length + 1).Replace('\', '/') + '=' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
	} | Sort-Object)

}

function Get-CppCodeOnly([string]$Text) {
	# A comment or a string literal that mentions IMPLEMENT_MODULE is not an entry point: commenting
	# the macro out is one of the ways a module silently loses its entry point, so the scan reads
	# only the code. One pass with alternation keeps the remaining text in order.
	# Limits (deliberate): `#if 0` regions and raw string literals are not parsed, so a module whose
	# only entry point sits inside a disabled block is still accepted.
	$pattern = '(?s)(?<raw>R"(?<delimiter>[^ ()\\	
]{0,16})\([\s\S]*?\)\k<delimiter>")|(?<block>/\*.*?\*/)|(?<line>//[^\r\n]*)|(?<string>"(?:\\.|[^"\\\r\n])*")|(?<char>''(?:\\.|[^''\\\r\n])*'')'
	return [regex]::Replace($Text, $pattern, '')
}

function Get-PluginModuleEntryPointViolations([string]$PluginRoot) {
	# A `.uplugin` declares the modules UE creates, and each of them needs the entry point that
	# IMPLEMENT_MODULE generates (Engine/Source/Runtime/Core/.../ModuleManager.h/.cpp); a module
	# without one produces a DLL that fails to initialize at load. The check reads file *contents*
	# because the engine convention does not fix the file name
	# (AudioCapture/Private/AudioCapture.cpp holds IMPLEMENT_MODULE(FAudioCaptureModule, AudioCapture)).
	$violations = New-Object System.Collections.Generic.List[string]
	$descriptors = @(Get-ChildItem -LiteralPath $PluginRoot -Filter '*.uplugin' -File)
	if ($descriptors.Count -eq 0) {
		$violations.Add(("{0}: no .uplugin descriptor was found" -f $PluginRoot))
		return $violations.ToArray()
	}
	if ($descriptors.Count -gt 1) {
		$violations.Add(('{0}: {1} .uplugin descriptors; the module contract is ambiguous' -f $PluginRoot, $descriptors.Count))
		return $violations.ToArray()
	}
	$descriptor = [System.IO.File]::ReadAllText($descriptors[0].FullName) | ConvertFrom-Json
	$declaredModules = @($descriptor.Modules | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.Name })
	$sourceRoot = Join-Path $PluginRoot 'Source'
	$sourceFiles = @()
	if (Test-Path -LiteralPath $sourceRoot -PathType Container) {
		$sourceFiles = @(Get-ChildItem -LiteralPath $sourceRoot -Filter '*.cpp' -File -Recurse | Sort-Object FullName)
	}
	$entryPoints = New-Object System.Collections.Generic.List[object]
	foreach ($sourceFile in $sourceFiles) {
		$text = Get-CppCodeOnly ([System.IO.File]::ReadAllText($sourceFile.FullName))
		foreach ($match in [regex]::Matches($text, 'IMPLEMENT_MODULE\s*\(\s*(?<implementation>[A-Za-z_][A-Za-z0-9_:]*)\s*,\s*(?<module>[A-Za-z_][A-Za-z0-9_]*)\s*\)')) {
			$entryPoints.Add([pscustomobject]@{
				Module = $match.Groups['module'].Value
				Implementation = $match.Groups['implementation'].Value
				File = $sourceFile.FullName
			})
		}
	}
	foreach ($moduleName in $declaredModules) {
		$matching = @($entryPoints | Where-Object { $_.Module -ceq $moduleName })
		if ($matching.Count -eq 0) {
			$violations.Add(("{0} declares module '{1}' but no .cpp under {2} holds IMPLEMENT_MODULE(<class>, {1})" -f $descriptors[0].Name, $moduleName, $sourceRoot))
		} elseif ($matching.Count -gt 1) {
			$violations.Add(("{0} declares module '{1}' and {2} .cpp files hold an IMPLEMENT_MODULE entry point for it" -f $descriptors[0].Name, $moduleName, $matching.Count))
		}
	}
	foreach ($entryPoint in $entryPoints) {
		if ($declaredModules -notcontains $entryPoint.Module) {
			$relativePath = $entryPoint.File.Replace($PluginRoot + [System.IO.Path]::DirectorySeparatorChar, '')
			$violations.Add(("{0} holds IMPLEMENT_MODULE({1}, {2}) but {3} declares modules '{4}'; the entry point name must equal the declared module name" -f $relativePath, $entryPoint.Implementation, $entryPoint.Module, $descriptors[0].Name, ($declaredModules -join ',')))
		}
	}
	return $violations.ToArray()

}
$canonicalProjectSettingsSection = '/Script/EngineSettings.GeneralProjectSettings'

function Get-DefaultGameSectionEntries([string]$ProjectOutput) {
	# Returns every ProjectID / ProjectName line of the generated Config/DefaultGame.ini with the section
	# header it sits under. Body-only matching cannot tell an effective identity from a stray one, which
	# is exactly how the old suite passed while '[ProjectSettings]' was still in place.
	$gameIniPath = Join-Path $ProjectOutput 'Config\DefaultGame.ini'
	if (-not (Test-Path -LiteralPath $gameIniPath -PathType Leaf)) { return @() }
	$entries = New-Object 'System.Collections.Generic.List[object]'
	$section = ''
	foreach ($line in [System.IO.File]::ReadAllLines($gameIniPath)) {
		$trimmed = $line.Trim()
		if ($trimmed -match '^\[(.+)\]$') { $section = $Matches[1].Trim(); continue }
		if ($trimmed -match '^(ProjectID|ProjectName)[ \t]*=[ \t]*(.*)$') {
			$entries.Add([pscustomobject]@{ Section = $section; Key = $Matches[1]; Value = $Matches[2].Trim() })
		}
	}
	return $entries.ToArray()
}

function Get-ShortHeaderIdentitySection([string]$ProjectOutput) {
	# Names every section other than the canonical one that still declares a project identity key.
	return @(Get-DefaultGameSectionEntries $ProjectOutput | Where-Object { $_.Section -ine $canonicalProjectSettingsSection } | ForEach-Object { $_.Section })
}

function Assert-ProjectIdentity([string]$ProjectOutput, [string]$Name, [string]$Label) {
	# One assertion block for all three recipes: the identity exists, it is under the only section name
	# the engine resolves, no short-header copy survives, and the lock records the same values.
	$gameIniPath = Join-Path $ProjectOutput 'Config\DefaultGame.ini'
	Assert-True (Test-Path -LiteralPath $gameIniPath -PathType Leaf) "${Label}: the generated project ships Config/DefaultGame.ini"
	$entries = @(Get-DefaultGameSectionEntries $ProjectOutput)
	Assert-True ($entries.Count -eq 2) "${Label}: DefaultGame.ini declares exactly one ProjectID and one ProjectName"
	Assert-True ($entries[0].Key -eq 'ProjectID' -and $entries[0].Section -ceq $canonicalProjectSettingsSection) "${Label}: ProjectID sits under $canonicalProjectSettingsSection"
	Assert-True ($entries[1].Key -eq 'ProjectName' -and $entries[1].Section -ceq $canonicalProjectSettingsSection) "${Label}: ProjectName sits under $canonicalProjectSettingsSection"
	Assert-True ($entries[1].Value -ceq $Name) "${Label}: ProjectName is the generated project name, not the template's"
	Assert-True ($entries[0].Value -match '^\(A=-?[0-9]+,B=-?[0-9]+,C=-?[0-9]+,D=-?[0-9]+\)$') "${Label}: ProjectID is a full FGuid string"
	$shortSections = @(Get-ShortHeaderIdentitySection $ProjectOutput)
	Assert-True ($shortSections.Count -eq 0) ("${Label}: no project identity is left under a short section header (found: " + ($shortSections -join ', ') + ')')
	$lockData = [System.IO.File]::ReadAllText((Join-Path $ProjectOutput 'template-lock.json')) | ConvertFrom-Json
	$lockIdentity = $lockData.default_game_ini_identity
	Assert-True ($null -ne $lockIdentity) "${Label}: template-lock.json records the DefaultGame.ini identity"
	Assert-True ($lockIdentity.section -ceq $canonicalProjectSettingsSection) "${Label}: lock records the canonical section name"
	Assert-True ($lockIdentity.project_id -ceq $entries[0].Value) "${Label}: lock ProjectID matches the generated DefaultGame.ini"
	Assert-True ($lockIdentity.project_name -ceq $Name) "${Label}: lock ProjectName is the generated project name"
	return $entries[0].Value
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
	# The installed TP_FirstPerson ships its identity under the short '[ProjectSettings]' header, which
	# UGeneralProjectSettings never reads (its UCLASS has config=Game and no OverrideConfigSection). The
	# fixture carries that file so the suite cannot pass through the old 'no Config/ directory' gap: a
	# generated project that keeps this header declares an identity the engine ignores.
	Write-FixtureJson (Join-Path $firstPersonTemplate 'Config\DefaultGame.ini') ("[ProjectSettings]`r`nProjectID=(A=1823396784,B=1298598689,C=1743498150,D=-2048051708)`r`nProjectName=First Person Template`r`n")

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
	# TP_BlankBP ships a 2 byte DefaultGame.ini (CRLF only): no identity block at all.
	Write-FixtureJson (Join-Path $blankTemplate 'Config\DefaultGame.ini') "`r`n"

	$thirdPersonTemplate = Join-Path $fixtureEngine 'Templates\TP_ThirdPerson'
	# The installed TP_ThirdPerson descriptor enables three plugins of its own. The fixture keeps that
	# shape so the suite exercises a project whose plugin set is wider than the recipe's
	# required_plugins; a fixture that enables nothing cannot tell the two sets apart.
	Write-FixtureJson (Join-Path $thirdPersonTemplate 'TP_ThirdPerson.uproject') '{"FileVersion":3,"EngineAssociation":"","Modules":[{"Name":"TP_ThirdPerson","Type":"Runtime"}],"Plugins":[{"Name":"ModelingToolsEditorMode","Enabled":true,"TargetAllowList":["Editor"]},{"Name":"StateTree","Enabled":true},{"Name":"GameplayStateTree","Enabled":true}]}'
	Write-FixtureJson (Join-Path $thirdPersonTemplate 'Config\TemplateDefs.ini') (@(
		'[/Script/GameProjectGeneration.TemplateProjectDefs]',
		'FoldersToIgnore=Media',
		'FoldersToIgnore=Content/ThirdPerson/Animations',
		'FilesToIgnore="%TEMPLATENAME%.uproject"',
		'FilesToIgnore="Config/TemplateDefs.ini"',
		'FilesToIgnore="Config/config.ini"',
		'FolderRenames=(From="Source/%TEMPLATENAME%",To="Source/%PROJECTNAME%")',
		'FilenameReplacements=(Extensions=("cpp","h","ini","cs"),From="%TEMPLATENAME_UPPERCASE%",To="%PROJECTNAME_UPPERCASE%",bCaseSensitive=true)',
		'FilenameReplacements=(Extensions=("cpp","h","ini","cs"),From="%TEMPLATENAME_LOWERCASE%",To="%PROJECTNAME_LOWERCASE%",bCaseSensitive=true)',
		'FilenameReplacements=(Extensions=("cpp","h","ini","cs"),From="%TEMPLATENAME%",To="%PROJECTNAME%",bCaseSensitive=false)',
		'ReplacementsInFiles=(Extensions=("cpp","h","ini","cs"),From="%TEMPLATENAME_UPPERCASE%",To="%PROJECTNAME_UPPERCASE%",bCaseSensitive=true)',
		'ReplacementsInFiles=(Extensions=("cpp","h","ini","cs"),From="%TEMPLATENAME_LOWERCASE%",To="%PROJECTNAME_LOWERCASE%",bCaseSensitive=true)',
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
		@{ Name = 'MovieRenderPipeline'; RelativePath = 'Engine\Plugins\MovieScene\MovieRenderPipeline\MovieRenderPipeline.uplugin'; Version = '1.0' },
		# The three plugins the TP_ThirdPerson template enables. Two sit directly under a category
		# directory like the installed engine, one sits a level deeper, so the resolution has to walk
		# the category directories and then fall back to a recursive scan.
		@{ Name = 'ModelingToolsEditorMode'; RelativePath = 'Engine\Plugins\Editor\ModelingToolsEditorMode\ModelingToolsEditorMode.uplugin'; Version = '0.1' },
		@{ Name = 'StateTree'; RelativePath = 'Engine\Plugins\Runtime\StateTree\StateTree.uplugin'; Version = '0.1' },
		@{ Name = 'GameplayStateTree'; RelativePath = 'Engine\Plugins\Runtime\AI\GameplayStateTree\GameplayStateTree.uplugin'; Version = '1.0' }
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
		& $dirtyGenerator -MaxPathLength 32767 -Recipe 'spectator-explore' -ProjectName $dirtyProjectName -RunId 'dirty-rejected' -EngineRoot $fixtureEngine -ProjectDiff @() -SkipTemplatePublishCheck | Out-Null
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
	& $provGenerator -MaxPathLength 32767 -Recipe 'spectator-explore' -ProjectName $provPublishedName -RunId "$testId-pub" -EngineRoot $fixtureEngine -ProjectDiff @() | Out-Null
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
		& $provGenerator -MaxPathLength 32767 -Recipe 'spectator-explore' -ProjectName $provUnpublishedName -RunId "$testId-default" -EngineRoot $fixtureEngine -ProjectDiff @() | Out-Null
	} catch {
		$provUnpublishedFailure = $_.Exception.Message
	}
	Assert-True ($provUnpublishedFailure.Contains('is not retrievable from the recorded template repository')) 'an unpushed template commit stops generation by default'
	Assert-True (-not (Test-Path -LiteralPath $provUnpublishedDefaultOutput)) 'the unpublished stop writes no project'
	$provUnpublishedAllowedOutput = Join-Path (Join-Path $provTemplateRoot 'Production') "${provUnpublishedName}_$testId-allowed"
	& $provGenerator -MaxPathLength 32767 -Recipe 'spectator-explore' -ProjectName $provUnpublishedName -RunId "$testId-allowed" -EngineRoot $fixtureEngine -ProjectDiff @() -AllowUnpublishedTemplate | Out-Null
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
		& $provNoRemoteGenerator -MaxPathLength 32767 -Recipe 'spectator-explore' -ProjectName $provNoRemoteName -RunId "$testId-default" -EngineRoot $fixtureEngine -ProjectDiff @() | Out-Null
	} catch {
		$provNoRemoteFailure = $_.Exception.Message
	}
	Assert-True ($provNoRemoteFailure.Contains("has no 'origin' remote")) 'a checkout without an origin stops the default path'
	Assert-True (($provNoRemoteFailure.Contains('no-remote') -or $provNoRemoteFailure.Contains('no-origin'))) 'the no-remote stop reports which source kind it saw'
	Assert-True (-not (Test-Path -LiteralPath $provNoRemoteDefaultOutput)) 'the no-remote stop writes no project'
	$provNoRemoteAllowedOutput = Join-Path (Join-Path $provNoRemoteRoot 'Production') "${provNoRemoteName}_$testId-allowed"
	& $provNoRemoteGenerator -MaxPathLength 32767 -Recipe 'spectator-explore' -ProjectName $provNoRemoteName -RunId "$testId-allowed" -EngineRoot $fixtureEngine -ProjectDiff @() -AllowUnpublishedTemplate | Out-Null
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
		& $provBundleGenerator -MaxPathLength 32767 -Recipe 'spectator-explore' -ProjectName $provBundleName -RunId "$testId-default" -EngineRoot $fixtureEngine -ProjectDiff @() | Out-Null
	} catch {
		$provBundleFailure = $_.Exception.Message
	}
	Assert-True ($provBundleFailure.Contains('offline hand-off file')) 'a bundle clone stops the default path because a bundle cannot establish a published commit'
	Assert-True (-not (Test-Path -LiteralPath $provBundleDefaultOutput)) 'the bundle stop writes no project'
	$provBundleAllowedOutput = Join-Path (Join-Path $provBundleClone 'Production') "${provBundleName}_$testId-allowed"
	& $provBundleGenerator -MaxPathLength 32767 -Recipe 'spectator-explore' -ProjectName $provBundleName -RunId "$testId-allowed" -EngineRoot $fixtureEngine -ProjectDiff @() -AllowUnpublishedTemplate | Out-Null
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
	# The descriptor declaring a module is not the same as the module being loadable: UE builds every
	# declared C++ module with a forced `IMPLEMENT_MODULE_<Name>` reference and fails the plugin at
	# load when the entry point is absent. Assert both the repository template and the generated copy.
	$templateEntryPointViolations = @(Get-PluginModuleEntryPointViolations (Join-Path $repoRoot 'templates\online\MulticaOnlineStarter'))
	Assert-True ($templateEntryPointViolations.Count -eq 0) ('repository plugin declares every module with a matching IMPLEMENT_MODULE entry point: ' + ($templateEntryPointViolations -join '; '))
	$generatedEntryPointViolations = @(Get-PluginModuleEntryPointViolations (Join-Path $firstOutput 'Plugins\MulticaOnlineStarter'))
	Assert-True ($generatedEntryPointViolations.Count -eq 0) ('the generated plugin copy carries a matching IMPLEMENT_MODULE entry point for every declared module: ' + ($generatedEntryPointViolations -join '; '))
	$generatedModuleCpp = @(Get-ChildItem -LiteralPath (Join-Path $pluginDirectory 'Source') -Filter '*.cpp' -File -Recurse | Where-Object { (Get-CppCodeOnly ([System.IO.File]::ReadAllText($_.FullName))) -match 'IMPLEMENT_MODULE\s*\(\s*[A-Za-z_][A-Za-z0-9_:]*\s*,\s*MulticaOnlineStarter\s*\)' })
	Assert-True ($generatedModuleCpp.Count -eq 1) 'the generated project ships exactly one IMPLEMENT_MODULE entry point for MulticaOnlineStarter'
	# Repository-wide inventory: every .uplugin this repository ships must back its declared
	# module with an entry point, so a second plugin cannot reintroduce the same gap unnoticed.
	$repositoryPlugins = @(Get-ChildItem -LiteralPath $repoRoot -Filter '*.uplugin' -File -Recurse | Where-Object { $_.FullName -notmatch '\\(Production|\.git)\\' })
	Assert-True ($repositoryPlugins.Count -ge 1) 'the repository-wide module inventory finds at least one plugin descriptor'
	$inventoryViolations = @()
	foreach ($pluginDescriptor in $repositoryPlugins) {
		$inventoryViolations += @(Get-PluginModuleEntryPointViolations $pluginDescriptor.DirectoryName)
	}
	Assert-True ($inventoryViolations.Count -eq 0) ('every module declared by the repository .uplugin descriptors has a matching IMPLEMENT_MODULE entry point: ' + ($inventoryViolations -join '; '))
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
	Assert-True ($lockData.plugins.MulticaOnlineStarter.version -eq '1.0.2') 'lock records the project plugin version'
	Assert-True ($lockData.project_differences.Count -eq 2) 'lock records normalized project-specific differences'
	Assert-True ($lockData.schema_version -ge 4) 'lock declares at least the template-provenance schema version'
	Assert-True ($lockData.engine_changelist -eq 55116800) 'lock records the effective changelist UE derives from CompatibleChangelist'
	Assert-True ($lockData.engine_changelist_source -eq 'CompatibleChangelist') 'lock names CompatibleChangelist as the effective changelist source'
	Assert-True ($lockData.engine_changelist_raw -eq 58902052) 'lock keeps the raw Changelist exactly as the engine reported it'
	Assert-True ($lockData.engine_compatible_changelist -eq 55116800) 'lock records CompatibleChangelist'
	Assert-True ($lockData.engine_is_licensee_version -eq 0) 'lock records IsLicenseeVersion'
	Assert-True ($lockData.engine_is_promoted_build -eq 1) 'lock records IsPromotedBuild'
	Assert-True ($lockData.engine_branch_name -eq '++UE5+Release-5.8') 'lock records BranchName'

	Assert-True ($lockData.template_commit -match '^[0-9a-f]{40}$') 'lock records a full template commit SHA'
	Assert-True ($lockData.plugins.MulticaOnlineStarter.version -eq '1.0.2') 'lock records the project plugin version'
	Assert-True ($lockData.plugins.MulticaOnlineStarter.source -eq 'project') 'lock records the plugin payload the generated project actually loads'
	Assert-True ($lockData.plugins.MulticaOnlineStarter.enabled_in_project -eq $true) 'lock records that the project enables the plugin'
	$lockPluginNames = @($lockData.plugins.PSObject.Properties.Name)
	[Array]::Sort($lockPluginNames, [System.StringComparer]::Ordinal)
	$descriptorPluginNames = @($firstDescriptor.Plugins | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.Name })
	[Array]::Sort($descriptorPluginNames, [System.StringComparer]::Ordinal)
	Assert-True (($lockPluginNames -join ',') -ceq ($descriptorPluginNames -join ',')) 'lock records every plugin the generated project enables, and nothing else'
	Assert-True ($lockPluginNames.Count -eq 5) 'the online game recipe records all five plugins it enables'
	Assert-True ($lockData.project_differences.Count -eq 2) 'lock records normalized project-specific differences'
	Assert-True ($lockData.schema_version -ge 5) 'lock records the identity-bearing schema version'
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
	$firstProjectId = Assert-ProjectIdentity $firstOutput $projectName 'spectator-explore'
	$otherProjectId = Assert-ProjectIdentity $otherOutput $otherProjectName 'spectator-explore (other project name)'
	Assert-True ($firstProjectId -cne $otherProjectId) 'two projects generated from different names do not share one ProjectID'
	$secondProjectId = Assert-ProjectIdentity $secondOutput $projectName 'spectator-explore (same name, second run ID)'
	Assert-True ($firstProjectId -ceq $secondProjectId) 'regenerating the same project name reproduces the same ProjectID'
	$firstGameIni = [System.IO.File]::ReadAllText((Join-Path $firstOutput 'Config\DefaultGame.ini'))
	Assert-True (-not $firstGameIni.Contains('ProjectName=First Person Template')) 'the copied template ProjectName does not survive into the generated project'
	Assert-True (-not ([regex]::IsMatch($firstGameIni, '(?m)^\[ProjectSettings\][ \t]*\r?$'))) 'the short [ProjectSettings] header is not carried over from the template'
	$firstLockData = $firstLock | ConvertFrom-Json
	Assert-True ($firstLockData.default_game_ini_identity.normalized_from_section -ceq 'ProjectSettings') 'lock records which short header it normalized away'
	Assert-True ($firstLockData.default_game_ini_identity.created_section -eq $true) 'lock records that the canonical section had to be created because the template only had the short header'
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
	$loopLockPluginNames = @($loopLock.plugins.PSObject.Properties.Name)
	Assert-True (($loopLockPluginNames -join ',') -ceq 'MovieRenderPipeline') 'video-only lock records the same plugin set the generated descriptor enables'
	Assert-True ($loopLock.plugins.MovieRenderPipeline.enabled_in_project -eq $true -and $loopLock.plugins.MovieRenderPipeline.version -eq '1.0') 'video-only lock records the plugin version the install reports'

	Assert-ProjectIdentity $loopOutput $loopProjectName 'vertical-loop' | Out-Null
	Assert-True ($loopLock.default_game_ini_identity.created_section -eq $true) 'the identity-less TP_BlankBP template gets the canonical section created'
	Assert-True ($null -eq $loopLock.default_game_ini_identity.normalized_from_section) 'nothing had to be normalized for a template with no identity block'
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
	$materializedStdout = & $generator -Recipe 'third-person-game' -ProjectName "Sz_$testId" -RunId "$testId-a" -EngineRoot $fixtureEngine -ProjectDiff @() -AllowDirtyTemplate -MaxPathLength 32767 -SkipTemplatePublishCheck
	$sizeOutput = Join-Path $productionRoot "Sz_${testId}_$testId-a"
	Assert-True (($materializedStdout -join "`n") -match '(?m)^Class redirects: TP_ThirdPersonCharacter -> Sz_') 'the generator reports the class redirects it wrote'
	Assert-True (Test-Path -LiteralPath (Join-Path $sizeOutput 'Config\DefaultEngine.ini')) 'the reporting generator wrote its output'
	$tpGameIni = [System.IO.File]::ReadAllText((Join-Path $tpOutput 'Config\DefaultGame.ini'))
	Assert-True ($tpGameIni.Contains("ProjectName=$tpName") -and -not $tpGameIni.Contains('ProjectID=(A=1,B=2,C=3,D=4)')) 'materialized recipe gives the project its own name and ID'
	Assert-ProjectIdentity $tpOutput $tpName 'third-person-game' | Out-Null
	Assert-True ((([System.IO.File]::ReadAllText((Join-Path $tpOutput 'template-lock.json'))) | ConvertFrom-Json).default_game_ini_identity.normalized_from_section -eq $null) 'the materialized template already had the canonical header, so nothing was normalized'
	Assert-True (Test-Path -LiteralPath (Join-Path $tpOutput 'Recipe\Play.md')) 'third-person recipe has a play delta'
	$tpLock = [System.IO.File]::ReadAllText((Join-Path $tpOutput 'template-lock.json')) | ConvertFrom-Json
	Assert-True ($tpLock.engine_template -eq 'TP_ThirdPerson') 'lock records the third-person engine template'
	$tpLockPluginNames = @($tpLock.plugins.PSObject.Properties.Name)
	[Array]::Sort($tpLockPluginNames, [System.StringComparer]::Ordinal)
	$tpDescriptorPluginNames = @($tpDescriptor.Plugins | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.Name })
	[Array]::Sort($tpDescriptorPluginNames, [System.StringComparer]::Ordinal)
	Assert-True (($tpLockPluginNames -join ',') -ceq ($tpDescriptorPluginNames -join ',')) 'lock records the plugins the template enables, not only the recipe requirement'
	Assert-True ($tpLockPluginNames.Count -eq 4) 'the materialized recipe records the three template plugins and the one recipe plugin'
	foreach ($templatePlugin in @('ModelingToolsEditorMode', 'StateTree', 'GameplayStateTree')) {
		Assert-True ($tpLock.plugins.$templatePlugin.enabled_in_project -eq $true) "lock records the template plugin $templatePlugin as enabled"
		Assert-True (@('0.1', '1.0') -contains $tpLock.plugins.$templatePlugin.version) "lock records the version $templatePlugin's .uplugin reports instead of inventing one"
		Assert-True ($tpLock.plugins.$templatePlugin.source -eq 'engine') "lock records that $templatePlugin comes from the installed engine"
	}
	Assert-True ($tpLock.plugins.GameplayStateTree.version -eq '1.0') 'a plugin one directory deeper than its category is resolved, not recorded as unknown'
	Assert-True ($tpLock.plugins.StateTree.version -eq '0.1') 'a plugin directly under its category is resolved'
	Write-Output 'PASS: lock records every enabled plugin of the generated project with its resolved version'
	Assert-GeneratorFails { Invoke-Generator 'third-person-game' 'Bad-Name' "$testId-bad" @() } 'materialized recipe rejects non-identifier project names'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $productionRoot "Bad-Name_$testId-bad"))) 'invalid materialized project name creates no output'
	Write-Output 'PASS: third-person recipe materializes the official template with the implemented TemplateDefs.ini keys'

	# --- TemplateDefs.ini rule engine (DOT-3135) -----------------------------------------------
	# Each group below runs the materialize path in an isolated clone, because the fixture recipe has to
	# name the fixture template and the developer checkout must stay untouched.
	$rulesRepoRoot = Join-Path $fixtureRoot 'RulesTemplate'
	& git -C $repoRoot clone --quiet --local --no-hardlinks --no-tags --no-checkout $repoRoot $rulesRepoRoot
	if ($LASTEXITCODE -ne 0) { throw 'Could not create the isolated rules-repository fixture.' }
	& git -C $rulesRepoRoot checkout --quiet --detach $templateRevision
	if ($LASTEXITCODE -ne 0) { throw "Could not check out revision $templateRevision in the isolated rules-repository fixture." }
	[System.IO.Directory]::CreateDirectory((Join-Path $rulesRepoRoot 'Production')) | Out-Null
	$rulesGenerator = Join-Path $rulesRepoRoot 'scripts\New-UETemplateScaffold.ps1'
	Copy-Item -LiteralPath $generator -Destination $rulesGenerator -Force
	$rulesEngine = Join-Path $fixtureRoot 'RulesEngineRoot'
	Write-FixtureJson (Join-Path $rulesEngine 'Engine\Build\Build.version') '{"MajorVersion":5,"MinorVersion":8,"PatchVersion":4,"Changelist":58902052}'
	Write-FixtureJson (Join-Path $rulesEngine 'Engine\Plugins\MovieScene\MovieRenderPipeline\MovieRenderPipeline.uplugin') '{"FileVersion":3,"Version":1,"VersionName":"1.0"}'
	$rulesTemplateRoot = Join-Path $rulesEngine 'Templates'
	function Invoke-RulesCase {
		# One fixture template + one isolated run. Returns the generator's report and the output path
		# whether the run succeeded or stopped.
		param(
			[string]$TemplateName,
			[string[]]$DefsLines,
			[string]$ProjectName,
			[string]$RunId
		)
		Write-FixtureRulesTemplate (Join-Path $rulesTemplateRoot $TemplateName) $TemplateName $DefsLines
		Set-FixtureRecipeTemplate $rulesRepoRoot 'third-person-game' $TemplateName
		$report = Invoke-ScaffoldGenerator -GeneratorPath $rulesGenerator -RecipeName 'third-person-game' -Name $ProjectName -RunId $RunId -EngineRoot $rulesEngine -Diff @('Variant: Rules')
		return [pscustomobject]@{
			Report = $report
			Output = Join-Path (Join-Path $rulesRepoRoot 'Production') ("{0}_{1}" -f $ProjectName, $RunId)
		}
	}

	# FilenameReplacements and ReplacementsInFiles carry different extension lists here. A .cpp file name
	# must follow the first list (renamed), a .cpp body must follow the second (not rewritten), and a .ini
	# is in the second list only, so its body is rewritten while its file name is kept. The .ini body also
	# carries all three template-name spellings, which the declared case-sensitive UPPERCASE/lowercase
	# tuples must replace in declaration order.
	$asymTemplate = 'TP_AsymRules'
	$asymName = "Asym_$testId"
	$asym = Invoke-RulesCase -TemplateName $asymTemplate -ProjectName $asymName -RunId 'asym' -DefsLines @(
		'[/Script/GameProjectGeneration.TemplateProjectDefs]',
		'FoldersToIgnore=Media',
		'FilesToIgnore="%TEMPLATENAME%.uproject"',
		'FilesToIgnore="Config/TemplateDefs.ini"',
		'FolderRenames=(From="Source/%TEMPLATENAME%",To="Source/%PROJECTNAME%")',
		'FilenameReplacements=(Extensions=("cpp","cs"),From="%TEMPLATENAME%",To="%PROJECTNAME%",bCaseSensitive=false)',
		'ReplacementsInFiles=(Extensions=("ini","cs"),From="%TEMPLATENAME_UPPERCASE%",To="%PROJECTNAME_UPPERCASE%",bCaseSensitive=true)',
		'ReplacementsInFiles=(Extensions=("ini","cs"),From="%TEMPLATENAME_LOWERCASE%",To="%PROJECTNAME_LOWERCASE%",bCaseSensitive=true)',
		'ReplacementsInFiles=(Extensions=("ini","cs"),From="%TEMPLATENAME%",To="%PROJECTNAME%",bCaseSensitive=false)'
	)
	Assert-True ($asym.Report.Failure -eq '') ('asymmetric FilenameReplacements/ReplacementsInFiles lists generate: ' + $asym.Report.Failure)
	$asymBuildCs = Join-Path $asym.Output "Source\$asymName\$asymName.Build.cs"
	Assert-True (Test-Path -LiteralPath $asymBuildCs) 'FilenameReplacements renames the .Build.cs file name'
	$asymBuildText = [System.IO.File]::ReadAllText($asymBuildCs)
	Assert-True ($asymBuildText.Contains("class $asymName ") -and -not $asymBuildText.Contains($asymTemplate)) 'ReplacementsInFiles rewrites the .cs body (case-insensitive tuple)'
	$asymCpp = Join-Path $asym.Output "Source\$asymName\Private\$asymName.cpp"
	Assert-True (Test-Path -LiteralPath $asymCpp) 'FilenameReplacements renames the .cpp file name'
	Assert-True ([System.IO.File]::ReadAllText($asymCpp) -ceq "// $asymTemplate module impl") 'a .cpp outside ReplacementsInFiles keeps its body unreplaced'
	$asymIni = Join-Path $asym.Output "Config\$asymTemplate.ini"
	Assert-True (Test-Path -LiteralPath $asymIni) 'a .ini outside FilenameReplacements keeps its file name'
	$asymIniText = [System.IO.File]::ReadAllText($asymIni)
	Assert-True ($asymIniText -ceq ('Setting={0} {1} {2}' -f $asymName, $asymName.ToUpperInvariant(), $asymName.ToLowerInvariant())) 'a .ini inside ReplacementsInFiles has UPPERCASE, lowercase and any-case replaced in declaration order'
	Assert-True (-not $asymIniText.Contains($asymTemplate) -and -not $asymIniText.Contains($asymTemplate.ToUpperInvariant()) -and -not $asymIniText.Contains($asymTemplate.ToLowerInvariant())) 'no template-name spelling survives the declared case tuples'
	$asymCfg = Join-Path $asym.Output 'Config\Extra.cfg'
	Assert-True ([System.IO.File]::ReadAllText($asymCfg) -ceq 'Marker=Zzz_NoSuchSymbol') 'an extension neither rule declares is copied byte for byte'
	$asymLock = [System.IO.File]::ReadAllText((Join-Path $asym.Output 'template-lock.json')) | ConvertFrom-Json
	Assert-True (@($asymLock.template_defs.applied_keys) -contains 'FilenameReplacements' -and @($asymLock.template_defs.applied_keys) -contains 'ReplacementsInFiles') 'lock records both rule keys as applied'
	Write-Output 'PASS: FilenameReplacements renames file names while ReplacementsInFiles rewrites bodies, from separate extension lists'

	# From that matches nothing must replace nothing. The declared folder rename still applies, so the
	# run must stop at the identity check instead of publishing a tree whose module name no longer matches
	# its Build.cs. The partial output is left in place, which is where the unreplaced body is observed.
	$fromTemplate = 'TP_FromMismatch'
	$fromName = "From_$testId"
	$fromCase = Invoke-RulesCase -TemplateName $fromTemplate -ProjectName $fromName -RunId 'frommiss' -DefsLines @(
		'[/Script/GameProjectGeneration.TemplateProjectDefs]',
		'FilesToIgnore="Config/TemplateDefs.ini"',
		'FolderRenames=(From="Source/%TEMPLATENAME%",To="Source/%PROJECTNAME%")',
		'FilenameReplacements=(Extensions=("cpp","cs"),From="%TEMPLATENAME%",To="%PROJECTNAME%",bCaseSensitive=false)',
		'ReplacementsInFiles=(Extensions=("cpp","cs","ini"),From="Zzz_NoSuchSymbol",To="%PROJECTNAME%",bCaseSensitive=true)'
	)
	Assert-True ($fromCase.Report.Failure.Contains('Project identity check stopped')) 'a From that occurs nowhere does not rewrite the module name, so generation stops instead of publishing a mismatched tree'
	Assert-True ($fromCase.Report.Failure.Contains("Source/$fromName/$fromName.Build.cs")) 'the stop names the unmatched module path'
	# Atomic publication removes failed staging. Test the unchanged body through the very same
	# shipped transformation function, and separately require absence of a partial public output.
	$generatorAst = [System.Management.Automation.Language.Parser]::ParseFile($generator, [ref]$null, [ref]$null)
	$ruleFunction = $generatorAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-TemplateRules' }, $true)
	Invoke-Expression $ruleFunction.Extent.Text
	$noMatchRule = [pscustomobject]@{ Extensions=@('cpp'); From='Zzz_NoSuchSymbol'; To=$fromName; CaseSensitive=$true }
	Assert-True ((Invoke-TemplateRules -Text "// $fromTemplate module impl" -Rules @($noMatchRule) -Extension 'cpp') -ceq "// $fromTemplate module impl") 'a From that occurs nowhere replaces nothing in the file body'
	Assert-True (-not (Test-Path -LiteralPath $fromCase.Output)) 'identity failure publishes no partial tree'
	Write-Output 'PASS: a From that matches nothing replaces nothing and the identity mismatch stops the run'

	# Keys this generator does not implement (wizard metadata) are reported instead of dropped. The chosen
	# behaviour is warn-and-continue, because a real engine template carries them and a hard stop would
	# reject every installed template; the lock keeps the record of what was applied and what was ignored.
	$keysTemplate = 'TP_UnknownKeys'
	$keysName = "Keys_$testId"
	$keysCase = Invoke-RulesCase -TemplateName $keysTemplate -ProjectName $keysName -RunId 'keys' -DefsLines @(
		'[/Script/GameProjectGeneration.TemplateProjectDefs]',
		'Categories=Games',
		'LocalizedDisplayNames=(Language="en",Text="Rules Template")',
		'LocalizedDescriptions=(Language="en",Text="Rules Template description")',
		'bThumbnailAsIcon=true',
		'ClassTypes=Character, PlayerController',
		'AssetTypes=Animation Sequence, Skeleton',
		'SortKey=50',
		'Variants=(VariantName="Basic",Path="Maps/Basic")',
		'FilesToIgnore="Config/TemplateDefs.ini"',
		'FolderRenames=(From="Source/%TEMPLATENAME%",To="Source/%PROJECTNAME%")',
		'FilenameReplacements=(Extensions=("cpp","cs"),From="%TEMPLATENAME%",To="%PROJECTNAME%",bCaseSensitive=false)',
		'ReplacementsInFiles=(Extensions=("cpp","cs","ini"),From="%TEMPLATENAME%",To="%PROJECTNAME%",bCaseSensitive=false)'
	)
	Assert-True ($keysCase.Report.Failure -eq '') ('unknown TemplateDefs keys warn and continue: ' + $keysCase.Report.Failure)
	foreach ($unimplementedKey in @('Categories', 'LocalizedDisplayNames', 'Variants', 'bThumbnailAsIcon')) {
		Assert-True (@($keysCase.Report.Warnings | Where-Object { $_ -like "*$unimplementedKey*" }).Count -gt 0) "an unimplemented TemplateDefs key ($unimplementedKey) is reported, not dropped quietly"
	}
	$keysLock = [System.IO.File]::ReadAllText((Join-Path $keysCase.Output 'template-lock.json')) | ConvertFrom-Json
	foreach ($unimplementedKey in @('Categories', 'LocalizedDisplayNames', 'LocalizedDescriptions', 'bThumbnailAsIcon', 'ClassTypes', 'AssetTypes', 'SortKey', 'Variants')) {
		Assert-True (@($keysLock.template_defs.ignored_keys) -contains $unimplementedKey) "lock records $unimplementedKey as ignored"
	}
	foreach ($appliedKey in @('FolderRenames', 'FilenameReplacements', 'ReplacementsInFiles', 'FilesToIgnore')) {
		Assert-True (@($keysLock.template_defs.applied_keys) -contains $appliedKey) "lock records $appliedKey as applied"
		Assert-True (@($keysLock.template_defs.ignored_keys) -notcontains $appliedKey) "lock does not record the applied key $appliedKey as ignored"
	}
	Assert-True (@($keysLock.template_defs.unreadable_lines).Count -eq 0) 'every implemented key produced a rule in the unknown-key fixture'
	Write-Output 'PASS: unimplemented TemplateDefs.ini keys are warned about and recorded in the lock instead of being dropped'

	# A per-mount DetailLevel that differs from EditDetailLevelPreference must decide the search path. The
	# pack exists at Low only, so a generator using the template preference (High) would report it missing.
	$lowTemplate = 'TP_PerMountLow'
	$lowName = "Low_$testId"
	Write-FixtureJson (Join-Path $rulesEngine 'Templates\TemplateResources\Low\Characters\Content\Mannequins\SK_Low.uasset') 'low pack'
	$lowCase = Invoke-RulesCase -TemplateName $lowTemplate -ProjectName $lowName -RunId 'perlow' -DefsLines @(
		'[/Script/GameProjectGeneration.TemplateProjectDefs]',
		'FilesToIgnore="Config/TemplateDefs.ini"',
		'FolderRenames=(From="Source/%TEMPLATENAME%",To="Source/%PROJECTNAME%")',
		'FilenameReplacements=(Extensions=("cpp","cs"),From="%TEMPLATENAME%",To="%PROJECTNAME%",bCaseSensitive=false)',
		'ReplacementsInFiles=(Extensions=("cpp","cs","ini"),From="%TEMPLATENAME%",To="%PROJECTNAME%",bCaseSensitive=false)',
		'SharedContentPacks=(MountName="Characters",DetailLevels=("Low"))',
		'EditDetailLevelPreference="High"'
	)
	Assert-True ($lowCase.Report.Failure -eq '') ('a pack declared at Low is found when only Low exists: ' + $lowCase.Report.Failure)
	Assert-True (Test-Path -LiteralPath (Join-Path $lowCase.Output 'Content\Characters\Mannequins\SK_Low.uasset')) 'the Low pack content reaches Content/Characters'
	Assert-True (@($lowCase.Report.Warnings | Where-Object { $_ -like '*was declared for detail level*' }).Count -eq 0) 'a declared level that exists needs no fall back warning'
	$lowLock = [System.IO.File]::ReadAllText((Join-Path $lowCase.Output 'template-lock.json')) | ConvertFrom-Json
	$lowPack = @($lowLock.template_defs.shared_content_packs | Where-Object { $_.mount -eq 'Characters' })[0]
	Assert-True ($lowPack.detail_level -eq 'Low' -and $lowPack.declared -eq $true) 'lock records the declared Low level as the one actually used'
	Write-Output 'PASS: a per-mount DetailLevels declaration decides the search path instead of EditDetailLevelPreference'

	# A declared level that the installed engine does not have must fall back explicitly: the pack is found
	# at another level, the run continues, and both the warning and the lock say the level was not declared.
	$fallbackTemplate = 'TP_PerMountFallback'
	$fallbackName = "Fall_$testId"
	Write-FixtureJson (Join-Path $rulesEngine 'Templates\TemplateResources\High\Input\Content\Input_Action.uasset') 'input pack'
	$fallbackCase = Invoke-RulesCase -TemplateName $fallbackTemplate -ProjectName $fallbackName -RunId 'perfall' -DefsLines @(
		'[/Script/GameProjectGeneration.TemplateProjectDefs]',
		'FilesToIgnore="Config/TemplateDefs.ini"',
		'FolderRenames=(From="Source/%TEMPLATENAME%",To="Source/%PROJECTNAME%")',
		'FilenameReplacements=(Extensions=("cpp","cs"),From="%TEMPLATENAME%",To="%PROJECTNAME%",bCaseSensitive=false)',
		'ReplacementsInFiles=(Extensions=("cpp","cs","ini"),From="%TEMPLATENAME%",To="%PROJECTNAME%",bCaseSensitive=false)',
		'SharedContentPacks=(MountName="Input",DetailLevels=("Low"))',
		'EditDetailLevelPreference="High"'
	)
	Assert-True ($fallbackCase.Report.Failure -eq '') ('a declared level that is absent falls back instead of failing: ' + $fallbackCase.Report.Failure)
	Assert-True (@($fallbackCase.Report.Warnings | Where-Object { $_ -like '*was declared for detail level*Low*' }).Count -gt 0) 'the fall back from the declared detail level is reported'
	$fallbackLock = [System.IO.File]::ReadAllText((Join-Path $fallbackCase.Output 'template-lock.json')) | ConvertFrom-Json
	$fallbackPack = @($fallbackLock.template_defs.shared_content_packs | Where-Object { $_.mount -eq 'Input' })[0]
	Assert-True ($fallbackPack.detail_level -eq 'High' -and $fallbackPack.declared -eq $false) 'lock records the fall back level and that it was not the declared one'
	Write-Output 'PASS: a declared detail level that the engine lacks is replaced by an explicit, recorded fall back'

	Assert-GeneratorFails { Invoke-Generator 'spectator-explore' "..\escape_$testId" 'path-test' @() } 'path traversal project name is rejected'
	Assert-GeneratorFails { Invoke-Generator 'spectator-explore' "TestExplore_$testId" '..\escape' @() } 'path traversal run ID is rejected'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $productionRoot "escape_$testId"))) 'path traversal did not create an out-of-scope directory'
	Write-Output 'PASS: path traversal rejected before output creation'

	# Recipe layer group (DOT-3118): the selectable recipes are data. The suite proves this by adding
	# and breaking recipe directories in an isolated clone of the committed template, so the checked-in
	# recipes stay untouched and the checkout-unchanged gate keeps its meaning.
	$recipeRepo = New-RecipeFixtureRepository 'RecipeLayer' $templateRevision
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
	Assert-True (@($genreLock.plugins.PSObject.Properties).Count -eq 2 -and $genreLock.plugins.MulticaOnlineStarter.version -eq '1.0.2') 'lock records every declared plugin version'
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
	Assert-True ($null -eq $compatibleOnlyLock.plugins.MovieRenderPipeline.version) 'a plugin that declares no version is recorded as null, not as an empty string'
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
	Assert-True ($changelistOnlyLock.plugins.MovieRenderPipeline.version -eq '1.0') 'a plugin that declares a version records it'
	Write-Output 'PASS: a Build.version with only Changelist still records its build identity'

	# The baseline wrote the same lock for both: Changelist 0 in both installs, CompatibleChangelist
	# never read. The lock has to separate them through the raw fields it now records.
	$installAEngine = Join-Path $fixtureRoot 'InstallAEngineRoot'
	$installBEngine = Join-Path $fixtureRoot 'InstallBEngineRoot'
	New-FixtureEngineRoot $installAEngine '{"MajorVersion":5,"MinorVersion":8,"PatchVersion":4,"Changelist":0,"CompatibleChangelist":58902052}'
	New-FixtureEngineRoot $installBEngine '{"MajorVersion":5,"MinorVersion":8,"PatchVersion":4,"Changelist":0,"CompatibleChangelist":44201111}'
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
        $outputPaths += $caseOutput
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
	$budgetProbeOutput = Invoke-GeneratorCaptured 'spectator-explore' 'PthB_ok1' $testId @() $unboundedPathBudget
	$measuredMatch = [regex]::Match($budgetProbeOutput, 'longest planned path (\d+) characters, (\d+) characters of headroom')
	Assert-True ($measuredMatch.Success) 'the generator reports the longest planned path and its headroom on success'
	$measuredLongest = [int]$measuredMatch.Groups[1].Value
	$measuredHeadroom = [int]$measuredMatch.Groups[2].Value
	Assert-True ($measuredHeadroom -eq ($unboundedPathBudget - $measuredLongest)) 'the reported headroom is the declared budget minus the measured longest path'
	Assert-True (Test-Path -LiteralPath (Join-Path (Join-Path $productionRoot ("PthB_ok1_$testId")) 'template-lock.json')) 'an unbounded budget still generates the project'

	Invoke-Generator 'spectator-explore' 'PthB_eq1' $testId @() $measuredLongest
	$equalBudgetOutput = Join-Path $productionRoot ("PthB_eq1_$testId")
	Assert-True (Test-Path -LiteralPath (Join-Path $equalBudgetOutput 'template-lock.json')) 'a budget exactly equal to the longest planned path still generates the project'
	Assert-True (Test-Path -LiteralPath (Join-Path $equalBudgetOutput 'Plugins\MulticaOnlineStarter\MulticaOnlineStarter.uplugin')) 'the budget check does not drop the online plugin payload'

	$tightBudget = $measuredLongest - 1
	$budgetFailure = ''
	try { Invoke-Generator 'spectator-explore' 'PthB_no1' $testId @() $tightBudget } catch { $budgetFailure = $_.Exception.Message }
	Assert-True ($budgetFailure.Contains([string]$measuredLongest)) 'the budget stop names the measured longest path length'
	Assert-True ($budgetFailure.Contains("{0}-character budget" -f $tightBudget)) 'the budget stop names the budget it compared against'
	Assert-True ($budgetFailure.Contains('over the')) 'the budget stop states how far the tree exceeds the budget'
	Assert-True ($budgetFailure.Contains('shallower directory')) 'the budget stop suggests a concrete way to shorten the path'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $productionRoot ("PthB_no1_$testId")))) 'a budget stop happens before the exclusive mkdir, so no output directory exists'

	# Default budget (no -MaxPathLength), driven by the longest names the generator accepts. This is
	# the case an agent hits by following the documented example with a full GUID run ID. Whether it
	# stops depends on how deep this checkout is, so the expectation is derived from the measured
	# length instead of assuming the developer's path.
	$maxNameProbeRun = ($testId + ('b' * 32))
	$maxNameProbe = (& $generator -Recipe 'spectator-explore' -ProjectName $maxName -RunId $maxNameProbeRun -EngineRoot $fixtureEngine -ProjectDiff @() -AllowDirtyTemplate -SkipTemplatePublishCheck -MaxPathLength $unboundedPathBudget) -join "`n"
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
	$relativeLongest = $measuredLongest - ((Join-Path $productionRoot ("PthB_ok1_$testId")).Length + 1)
	$deepOutputName = 'PthB_dk1_dk'
	$deepRootLengthNeeded = 259 - $relativeLongest - ($deepOutputName.Length + '\Production'.Length) + 1
	$deepRootLengthNeeded = [Math]::Max($deepRootLengthNeeded, $fixtureRoot.Length + 120)
	$deepSegment = 'd' * ($deepRootLengthNeeded - $fixtureRoot.Length - 1)
	$deepParent = Join-Path $fixtureRoot $deepSegment
	[System.IO.Directory]::CreateDirectory($deepParent) | Out-Null
	$deepRepoRoot = Join-Path $deepParent 'repo'
	& git -c core.longpaths=true -C $repoRoot clone --quiet --local --no-hardlinks --no-tags --no-checkout $repoRoot $deepRepoRoot
	if ($LASTEXITCODE -ne 0) { throw 'Could not create the isolated deep-path repository fixture.' }
	& git -C $deepRepoRoot checkout --quiet --detach $templateRevision
	if ($LASTEXITCODE -ne 0) { throw "Could not check out revision $templateRevision in the isolated deep-path repository fixture." }
	[System.IO.Directory]::CreateDirectory((Join-Path $deepRepoRoot 'Production')) | Out-Null
	$deepGenerator = Join-Path $deepRepoRoot 'scripts\New-UETemplateScaffold.ps1'
	Copy-Item -LiteralPath $generator -Destination $deepGenerator -Force
	$deepStopFailure = ''
	try {
		& $deepGenerator -Recipe 'spectator-explore' -ProjectName 'PthB_dk1' -RunId 'dk' -EngineRoot $fixtureEngine -ProjectDiff @() -AllowDirtyTemplate -MaxPathLength 32767 -SkipTemplatePublishCheck | Out-Null
	} catch { $deepStopFailure = $_.Exception.Message }
	Assert-True ($deepStopFailure.Contains('260-character budget')) 'a deeper clone root stops the default-budget run without changing the generated tree'
	Assert-True ($deepStopFailure.Contains($deepRepoRoot)) 'the deep-root stop names the checkout root that made the tree too long'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path (Join-Path $deepRepoRoot 'Production') $deepOutputName))) 'the deep-root stop creates no output directory'
	$deepSuccessOutput = (& $deepGenerator -Recipe 'spectator-explore' -ProjectName 'PthB_dk1' -RunId 'dk' -EngineRoot $fixtureEngine -ProjectDiff @() -AllowDirtyTemplate -SkipTemplatePublishCheck -MaxPathLength $unboundedPathBudget) -join "`n"
	$deepMatch = [regex]::Match($deepSuccessOutput, 'longest planned path (\d+) characters')
	Assert-True ($deepMatch.Success) 'the deep-root run reports its measured longest path when the budget allows it'
	Assert-True ([int]$deepMatch.Groups[1].Value -gt 260) 'the deeper clone root really exceeds 260 characters for the same tree'
	Assert-True (Test-Path -LiteralPath (Join-Path (Join-Path $deepRepoRoot 'Production') ($deepOutputName + '\template-lock.json'))) 'an explicitly raised budget still generates the project at the deeper root'

	# The measured value must equal the tree that actually lands on disk, including the recipe that
	# rewrites paths through TemplateDefs.ini (folder renames change the relative lengths).
	$materializedOutput = (& $generator -Recipe 'third-person-game' -ProjectName $pathBudgetMaterializedName -RunId 'budget' -EngineRoot $fixtureEngine -ProjectDiff @() -AllowDirtyTemplate -SkipTemplatePublishCheck -MaxPathLength $unboundedPathBudget) -join "`n"
	$materializedMatch = [regex]::Match($materializedOutput, 'longest planned path (\d+) characters')
	Assert-True ($materializedMatch.Success) 'the materializing recipe reports its measured longest path too'
	$materializedDir = Join-Path $productionRoot (('{0}_' + $testId) -f $pathBudgetMaterializedName)
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
		& $badVersionGenerator -Recipe 'vertical-loop' -ProjectName $badVersionProjectName -RunId 'badver' -EngineRoot $badVersionEngine -ProjectDiff @() -AllowDirtyTemplate -MaxPathLength 32767 -SkipTemplatePublishCheck | Out-Null
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
		& $driftGenerator -Recipe 'vertical-loop' -ProjectName $driftProjectName -RunId 'drift' -EngineRoot $fixtureEngine -ProjectDiff @() -AllowDirtyTemplate -MaxPathLength 32767 -SkipTemplatePublishCheck | Out-Null
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

	# Format coverage: the installed engine templates write the same FolderRenames tuple two ways —
	# `", To="` (TP_Blank and TP_SIM_Blank, the two spaced templates that actually carry Source/)
	# and `",To="`. A spaced rule used to be dropped without a word: the descriptor was renamed while
	# Source/ kept the template's module directory. One fixture writes both forms, writes the other
	# tuple keys with surrounding spaces, and carries one known-key line this reader cannot interpret.
	$formatTemplateName = 'TP_SpacedRenames'
	$formatTemplateRoot = Join-Path $fixtureEngine ('Templates\' + $formatTemplateName)
	Write-FixtureTemplate $formatTemplateRoot $formatTemplateName $formatTemplateName
	Write-FixtureJson (Join-Path $formatTemplateRoot 'Config\TemplateDefs.ini') (@(
		'[/Script/GameProjectGeneration.TemplateProjectDefs]',
		'FoldersToIgnore=Media',
		'FilesToIgnore="Config/TemplateDefs.ini"',
		'FolderRenames=(From="Source/%TEMPLATENAME%", To="Source/%PROJECTNAME%")',
		'FolderRenames=(From="Content/Template",To="Content/Project")',
		'FolderRenames=(From="Content/Template2",To="Content/Project2") ; trailing text the previous reader accepted',
		'ReplacementsInFiles=(Extensions=("cpp","h","ini","cs"), From="%TEMPLATENAME%", To="%PROJECTNAME%", bCaseSensitive=false)',
		'SharedContentPacks=( MountName = "SpacedPack" , DetailLevels=("Standard") )',
		'SharedContentPacks=(MountName=Variant_Shooter, DetailLevels=("Standard"))',
		'EditDetailLevelPreference = "Standard"'
	) -join "`r`n")
	Write-FixtureJson (Join-Path $formatTemplateRoot 'Content\Template\Lvl_Loose.umap') 'binary Content/Template'
	Write-FixtureJson (Join-Path $formatTemplateRoot 'Content\Template2\Lvl_Trailing.umap') 'binary Content/Template2'
	Write-FixtureJson (Join-Path $formatTemplateRoot 'Media\Ignored.png') 'ignored'
	Write-FixtureJson (Join-Path $fixtureEngine 'Templates\TemplateResources\Standard\SpacedPack\Content\Packed\P.uasset') 'spaced pack'

	$formatRepoRoot = Join-Path $fixtureRoot 'Fmt'
	& git -C $repoRoot clone --quiet --local --no-hardlinks --no-tags --no-checkout $repoRoot $formatRepoRoot
	if ($LASTEXITCODE -ne 0) { throw 'Could not create the isolated TemplateDefs format repository fixture.' }
	& git -C $formatRepoRoot checkout --quiet --detach $templateRevision
	if ($LASTEXITCODE -ne 0) { throw "Could not check out revision $templateRevision in the isolated TemplateDefs format repository fixture." }
	[System.IO.Directory]::CreateDirectory((Join-Path $formatRepoRoot 'Production')) | Out-Null
	$formatGenerator = Join-Path $formatRepoRoot 'scripts\New-UETemplateScaffold.ps1'
	Copy-Item -LiteralPath $generator -Destination $formatGenerator -Force
	Set-FixtureRecipeTemplate $formatRepoRoot 'third-person-game' $formatTemplateName

	$formatProjectName = 'Fmt' + $testId.Substring(0, 12)
	$formatOutput = Join-Path (Join-Path $formatRepoRoot 'Production') "${formatProjectName}_a"
	$formatWarnings = @()
	& $formatGenerator -Recipe 'third-person-game' -ProjectName $formatProjectName -RunId 'a' -EngineRoot $fixtureEngine -ProjectDiff @() -AllowDirtyTemplate -MaxPathLength 32767 -SkipTemplatePublishCheck -WarningVariable +formatWarnings -WarningAction Continue | Out-Null
	Assert-True (Test-Path -LiteralPath (Join-Path $formatOutput "Source\$formatProjectName\$formatProjectName.Build.cs")) 'a spaced FolderRenames tuple renames the module directory too'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $formatOutput "Source\$formatTemplateName"))) 'a spaced FolderRenames tuple leaves no template module directory behind'
	Assert-True (Test-Path -LiteralPath (Join-Path $formatOutput 'Content\Project\Lvl_Loose.umap')) 'an unspaced FolderRenames tuple outside Source is also applied'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $formatOutput 'Content\Template'))) 'the unspaced FolderRenames source folder is gone'
	# Parity guard: the previous reader accepted a rule followed by trailing text because its pattern
	# was unanchored. Widening must not narrow, so that line still applies and is still not reported.
	Assert-True (Test-Path -LiteralPath (Join-Path $formatOutput 'Content\Project2\Lvl_Trailing.umap')) 'a FolderRenames rule followed by trailing text is still applied'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $formatOutput 'Content\Template2'))) 'the trailing-text FolderRenames source folder is gone'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $formatOutput 'Media'))) 'spaced FoldersToIgnore is applied'
	Assert-True (Test-Path -LiteralPath (Join-Path $formatOutput 'Content\SpacedPack\Packed\P.uasset')) 'spaced SharedContentPacks and spaced EditDetailLevelPreference are applied'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $formatOutput 'Content\Variant_Shooter'))) 'an uninterpretable SharedContentPacks line applies nothing'
	$formatWarningText = @($formatWarnings) -join "`n"
	Assert-True ($formatWarningText.Contains('not understood')) 'an uninterpretable known-key line is reported as a warning instead of being skipped silently'
	Assert-True ($formatWarningText.Contains('MountName=Variant_Shooter')) 'the warning names the line that was dropped'
	Assert-True (-not $formatWarningText.Contains('trailing text')) 'a rule the previous reader accepted is not reported as uninterpretable'
	$formatDescriptor = [System.IO.File]::ReadAllText((Join-Path $formatOutput "$formatProjectName.uproject")) | ConvertFrom-Json
	Assert-True ($formatDescriptor.Modules[0].Name -ceq $formatProjectName) 'a spaced FolderRenames tuple keeps descriptor and Source/ in agreement'
	$formatLock = [System.IO.File]::ReadAllText((Join-Path $formatOutput 'template-lock.json')) | ConvertFrom-Json
	Assert-True (@($formatLock.identity.project_modules) -join ',' -ceq $formatProjectName) 'the lock records the module name the spaced rule produced'
	Write-Output 'PASS: TemplateDefs.ini accepts spaced and unspaced separators and reports uninterpretable known-key lines'

	# The warning must not become the whole contract: a FolderRenames line the reader cannot parse
	# leaves the template's own module directory in place, so the run has to stop on the identity
	# check instead of printing a success message for a project that cannot find its module.
	$silentTemplateName = 'TP_SilentRenames'
	$silentTemplateRoot = Join-Path $fixtureEngine ('Templates\' + $silentTemplateName)
	Write-FixtureTemplate $silentTemplateRoot $silentTemplateName $silentTemplateName
	Write-FixtureJson (Join-Path $silentTemplateRoot 'Config\TemplateDefs.ini') (@(
		'[/Script/GameProjectGeneration.TemplateProjectDefs]',
		'FilesToIgnore="Config/TemplateDefs.ini"',
		'FolderRenames=(From="Source/%TEMPLATENAME%" To="Source/%PROJECTNAME%")'
	) -join "`r`n")
	Set-FixtureRecipeTemplate $formatRepoRoot 'third-person-game' $silentTemplateName
	$silentProjectName = 'Drp' + $testId.Substring(0, 12)
	$silentOutput = Join-Path (Join-Path $formatRepoRoot 'Production') "${silentProjectName}_b"
	$silentWarnings = @()
	$silentFailure = ''
	try {
		& $formatGenerator -Recipe 'third-person-game' -ProjectName $silentProjectName -RunId 'b' -EngineRoot $fixtureEngine -ProjectDiff @() -AllowDirtyTemplate -MaxPathLength 32767 -SkipTemplatePublishCheck -WarningVariable +silentWarnings -WarningAction Continue | Out-Null
	} catch {
		$silentFailure = $_.Exception.Message
	}
	$silentWarningText = @($silentWarnings) -join "`n"
	Assert-True (-not $silentWarningText.Contains('FilesToIgnore')) 'a line that parses produces no warning'
	Assert-True ($silentWarningText.Contains('FolderRenames=(From="Source/%TEMPLATENAME%" To=')) 'a FolderRenames line the reader cannot parse is reported'
	Assert-True ($silentFailure.Contains('Project identity check stopped')) 'an unparsed module rename stops the run instead of reporting success'
	Assert-True ($silentFailure.Contains('Source/TP_SilentRenames')) 'the stop names the source path that kept the template module name'
	Write-Output 'PASS: a FolderRenames line the reader drops stops the run through the identity check'


	# Negative case: the template declares ProjectID / ProjectName twice, under two different section
	# headers. Folding that into one canonical block has no deterministic answer, so the generator must
	# stop and name the file, sections and keys instead of silently keeping one of them.
	$ambiguousTemplateName = 'TP_IdentityAmbiguous'
	$ambiguousTemplateRoot = Join-Path $fixtureEngine ('Templates\' + $ambiguousTemplateName)
	Write-FixtureTemplate $ambiguousTemplateRoot $ambiguousTemplateName $ambiguousTemplateName
	Write-FixtureTemplateDefs $ambiguousTemplateRoot @(
		'[/Script/GameProjectGeneration.TemplateProjectDefs]',
		'FoldersToIgnore=Media',
		'FilesToIgnore="%TEMPLATENAME%.uproject"',
		'FilesToIgnore="Config/TemplateDefs.ini"'
	)
	Write-FixtureJson (Join-Path $ambiguousTemplateRoot 'Config\DefaultGame.ini') ("[/Script/EngineSettings.GeneralProjectSettings]`r`nProjectID=(A=1,B=2,C=3,D=4)`r`nProjectName=Ambiguous Template`r`n`r`n[ProjectSettings]`r`nProjectID=(A=5,B=6,C=7,D=8)`r`nProjectName=Ambiguous Legacy`r`n")
	$ambiguousRepoRoot = Join-Path $fixtureRoot 'AmbigIdentityTmpl'
	& git -C $repoRoot clone --quiet --local --no-hardlinks --no-tags --no-checkout $repoRoot $ambiguousRepoRoot
	if ($LASTEXITCODE -ne 0) { throw 'Could not create the isolated ambiguous-identity repository fixture.' }
	& git -C $ambiguousRepoRoot checkout --quiet --detach $templateRevision
	if ($LASTEXITCODE -ne 0) { throw "Could not check out revision $templateRevision in the isolated ambiguous-identity repository fixture." }
	[System.IO.Directory]::CreateDirectory((Join-Path $ambiguousRepoRoot 'Production')) | Out-Null
	$ambiguousGenerator = Join-Path $ambiguousRepoRoot 'scripts\New-UETemplateScaffold.ps1'
	Copy-Item -LiteralPath $generator -Destination $ambiguousGenerator -Force
	Set-FixtureRecipeTemplate $ambiguousRepoRoot 'vertical-loop' $ambiguousTemplateName
	$ambiguousProjectName = "Ambig_$testId"
	$ambiguousOutput = Join-Path (Join-Path $ambiguousRepoRoot 'Production') "${ambiguousProjectName}_amb"
	$ambiguousFailure = ''
	try {
		& $ambiguousGenerator -Recipe 'vertical-loop' -ProjectName $ambiguousProjectName -RunId 'amb' -EngineRoot $fixtureEngine -ProjectDiff @() -AllowDirtyTemplate -MaxPathLength 32767 -SkipTemplatePublishCheck | Out-Null
	} catch {
		$ambiguousFailure = $_.Exception.Message
	}
	Assert-True ($ambiguousFailure.Contains('Project identity check stopped')) 'an identity declared in two sections stops the generator'
	Assert-True ($ambiguousFailure.Contains('ProjectID in [/Script/EngineSettings.GeneralProjectSettings] and [ProjectSettings]')) 'the stop names the sections that both declare ProjectID'
	Assert-True ($ambiguousFailure.Contains('ProjectName in [/Script/EngineSettings.GeneralProjectSettings] and [ProjectSettings]')) 'the stop names the sections that both declare ProjectName'
	# The generator keeps the exclusive output directory when it stops (it does not delete work), so the
	# assertion is that the ambiguous template file was copied verbatim and no identity was written into it:
	# a half-normalized file with a fresh ProjectID would be worse than an untouched copy.
	$ambiguousGameIni = Join-Path $ambiguousOutput 'Config\DefaultGame.ini'
	if (Test-Path -LiteralPath $ambiguousGameIni -PathType Leaf) {
		Assert-True (@(Get-DefaultGameSectionEntries $ambiguousOutput).Count -eq 4) 'the stopped run left the template identity untouched instead of writing a fresh one'
	}
	Write-Output 'PASS: an identity declared under two section headers stops generation and names the sections'

	# The generated project's own Config declares the map it opens. If that map is only available

	# Negative case: the generated project's own Config declares the map it opens. If that map is only available
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
	& $packMapGenerator -Recipe 'vertical-loop' -ProjectName $packMapProjectName -RunId 'ok' -EngineRoot $fixtureEngine -ProjectDiff @() -AllowDirtyTemplate -MaxPathLength 32767 -SkipTemplatePublishCheck | Out-Null
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
		& $packMapGenerator -Recipe 'vertical-loop' -ProjectName $missingMapProjectName -RunId 'missing-map' -EngineRoot $fixtureEngine -ProjectDiff @() -AllowDirtyTemplate -MaxPathLength 32767 -SkipTemplatePublishCheck | Out-Null
	} catch {
		$missingMapFailure = $_.Exception.Message
	}
	$missingMapOutput = Join-Path (Join-Path $packMapRepoRoot 'Production') "${missingMapProjectName}_missing-map"
	Assert-True ($missingMapFailure.Contains('Default map check stopped')) 'a declared default map missing from the output stops the generator'
	Assert-True ($missingMapFailure.Contains('/Game/LevelPrototyping/Lvl_Prototype')) 'the stop names the declared map package path'
	Assert-True ($missingMapFailure.Contains('Content/LevelPrototyping/Lvl_Prototype.umap')) 'the stop names the missing asset path instead of guessing'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $missingMapOutput 'template-lock.json'))) 'the default map stop happens before the lock is written, so success is never recorded'
	Write-Output 'PASS: a missing default map stops generation instead of reporting success'
	# Negative case: the commit `a9e31bc` shape - a .uplugin that declares a module while no .cpp in
	# Source/ holds its IMPLEMENT_MODULE entry point. The detector must name the declared module, so
	# the previous "the descriptor and the folder exist, therefore the module loads" reading cannot
	# pass. The fixture is built from the repository plugin and every IMPLEMENT_MODULE holder is
	# removed, because file names do not define the contract.
	$baselinePluginRoot = Join-Path $fixtureRoot 'BaselinePlugin\MulticaOnlineStarter'
	[System.IO.Directory]::CreateDirectory($baselinePluginRoot) | Out-Null
	Get-ChildItem -LiteralPath (Join-Path $repoRoot 'templates\online\MulticaOnlineStarter') -Force | ForEach-Object {
		Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $baselinePluginRoot $_.Name) -Recurse
	}
	$entryPointCppFiles = @(Get-ChildItem -LiteralPath (Join-Path $baselinePluginRoot 'Source') -Filter '*.cpp' -File -Recurse | Where-Object { (Get-CppCodeOnly ([System.IO.File]::ReadAllText($_.FullName))) -match 'IMPLEMENT_MODULE' })
	Assert-True ($entryPointCppFiles.Count -ge 1) 'the repository plugin ships an IMPLEMENT_MODULE holder the baseline fixture can strip'
	foreach ($entryPointFile in $entryPointCppFiles) { Remove-Item -LiteralPath $entryPointFile.FullName -Force }
	$baselineViolations = @(Get-PluginModuleEntryPointViolations $baselinePluginRoot)
	Assert-True ($baselineViolations.Count -eq 1) ('the entry-point-less plugin is reported exactly once: ' + ($baselineViolations -join '; '))
	Assert-True ($baselineViolations[0].Contains("declares module 'MulticaOnlineStarter'")) 'the entry-point-less plugin is reported by its declared module name, matching the a9e31bc baseline'
	$declaredModuleOnly = [System.IO.File]::ReadAllText((Join-Path $baselinePluginRoot 'MulticaOnlineStarter.uplugin')) | ConvertFrom-Json
	Assert-True (@($declaredModuleOnly.Modules).Count -eq 1 -and $declaredModuleOnly.Modules[0].Name -eq 'MulticaOnlineStarter') 'the negative fixture keeps the declaration that the detector must contradict'
	Write-Output 'PASS: a plugin that declares a module without IMPLEMENT_MODULE fails the module entry-point check'

	# Negative case: the entry point is still in the file but commented out. A bare regex over the
	# file text accepts it while UBT sees no IMPLEMENT_MODULE_<Name> symbol at all, so the commented
	# shape must be treated as missing and reported by the declared module name.
	$commentedPluginRoot = Join-Path $fixtureRoot 'CommentedPlugin\MulticaOnlineStarter'
	[System.IO.Directory]::CreateDirectory($commentedPluginRoot) | Out-Null
	Get-ChildItem -LiteralPath (Join-Path $repoRoot 'templates\online\MulticaOnlineStarter') -Force | ForEach-Object {
		Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $commentedPluginRoot $_.Name) -Recurse
	}
	$commentedEntryPointFiles = @(Get-ChildItem -LiteralPath (Join-Path $commentedPluginRoot 'Source') -Filter '*.cpp' -File -Recurse | Where-Object { (Get-CppCodeOnly ([System.IO.File]::ReadAllText($_.FullName))) -match 'IMPLEMENT_MODULE' })
	Assert-True ($commentedEntryPointFiles.Count -ge 1) 'the repository plugin ships an IMPLEMENT_MODULE holder the commented fixture can disable'
	foreach ($commentedFile in $commentedEntryPointFiles) {
		$holderText = [System.IO.File]::ReadAllText($commentedFile.FullName)
		$commentedText = [regex]::Replace($holderText, 'IMPLEMENT_MODULE\s*\(\s*[A-Za-z_][A-Za-z0-9_:]*\s*,\s*MulticaOnlineStarter\s*\)', '/* IMPLEMENT_MODULE(FDefaultGameModuleImpl, MulticaOnlineStarter) */')
		Assert-True ($commentedText -cne $holderText) "the commented fixture comments out the entry point in $($commentedFile.Name)"
		[System.IO.File]::WriteAllText($commentedFile.FullName, $commentedText, [System.Text.UTF8Encoding]::new($false))
	}
	$commentedViolations = @(Get-PluginModuleEntryPointViolations $commentedPluginRoot)
	Assert-True ($commentedViolations.Count -eq 1) ('the commented-out entry point is reported exactly once: ' + ($commentedViolations -join '; '))
	Assert-True ($commentedViolations[0].Contains("no .cpp under") -and $commentedViolations[0].Contains("'MulticaOnlineStarter'")) 'the commented-out entry point is reported as a missing entry point for the declared module'
	Write-Output 'PASS: a commented-out IMPLEMENT_MODULE does not count as a module entry point'

	# Negative case: the entry point names a different module than the descriptor declares. UBT
	# forces a reference to `IMPLEMENT_MODULE_<declared name>`, so a mismatched argument links
	# nothing; the check must report the mismatch instead of accepting "an IMPLEMENT_MODULE exists".
	$mismatchPluginRoot = Join-Path $fixtureRoot 'MismatchPlugin\MulticaOnlineStarter'
	[System.IO.Directory]::CreateDirectory($mismatchPluginRoot) | Out-Null
	Get-ChildItem -LiteralPath (Join-Path $repoRoot 'templates\online\MulticaOnlineStarter') -Force | ForEach-Object {
		Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $mismatchPluginRoot $_.Name) -Recurse
	}
	$mismatchedName = 'MulticaOnlineStarterRenamed'
	foreach ($sourceFile in @(Get-ChildItem -LiteralPath (Join-Path $mismatchPluginRoot 'Source') -Filter '*.cpp' -File -Recurse)) {
		$sourceText = [System.IO.File]::ReadAllText($sourceFile.FullName)
		if ((Get-CppCodeOnly $sourceText) -notmatch 'IMPLEMENT_MODULE') { continue }
		$rewritten = [regex]::Replace($sourceText, 'IMPLEMENT_MODULE\s*\(\s*([A-Za-z_][A-Za-z0-9_:]*)\s*,\s*MulticaOnlineStarter\s*\)', ('IMPLEMENT_MODULE($1, ' + $mismatchedName + ')'))
		Assert-True ($rewritten -cne $sourceText) "the mismatch fixture rewrites the entry point in $($sourceFile.Name)"
		[System.IO.File]::WriteAllText($sourceFile.FullName, $rewritten, [System.Text.UTF8Encoding]::new($false))
	}
	$mismatchViolations = @(Get-PluginModuleEntryPointViolations $mismatchPluginRoot)
	Assert-True ($mismatchViolations.Count -eq 2) ('a renamed entry point is reported for both the unbacked declaration and the stray entry point: ' + ($mismatchViolations -join '; '))
	Assert-True (($mismatchViolations -join ' ').Contains("no .cpp under") -and ($mismatchViolations -join ' ').Contains($mismatchedName)) 'the mismatch report names both the declared module and the entry point that does not match it'
	Write-Output 'PASS: an IMPLEMENT_MODULE whose module argument differs from the declared module fails the check'

	$playerCountGate = Join-Path $PSScriptRoot 'Test-MulticaOnlinePlayerCountContract.ps1'
	$playerCountFindings = @(& $playerCountGate -RepositoryRoot $repoRoot)
	Assert-True ($LASTEXITCODE -eq 0) ('the online player-count contract gate passes (the Logout path excludes the leaving controller and keeps the engine predicate): ' + ($playerCountFindings -join '; '))
	Write-Output 'PASS: online player count excludes the leaving controller and keeps the engine player predicate'

	# Delivery contract: docs/06-delivery.md defines the delivery set, AGENTS.md must enumerate the same
	# files, and every template the set points at must exist. Without this gate an agent can finish a
	# delivery that its own documentation forbids, or silently drop the README operation sheet.
	$deliveryProblems = @(Get-DeliveryContractProblems -RepositoryRoot $repoRoot)
	Assert-True ($deliveryProblems.Count -eq 0) ('the delivery set, the AGENTS.md folder contract and templates/ agree: ' + ($deliveryProblems -join '; '))
	$contractRepoRoot = Join-Path $fixtureRoot 'DeliveryContractTemplate'
	& git -C $repoRoot clone --quiet --local --no-hardlinks --no-tags --no-checkout $repoRoot $contractRepoRoot
	if ($LASTEXITCODE -ne 0) { throw 'Could not create the isolated delivery-contract repository fixture.' }
	& git -C $contractRepoRoot checkout --quiet --detach $templateRevision
	if ($LASTEXITCODE -ne 0) { throw "Could not check out revision $templateRevision in the isolated delivery-contract repository fixture." }
	# The gate is added in this change, so the revision under test can predate templates/README.md.
	# Copy the changed files into the fixture so each mutation below is the only difference.
	foreach ($relative in @('templates\README.md', 'templates\DELIVERY.json', 'templates\QA.md', 'docs\06-delivery.md', 'AGENTS.md')) {
		Copy-Item -LiteralPath (Join-Path $repoRoot $relative) -Destination (Join-Path $contractRepoRoot $relative) -Force
	}
	$fixtureUtf8 = [System.Text.UTF8Encoding]::new($false)
	Assert-True (@(Get-DeliveryContractProblems -RepositoryRoot $contractRepoRoot).Count -eq 0) 'the isolated delivery-contract fixture is quiet before mutation'
	$fixtureReadme = Join-Path $contractRepoRoot 'templates\README.md'
	$fixtureReadmeBody = [System.IO.File]::ReadAllText($fixtureReadme)
	Remove-Item -LiteralPath $fixtureReadme -Force
	$missingReadmeProblems = @(Get-DeliveryContractProblems -RepositoryRoot $contractRepoRoot)
	Assert-True ((($missingReadmeProblems -join '; ').Contains('templates/README.md: the delivery set names it but the file is missing'))) 'deleting templates/README.md fails the gate and names the path'
	[System.IO.File]::WriteAllText($fixtureReadme, $fixtureReadmeBody, $fixtureUtf8)
	Assert-True (@(Get-DeliveryContractProblems -RepositoryRoot $contractRepoRoot).Count -eq 0) 'restoring templates/README.md returns the gate to silence'
	$fixtureAgents = Join-Path $contractRepoRoot 'AGENTS.md'
	$fixtureAgentsBody = [System.IO.File]::ReadAllText($fixtureAgents)
	[System.IO.File]::WriteAllText($fixtureAgents, ($fixtureAgentsBody -creplace '(?m)^    README\.md QA\.md CREDITS\.md', '    QA.md CREDITS.md'), $fixtureUtf8)
	Assert-True ((@(Get-DeliveryContractProblems -RepositoryRoot $contractRepoRoot) -join '; ').Contains('AGENTS.md: the Out/run_<runid>/ listing does not include README.md')) 'dropping README.md from the AGENTS.md folder contract fails the gate'
	[System.IO.File]::WriteAllText($fixtureAgents, $fixtureAgentsBody, $fixtureUtf8)
	$fixtureQa = Join-Path $contractRepoRoot 'templates\QA.md'
	$fixtureQaBody = [System.IO.File]::ReadAllText($fixtureQa)
	$fixtureQaRows = @([System.IO.File]::ReadAllLines($fixtureQa) | Where-Object { -not ($_.StartsWith('|') -and $_.Contains('README')) })
	[System.IO.File]::WriteAllText($fixtureQa, ($fixtureQaRows -join "`r`n"), $fixtureUtf8)
	Assert-True ((@(Get-DeliveryContractProblems -RepositoryRoot $contractRepoRoot) -join '; ').Contains('templates/QA.md: no row checks that the delivered README points at the same build')) 'dropping the README row from the QA template fails the gate'
	[System.IO.File]::WriteAllText($fixtureQa, $fixtureQaBody, $fixtureUtf8)
	$fixtureDelivery = Join-Path $contractRepoRoot 'templates\DELIVERY.json'
	$fixtureDeliveryBody = [System.IO.File]::ReadAllText($fixtureDelivery)
	$fixtureDeliveryData = $fixtureDeliveryBody | ConvertFrom-Json
	$fixtureDeliveryData.PSObject.Properties.Remove('readme_receipt')
	Write-FixtureJson $fixtureDelivery (ConvertTo-Json -InputObject $fixtureDeliveryData -Depth 10)
	Assert-True ((@(Get-DeliveryContractProblems -RepositoryRoot $contractRepoRoot) -join '; ').Contains('templates/DELIVERY.json: readme_receipt is missing')) 'dropping readme_receipt from the delivery manifest fails the gate'
	[System.IO.File]::WriteAllText($fixtureDelivery, $fixtureDeliveryBody, $fixtureUtf8)
	Assert-True (@(Get-DeliveryContractProblems -RepositoryRoot $contractRepoRoot).Count -eq 0) 'every mutation restored leaves the delivery-contract gate silent'
	Write-Output 'PASS: delivery set, AGENTS.md folder contract and templates agree, and each removal fails the gate'

	# Negative case: the template enables a plugin that this engine install does not ship. The
	# generator must stop before creating the output directory instead of writing a lock (and a
	# project) that opens on one install and not on another.
	$pluginGapEngine = Join-Path $fixtureRoot 'PluginGapEngineRoot'
	Write-FixtureJson (Join-Path $pluginGapEngine 'Engine\Build\Build.version') '{"MajorVersion":5,"MinorVersion":8,"PatchVersion":4,"Changelist":58902052}'
	Write-FixtureJson (Join-Path $pluginGapEngine 'Engine\Plugins\MovieScene\MovieRenderPipeline\MovieRenderPipeline.uplugin') '{"FileVersion":3,"Version":1,"VersionName":"1.0"}'
	$pluginGapTemplate = Join-Path $pluginGapEngine 'Templates\TP_BlankBP'
	Write-FixtureTemplate $pluginGapTemplate 'TP_BlankBP' 'TP_BlankBP'
	Write-FixtureJson (Join-Path $pluginGapTemplate 'TP_BlankBP.uproject') '{"FileVersion":3,"EngineAssociation":"","Modules":[{"Name":"TP_BlankBP","Type":"Runtime"}],"Plugins":[{"Name":"PhantomPlugin","Enabled":true}]}'
	$pluginGapProjectName = "Phantom_$testId"
	$pluginGapOutput = Join-Path $productionRoot ("{0}_{1}-phantom" -f $pluginGapProjectName, $testId)
	$pluginGapFailure = ''
	try {
		& $generator -Recipe 'vertical-loop' -ProjectName $pluginGapProjectName -RunId "$testId-phantom" -EngineRoot $pluginGapEngine -ProjectDiff @() -AllowDirtyTemplate -MaxPathLength 32767 -SkipTemplatePublishCheck | Out-Null
	} catch {
		$pluginGapFailure = $_.Exception.Message
	}
	Assert-True ($pluginGapFailure.Contains('Plugin identity check stopped')) 'an enabled plugin that this install does not ship stops the generator'
	Assert-True ($pluginGapFailure.Contains('PhantomPlugin')) 'the stop names the unresolvable plugin instead of a generic message'
	Assert-True ($pluginGapFailure.Contains('PhantomPlugin.uplugin')) 'the stop lists the paths that were searched for the plugin'
	Assert-True (-not (Test-Path -LiteralPath $pluginGapOutput)) 'the plugin stop creates no output directory'
	Write-Output 'PASS: an enabled plugin that the installed engine does not ship stops generation before any output'

	# Negative case: the *file* write targets chosen by Config/TemplateDefs.ini. Only the output
	# directory was ever contained; FolderRenames / SharedContentPacks decided the rest, so a value
	# with `..` could write into a sibling directory, outside Production, into another run's
	# working directory, or overwrite a template file with a shared pack. Each case must stop *before*
	# writing, so the escape target and any victim directory stay byte-identical.
	$wsTemplateName = 'TP_WriteScope'
	$wsShort = $testId.Substring(0, 8)
	$wsTemplateRoot = Join-Path $fixtureEngine ('Templates\' + $wsTemplateName)
	Write-FixtureTemplate $wsTemplateRoot $wsTemplateName $wsTemplateName
	Write-FixtureJson (Join-Path $wsTemplateRoot 'Content\WriteScope\Notes.md') 'write-scope template content'
	Write-FixtureJson (Join-Path $wsTemplateRoot 'Config\DefaultGame.ini') "[/Script/EngineSettings.GeneralProjectSettings]`r`nProjectID=(A=1,B=2,C=3,D=4)`r`nProjectName=Write Scope`r`n"
	Write-FixtureJson (Join-Path $wsTemplateRoot 'Content\Characters\SK.uasset') 'TEMPLATE-OWNED-BYTES'
	Write-FixtureJson (Join-Path $fixtureEngine 'Templates\TemplateResources\High\Characters\Content\SK.uasset') 'PACK-ASSET'
	Write-FixtureJson (Join-Path $fixtureEngine ('Esc_' + $wsShort + '\Content\SK.uasset')) 'escaped pack payload'

	$wsRepoRoot = Join-Path $fixtureRoot 'WriteScopeTemplate'
	& git -C $repoRoot clone --quiet --local --no-hardlinks --no-tags --no-checkout $repoRoot $wsRepoRoot
	if ($LASTEXITCODE -ne 0) { throw 'Could not create the isolated write-scope repository fixture.' }
	& git -C $wsRepoRoot checkout --quiet --detach $templateRevision
	if ($LASTEXITCODE -ne 0) { throw "Could not check out revision $templateRevision in the isolated write-scope repository fixture." }
	[System.IO.Directory]::CreateDirectory((Join-Path $wsRepoRoot 'Production')) | Out-Null
	$wsGenerator = Join-Path $wsRepoRoot 'scripts\New-UETemplateScaffold.ps1'
	Copy-Item -LiteralPath $generator -Destination $wsGenerator -Force
	Set-FixtureRecipeTemplate $wsRepoRoot 'third-person-game' $wsTemplateName
	$wsProduction = Join-Path $wsRepoRoot 'Production'
	$wsProjectName = "Ws_$wsShort"
	$wsInvoke = {
		param([string]$RunId)
		& $wsGenerator -Recipe 'third-person-game' -ProjectName $wsProjectName -RunId $RunId -EngineRoot $fixtureEngine -ProjectDiff @() -AllowDirtyTemplate -MaxPathLength 32767 -SkipTemplatePublishCheck | Out-Null
	}
	# Case A (control): the rename stays inside the output directory and still succeeds.
	Write-FixtureJson (Join-Path $wsTemplateRoot 'Config\TemplateDefs.ini') (@(
		'[/Script/GameProjectGeneration.TemplateProjectDefs]',
		'FolderRenames=(From="Source/%TEMPLATENAME%",To="Source/%PROJECTNAME%")',
		'ReplacementsInFiles=(Extensions=("cs"),From="%TEMPLATENAME%",To="%PROJECTNAME%",bCaseSensitive=false)',
		'FolderRenames=(From="Content/WriteScope",To="Content2/%PROJECTNAME%")'
	) -join "`r`n")
	& $wsInvoke 'ws-a'
	$wsControlOutput = Join-Path $wsProduction "${wsProjectName}_ws-a"
	Assert-True (Test-Path -LiteralPath (Join-Path $wsControlOutput "Content2\$wsProjectName\Notes.md")) 'a contained FolderRenames target still materializes normally'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $wsProduction "Sib_$wsShort"))) 'the control run creates no sibling directory'
	Write-Output 'PASS: contained FolderRenames target still materializes the template'

	# Case B: FolderRenames To escapes into a sibling directory under Production.
	Write-FixtureJson (Join-Path $wsTemplateRoot 'Config\TemplateDefs.ini') (@(
		'[/Script/GameProjectGeneration.TemplateProjectDefs]',
		("FolderRenames=(From=`"Content/WriteScope`",To=`"../Sib_{0}`")" -f $wsShort)
	) -join "`r`n")
	$wsSibling = Join-Path $wsProduction "Sib_$wsShort"
	$wsSiblingFailure = Get-GeneratorFailure { & $wsInvoke 'ws-b' }
	Assert-True ($wsSiblingFailure.Contains('Container escape stopped the scaffold')) 'a FolderRenames target escaping the output directory stops the generator'
	Assert-True ($wsSiblingFailure.Contains('FolderRenames')) 'the stop names FolderRenames as the escaping rule'
	Assert-True (-not (Test-Path -LiteralPath $wsSibling)) 'an escaping FolderRenames target writes no sibling directory'
	Write-Output 'PASS: FolderRenames target outside the output directory is rejected before writing'

	# Case C: FolderRenames To escapes Production entirely (repo root).
	Write-FixtureJson (Join-Path $wsTemplateRoot 'Config\TemplateDefs.ini') (@(
		'[/Script/GameProjectGeneration.TemplateProjectDefs]',
		("FolderRenames=(From=`"Content/WriteScope`",To=`"../../InRepo_{0}`")" -f $wsShort)
	) -join "`r`n")
	$wsInRepo = Join-Path $wsRepoRoot "InRepo_$wsShort"
	$wsOutOfProductionFailure = Get-GeneratorFailure { & $wsInvoke 'ws-c' }
	Assert-True ($wsOutOfProductionFailure.Contains('Container escape stopped the scaffold')) 'a FolderRenames target escaping Production stops the generator'
	Assert-True ($wsOutOfProductionFailure.Contains('outside the allowed root')) 'the stop reports the resolved outside path instead of only failing silently'
	Assert-True (-not (Test-Path -LiteralPath $wsInRepo)) 'an escaping FolderRenames target writes nothing outside Production'
	Assert-True (-not (Test-Path -LiteralPath "$wsInRepo\Notes.md")) 'the repo root receives no materialized file from an escaping rename'
	Write-Output 'PASS: FolderRenames target outside Production is rejected and leaves the repo root untouched'

	# Case D: FolderRenames To points into another run's existing working directory.
	$wsVictim = Join-Path $wsProduction "Other_${wsShort}_run"
	[System.IO.Directory]::CreateDirectory((Join-Path $wsVictim 'Content')) | Out-Null
	Write-FixtureJson (Join-Path $wsVictim 'LEASE.json') '{"run":"other-writer","nonce":"abc","phase":"editor-build"}'
	Write-FixtureJson (Join-Path $wsVictim 'Content\Mine.uasset') 'other-writer asset'
	$wsVictimBefore = @(Get-DirectoryFileSet $wsVictim)
	Write-FixtureJson (Join-Path $wsTemplateRoot 'Config\TemplateDefs.ini') (@(
		'[/Script/GameProjectGeneration.TemplateProjectDefs]',
		("FolderRenames=(From=`"Content/WriteScope`",To=`"../Other_{0}_run/Content`")" -f $wsShort)
	) -join "`r`n")
	$wsVictimFailure = Get-GeneratorFailure { & $wsInvoke 'ws-d' }
	Assert-True ($wsVictimFailure.Contains('Container escape stopped the scaffold')) 'a FolderRenames target pointing into another run stops the generator'
	$wsVictimAfter = @(Get-DirectoryFileSet $wsVictim)
	Assert-True (($wsVictimBefore -join "`n") -ceq ($wsVictimAfter -join "`n")) 'another run working directory keeps its exact file set and contents'
	Write-Output 'PASS: FolderRenames target inside another run working directory is rejected and leaves it unchanged'

	# Case E: SharedContentPacks MountName escapes the output directory.
	Write-FixtureJson (Join-Path $wsTemplateRoot 'Config\TemplateDefs.ini') (@(
		'[/Script/GameProjectGeneration.TemplateProjectDefs]',
		("SharedContentPacks=(MountName=`"../../../Esc_{0}`",DetailLevels=(`"High`"))" -f $wsShort)
	) -join "`r`n")
	$wsEscapedPack = Join-Path $wsRepoRoot "Esc_$wsShort"
	$wsPackFailure = Get-GeneratorFailure { & $wsInvoke 'ws-e' }
	Assert-True ($wsPackFailure.Contains('Container escape stopped the scaffold')) 'an escaping SharedContentPacks MountName stops the generator'
	Assert-True ($wsPackFailure.Contains('SharedContentPacks')) 'the stop names SharedContentPacks as the escaping rule'
	Assert-True (-not (Test-Path -LiteralPath $wsEscapedPack)) 'an escaping MountName copies no pack content outside the output directory'
	Write-Output 'PASS: SharedContentPacks MountName outside the output directory is rejected before copying'

	# Case F: a shared pack file collides with a template-owned file and must not overwrite it.
	Write-FixtureJson (Join-Path $wsTemplateRoot 'Config\TemplateDefs.ini') (@(
		'[/Script/GameProjectGeneration.TemplateProjectDefs]',
		'SharedContentPacks=(MountName="Characters",DetailLevels=("High"))'
	) -join "`r`n")
	$wsCollisionFailure = Get-GeneratorFailure { & $wsInvoke 'ws-f' }
	Assert-True ($wsCollisionFailure.Contains('Materialized template paths collide: Content/Characters/SK.uasset')) 'a shared pack file colliding with a template file stops the generator instead of overwriting'
	$wsCollisionOutput = Join-Path $wsProduction "${wsProjectName}_ws-f"
	Assert-True ([System.IO.File]::ReadAllText((Join-Path $wsCollisionOutput 'Content\Characters\SK.uasset')) -ceq 'TEMPLATE-OWNED-BYTES') 'the template-owned file keeps its own bytes after a pack collision'
	Write-Output 'PASS: shared content pack colliding with a template file is rejected instead of overwriting it'

	$existingOutput = $outputPaths[3]
	[System.IO.Directory]::CreateDirectory($existingOutput) | Out-Null
	$sentinel = Join-Path $existingOutput 'KEEP.txt'
	[System.IO.File]::WriteAllText($sentinel, 'untouched', [System.Text.UTF8Encoding]::new($false))
	$existingRun = "$testId-preserved"
	$existingFailure = ''
	try { Invoke-Generator 'spectator-explore' $existingProjectName $existingRun @() } catch { $existingFailure = $_.Exception.Message }
	Assert-True ($existingFailure.Contains('Output already exists; it was not modified')) 'existing output is rejected with the unchanged-output wording'
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
		& $cleanTreeGenerator -MaxPathLength 32767 -Recipe 'vertical-loop' -ProjectName $cleanTreeProjectName -RunId 'qatemplate' -EngineRoot $fixtureEngine -ProjectDiff @() | Out-Null
	} catch {
		$cleanTreeFailure = $_.Exception.Message
	}
	Assert-True ($cleanTreeFailure.Contains('template working tree is dirty')) 'editing templates/QA.md still stops generation through the clean-tree gate'
	Assert-True (-not (Test-Path -LiteralPath $cleanTreeOutput)) 'the clean-tree refusal writes no project'
	Write-Output 'PASS: editing the tracked QA template still stops generation (clean-tree contract preserved)'

	Assert-True (-not (Test-Path -LiteralPath (Join-Path $existingOutput 'template-lock.json'))) 'a rejected run adds no completion marker to the existing output'
	Assert-NoStagingResidue $productionRoot $existingRun
	Write-Output 'PASS: an existing output is rejected before any copy and its content is preserved'

	# A run that stops after it has already copied parts of the template must publish nothing. Before
	# the staging rewrite these three cases each left a partial Production/<Name>_<runid>/ that later
	# blocked the same Name/RunId forever (the repository rule is "stop when the output exists").

	# Case A: a required plugin descriptor is missing, so generation stops after staging the template and before publication.
	$partialEngine = Join-Path $fixtureRoot 'PartialPluginEngineRoot'
	$partialTemplate = Join-Path $partialEngine 'Templates\TP_FirstPerson'
	Write-FixtureTemplate $partialTemplate 'TP_FirstPerson' 'TP_FirstPerson'
	Write-FixtureTemplateDefs $partialTemplate @(
		'[/Script/GameProjectGeneration.TemplateProjectDefs]',
		'FilesToIgnore="%TEMPLATENAME%.uproject"',
		'FilesToIgnore="Config/TemplateDefs.ini"'
	)
	Write-FixtureJson (Join-Path $partialEngine 'Engine\Build\Build.version') '{"MajorVersion":5,"MinorVersion":8,"PatchVersion":4,"Changelist":58902052}'
	foreach ($pluginFixture in @(
		@{ RelativePath = 'Engine\Plugins\Online\OnlineSubsystem\OnlineSubsystem.uplugin' },
		@{ RelativePath = 'Engine\Plugins\Online\OnlineSubsystemUtils\OnlineSubsystemUtils.uplugin' },
		@{ RelativePath = 'Engine\Plugins\MovieScene\MovieRenderPipeline\MovieRenderPipeline.uplugin' }
	)) {
		Write-FixtureJson (Join-Path $partialEngine $pluginFixture.RelativePath) '{"FileVersion":3,"Version":1,"VersionName":"1.0"}'
	}
	$midFailRun = "$testId-retry"
	$midFailOutput = Join-Path $productionRoot "${midFailName}_$testId-retry"
	$midFailFailure = ''
	try { Invoke-GeneratorAt $generator $partialEngine 'spectator-explore' $midFailName $midFailRun @() } catch { $midFailFailure = $_.Exception.Message }
	Assert-True ($midFailFailure.Contains('Required plugin metadata is missing')) 'a missing plugin descriptor stops generation after template staging'
	Assert-True (-not (Test-Path -LiteralPath $midFailOutput)) 'a mid-copy failure publishes no Production/<Name>_<runid> directory'
	Assert-NoStagingResidue $productionRoot $midFailRun
	Write-Output 'PASS: a missing plugin descriptor leaves no published project or staging directory'

	# Case B: the recipe copy stage stops part-way (a recipe file is missing). The clone lives under a
	# short directory name and the run id is short because the staging name adds the run id and a
	# nonce: the fixture already sits inside the developer checkout, and a deep path would stop the run
	# on the Win32 path limit instead of on the missing file.
	$recipeRepoRoot = Join-Path $fixtureRoot 'RF'
	& git -C $repoRoot clone --quiet --local --no-hardlinks --no-tags --no-checkout $repoRoot $recipeRepoRoot
	if ($LASTEXITCODE -ne 0) { throw 'Could not create the isolated recipe-copy repository fixture.' }
	& git -C $recipeRepoRoot checkout --quiet --detach $templateRevision
	if ($LASTEXITCODE -ne 0) { throw "Could not check out revision $templateRevision in the isolated recipe-copy repository fixture." }
	[System.IO.Directory]::CreateDirectory((Join-Path $recipeRepoRoot 'Production')) | Out-Null
	$recipeFailGenerator = Join-Path $recipeRepoRoot 'scripts\New-UETemplateScaffold.ps1'
	Copy-Item -LiteralPath $generator -Destination $recipeFailGenerator -Force
	Remove-Item -LiteralPath (Join-Path $recipeRepoRoot 'templates\recipes\vertical-loop\Capture.md') -Force
	$lateFailRun = 'late'
	$lateFailOutput = Join-Path (Join-Path $recipeRepoRoot 'Production') "${lateFailName}_$lateFailRun"
	$lateFailFailure = ''
	try { Invoke-GeneratorAt $recipeFailGenerator $fixtureEngine 'vertical-loop' $lateFailName $lateFailRun @() } catch { $lateFailFailure = $_.Exception.Message }
	Assert-True ($lateFailFailure.Contains('Capture.md')) 'a missing recipe file stops the run at the recipe copy stage'
	Assert-True (-not (Test-Path -LiteralPath $lateFailOutput)) 'the recipe-copy failure publishes no Production/<Name>_<runid> directory'
	Assert-NoStagingResidue (Join-Path $recipeRepoRoot 'Production') $lateFailRun
	Write-Output 'PASS: a failure at the recipe copy stage leaves no partial output project and no staging directory'

	# Case C: the same Name/RunId succeeds once the engine is sound again, so a stopped run never
	# blocks its own retry.
	Invoke-Generator 'spectator-explore' $midFailName $midFailRun @('Map: /Game/Test/Maps/L_Retry')
	Assert-True (Test-Path -LiteralPath (Join-Path $midFailOutput 'template-lock.json')) 'the same Name/RunId generates successfully after the failure'
	Assert-True (Test-Path -LiteralPath (Join-Path $midFailOutput 'TP_FirstPerson.uproject')) 'the retried run publishes the complete project'
	$retryLock = [System.IO.File]::ReadAllText((Join-Path $midFailOutput 'template-lock.json')) | ConvertFrom-Json
	Assert-True ($retryLock.identity.project_file -eq 'TP_FirstPerson.uproject') 'the retried run records the same project identity as a first run'
	Write-Output 'PASS: a stopped run does not block regeneration of the same Name/RunId'
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
