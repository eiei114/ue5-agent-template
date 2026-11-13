[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$productionRoot = Join-Path $repoRoot 'Production'
$generator = Join-Path $PSScriptRoot 'New-UETemplateScaffold.ps1'
$initialCheckoutStatus = @(& git -C $repoRoot status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0) { throw 'Could not record the developer checkout status before testing.' }
$testId = [Guid]::NewGuid().ToString('N')
$fixtureRoot = Join-Path $productionRoot ('.scaffold-test-' + $testId)
$fixtureEngine = Join-Path $fixtureRoot 'EngineRoot'
$projectPrefix = "Ex_$testId"
$loopProjectName = "Lp_$testId"
$existingProjectName = "No_$testId"
$otherProjectName = "Alt_$testId"
$compatibleOnlyProjectName = "Cpo_$testId"
$changelistOnlyProjectName = "Clo_$testId"
$installAProjectName = "Ida_$testId"
$installBProjectName = "Idb_$testId"
$noChangelistProjectName = "Ncl_$testId"
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
)
$outputPaths = @($outputNames | ForEach-Object { Join-Path $productionRoot $_ })

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
	$allowed = @('PLACEHOLDER.md') + @([System.IO.Path]::GetFileName($fixtureRoot)) + @($outputNames)
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
	return $violations.ToArray()
}

function Write-FixtureJson([string]$Path, [string]$Json) {
	$parent = Split-Path -Parent $Path
	[System.IO.Directory]::CreateDirectory($parent) | Out-Null
	[System.IO.File]::WriteAllText($Path, $Json, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-Generator([string]$RecipeName, [string]$Name, [string]$Run, [string[]]$Diff) {
	& $generator -Recipe $RecipeName -ProjectName $Name -RunId $Run -EngineRoot $fixtureEngine -ProjectDiff $Diff -AllowDirtyTemplate | Out-Null
}

function Invoke-EngineGenerator([string]$RecipeName, [string]$Name, [string]$Run, [string[]]$Diff, [string]$EngineRoot) {
	& $generator -Recipe $RecipeName -ProjectName $Name -RunId $Run -EngineRoot $EngineRoot -ProjectDiff $Diff -AllowDirtyTemplate | Out-Null
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

$suiteError = $null
try {
	$initialProductionResidue = @(Get-ProductionResidue)
	Assert-True ($initialProductionResidue.Count -eq 0) ("Production/ holds only the tracked placeholder before testing: " + ($initialProductionResidue -join '; '))

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
		& $dirtyGenerator -Recipe 'spectator-explore' -ProjectName $dirtyProjectName -RunId 'dirty-rejected' -EngineRoot $fixtureEngine -ProjectDiff @() | Out-Null
	} catch {
		$dirtyFailure = $_.Exception.Message
	}
	Assert-True ($dirtyFailure.Contains('template working tree is dirty')) 'dirty template is rejected when AllowDirtyTemplate is omitted'
	Assert-True (-not (Test-Path -LiteralPath $dirtyOutput)) 'dirty-template rejection creates no output project'
	Assert-True ([System.IO.File]::ReadAllText($dirtyMarker) -ceq 'fixture only') 'dirty-template rejection leaves the isolated fixture marker unchanged'
	Write-Output 'PASS: dirty template is rejected using an isolated fixture without touching the developer checkout'

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
	Assert-True ($lockData.template_commit -match '^[0-9a-f]{40}$') 'lock records a full template commit SHA'
	Assert-True ($lockData.plugins.MulticaOnlineStarter -eq '1.0.1') 'lock records the project plugin version'
	Assert-True ($lockData.project_differences.Count -eq 2) 'lock records normalized project-specific differences'
	Assert-True ($lockData.schema_version -eq 3) 'lock records the engine-build-identity schema version'
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
		& $badVersionGenerator -Recipe 'vertical-loop' -ProjectName $badVersionProjectName -RunId 'badver' -EngineRoot $badVersionEngine -ProjectDiff @() -AllowDirtyTemplate | Out-Null
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
		& $driftGenerator -Recipe 'vertical-loop' -ProjectName $driftProjectName -RunId 'drift' -EngineRoot $fixtureEngine -ProjectDiff @() -AllowDirtyTemplate | Out-Null
	} catch {
		$driftFailure = $_.Exception.Message
	}
	Assert-True ($driftFailure.Contains('Project identity check stopped')) 'unresolved project identity stops the generator'
	Assert-True ($driftFailure.Contains('Source/TP_IdentityDrift/TP_IdentityDrift.Build.cs')) 'the stop names the unmatched source path instead of guessing'
	Assert-True (-not (Test-Path -LiteralPath $driftOutput)) 'identity stop writes no raw-copied project'
	Write-Output 'PASS: unresolvable project identity stops generation instead of emitting a raw copy'

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

	$existingOutput = $outputPaths[3]
	[System.IO.Directory]::CreateDirectory($existingOutput) | Out-Null
	$sentinel = Join-Path $existingOutput 'KEEP.txt'
	[System.IO.File]::WriteAllText($sentinel, 'untouched', [System.Text.UTF8Encoding]::new($false))
	Assert-GeneratorFails { Invoke-Generator 'spectator-explore' $existingProjectName "$testId-preserved" @() } 'existing output is rejected'
	Assert-True ([System.IO.File]::ReadAllText($sentinel) -ceq 'untouched') 'existing output content is not overwritten'
	Write-Output 'PASS: exclusive output-directory creation preserves existing content'
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
