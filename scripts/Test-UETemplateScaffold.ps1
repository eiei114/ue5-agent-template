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
$outputNames = @(
	"${projectPrefix}_$testId-a",
	"${projectPrefix}_$testId-b",
	"${loopProjectName}_$testId-a",
	"${existingProjectName}_$testId-preserved",
	"Tp_${testId}_$testId-a",
	"${otherProjectName}_$testId-c"
)
$outputPaths = @($outputNames | ForEach-Object { Join-Path $productionRoot $_ })

function Assert-True([bool]$Condition, [string]$Message) {
	if (-not $Condition) { throw "ASSERT FAILED: $Message" }
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
	Write-FixtureJson (Join-Path $fixtureEngine 'Engine\Build\Build.version') '{"MajorVersion":5,"MinorVersion":8,"PatchVersion":4,"Changelist":58902052}'

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
	$pluginConfig = [System.IO.File]::ReadAllText((Join-Path $firstOutput 'Config\DefaultEngine.ini'))
	Assert-True ($pluginConfig.Contains('DefaultPlatformService=Null')) 'generated project config selects the Null provider'
	$expectedSessionIdentifier = "eiei114.ue5-agent-template:$projectName"
	$otherSessionIdentifier = "eiei114.ue5-agent-template:$otherProjectName"
	Assert-True ($pluginConfig.Contains("SessionProjectIdentifier=$expectedSessionIdentifier")) 'generated project config carries the requested stable project key'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $firstOutput 'Plugins\MulticaOnlineStarter\Config\DefaultEngine.ini'))) 'online plugin does not ship a config the engine would ignore for its own section'
	Assert-True ($pluginConfig.Contains('GlobalDefaultGameMode') -eq $true) 'raw copy keeps the template default GameMode line'
	$gameModeLineCount = ([regex]::Matches($pluginConfig, '(?m)^GlobalDefaultGameMode=')).Count
	Assert-True ($gameModeLineCount -eq 1) 'the generator does not add a second template-specific GameMode override'
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
	Assert-True ($firstLock -ceq $secondLock) 'identical dependencies and differences reproduce the same lock record'
	$lockData = $firstLock | ConvertFrom-Json
	Assert-True ($lockData.engine_version -eq '5.8.4') 'lock records the installed engine version'
	Assert-True ($lockData.template_commit -match '^[0-9a-f]{40}$') 'lock records a full template commit SHA'
	Assert-True ($lockData.plugins.MulticaOnlineStarter -eq '1.0.1') 'lock records the project plugin version'
	Assert-True ($lockData.project_differences.Count -eq 2) 'lock records normalized project-specific differences'
	Assert-True ($lockData.schema_version -eq 2) 'lock records the identity-bearing schema version'
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
	Write-FixtureTemplate (Join-Path $badVersionEngine 'Templates\TP_BlankBP') 'TP_BlankBP' 'TP_BlankBP'
	New-Item -ItemType Directory -Force -Path (Join-Path $badVersionEngine 'Engine\Build') | Out-Null
	Write-FixtureJson (Join-Path $badVersionEngine 'Engine\Build\Build.version') '{"MajorVersion":"","MinorVersion":8,"PatchVersion":4,"Changelist":58902052}'
	Write-FixtureJson (Join-Path $badVersionEngine 'Engine\Plugins\MovieScene\MovieRenderPipeline\MovieRenderPipeline.uplugin') '{"FileVersion":3,"Version":1,"VersionName":"1.0"}'
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
