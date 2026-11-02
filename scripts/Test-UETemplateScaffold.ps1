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
$outputNames = @(
	"${projectPrefix}_$testId-a",
	"${projectPrefix}_$testId-b",
	"${loopProjectName}_$testId-a",
	"${existingProjectName}_$testId-preserved"
)
$outputPaths = @($outputNames | ForEach-Object { Join-Path $productionRoot $_ })

function Assert-True([bool]$Condition, [string]$Message) {
	if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Write-FixtureJson([string]$Path, [string]$Json) {
	$parent = Split-Path -Parent $Path
	[System.IO.Directory]::CreateDirectory($parent) | Out-Null
	[System.IO.File]::WriteAllText($Path, $Json, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-Generator([string]$RecipeName, [string]$Name, [string]$Run, [string[]]$Diff) {
	& $generator -Recipe $RecipeName -ProjectName $Name -RunId $Run -EngineRoot $fixtureEngine -ProjectDiff $Diff -AllowDirtyTemplate | Out-Null
}

function Assert-GeneratorFails([scriptblock]$Action, [string]$Message) {
	$failed = $false
	try { & $Action } catch { $failed = $true }
	Assert-True $failed $Message
}

try {
	[System.IO.Directory]::CreateDirectory($fixtureEngine) | Out-Null
	Write-FixtureJson (Join-Path $fixtureEngine 'Engine\Build\Build.version') '{"MajorVersion":5,"MinorVersion":8,"PatchVersion":4,"Changelist":58902052}'

	$firstPersonTemplate = Join-Path $fixtureEngine 'Templates\TP_FirstPerson'
	$blankTemplate = Join-Path $fixtureEngine 'Templates\TP_BlankBP'
	Write-FixtureJson (Join-Path $firstPersonTemplate 'TP_FirstPerson.uproject') '{"FileVersion":3,"EngineAssociation":"","Modules":[],"Plugins":[]}'
	Write-FixtureJson (Join-Path $blankTemplate 'TP_BlankBP.uproject') '{"FileVersion":3,"EngineAssociation":"","Modules":[]}'

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
	$firstOutput = $outputPaths[0]
	$secondOutput = $outputPaths[1]
	Assert-True (Test-Path -LiteralPath (Join-Path $firstOutput 'TP_FirstPerson.uproject')) 'game recipe copies the selected engine project template'
	$firstDescriptor = [System.IO.File]::ReadAllText((Join-Path $firstOutput 'TP_FirstPerson.uproject')) | ConvertFrom-Json
	foreach ($pluginName in @('MovieRenderPipeline', 'OnlineSubsystem', 'OnlineSubsystemNull', 'OnlineSubsystemUtils', 'MulticaOnlineStarter')) {
		$pluginEntries = @($firstDescriptor.Plugins | Where-Object { $_.Name -eq $pluginName })
		Assert-True ($pluginEntries.Count -eq 1 -and $pluginEntries[0].Enabled -eq $true) "game recipe enables $pluginName in the project descriptor"
	}
	Assert-True (Test-Path -LiteralPath (Join-Path $firstOutput 'Plugins\MulticaOnlineStarter\MulticaOnlineStarter.uplugin')) 'game recipe includes the Null/LAN plugin'
	$starterDescriptor = [System.IO.File]::ReadAllText((Join-Path $firstOutput 'Plugins\MulticaOnlineStarter\MulticaOnlineStarter.uplugin')) | ConvertFrom-Json
	$nullPluginEntries = @($starterDescriptor.Plugins | Where-Object { $_.Name -eq 'OnlineSubsystemNull' })
	Assert-True ($nullPluginEntries.Count -eq 1 -and $nullPluginEntries[0].Enabled -eq $true) 'online starter plugin enables OnlineSubsystemNull'
	$pluginConfig = [System.IO.File]::ReadAllText((Join-Path $firstOutput 'Plugins\MulticaOnlineStarter\Config\DefaultEngine.ini'))
	Assert-True ($pluginConfig.Contains('DefaultPlatformService=Null')) 'online plugin selects the Null provider'
	Assert-True (-not $pluginConfig.Contains('GlobalDefaultGameMode')) 'online plugin does not override a template-specific GameMode/Pawn'
	Assert-True (Test-Path -LiteralPath (Join-Path $firstOutput 'Recipe\Play.md')) 'game recipe has a play delta'
	Assert-True (Test-Path -LiteralPath (Join-Path $firstOutput 'Recipe\Capture.md')) 'game recipe has a capture delta'
	Assert-True (Test-Path -LiteralPath (Join-Path $firstOutput 'Recipe\SET.md')) 'game recipe has exactly one shared set contract'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $firstOutput 'SyntheticAsset.uasset'))) 'generator does not fabricate Unreal assets'
	$firstLock = [System.IO.File]::ReadAllText((Join-Path $firstOutput 'template-lock.json'))
	$secondLock = [System.IO.File]::ReadAllText((Join-Path $secondOutput 'template-lock.json'))
	Assert-True ($firstLock -ceq $secondLock) 'identical dependencies and differences reproduce the same lock record'
	$lockData = $firstLock | ConvertFrom-Json
	Assert-True ($lockData.engine_version -eq '5.8.4') 'lock records the installed engine version'
	Assert-True ($lockData.template_commit -match '^[0-9a-f]{40}$') 'lock records a full template commit SHA'
	Assert-True ($lockData.plugins.MulticaOnlineStarter -eq '1.0.0') 'lock records the project plugin version'
	Assert-True ($lockData.project_differences.Count -eq 2) 'lock records normalized project-specific differences'
	Write-Output 'PASS: game+capture recipe, official template copy, online plugin, and deterministic lock'

	Invoke-Generator 'vertical-loop' $loopProjectName "$testId-a" @('capture: 1080x1920')
	$loopOutput = $outputPaths[2]
	Assert-True (Test-Path -LiteralPath (Join-Path $loopOutput 'TP_BlankBP.uproject')) 'video-only recipe copies the blank engine template'
	$loopDescriptor = [System.IO.File]::ReadAllText((Join-Path $loopOutput 'TP_BlankBP.uproject')) | ConvertFrom-Json
	$movieRenderPlugins = @($loopDescriptor.Plugins | Where-Object { $_.Name -eq 'MovieRenderPipeline' })
	Assert-True ($movieRenderPlugins.Count -eq 1 -and $movieRenderPlugins[0].Enabled -eq $true) 'video-only recipe enables MovieRenderPipeline in the project descriptor'
	Assert-True (Test-Path -LiteralPath (Join-Path $loopOutput 'Recipe\Capture.md')) 'video-only recipe has capture instructions'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $loopOutput 'Recipe\Play.md'))) 'video-only recipe does not add a play delta'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $loopOutput 'Plugins\MulticaOnlineStarter'))) 'video-only recipe does not add online gameplay code'
	Write-Output 'PASS: capture-only vertical-loop recipe'

	Assert-GeneratorFails { Invoke-Generator 'spectator-explore' "..\escape_$testId" 'path-test' @() } 'path traversal project name is rejected'
	Assert-GeneratorFails { Invoke-Generator 'spectator-explore' "TestExplore_$testId" '..\escape' @() } 'path traversal run ID is rejected'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $productionRoot "escape_$testId"))) 'path traversal did not create an out-of-scope directory'
	Write-Output 'PASS: path traversal rejected before output creation'

	$existingOutput = $outputPaths[3]
	[System.IO.Directory]::CreateDirectory($existingOutput) | Out-Null
	$sentinel = Join-Path $existingOutput 'KEEP.txt'
	[System.IO.File]::WriteAllText($sentinel, 'untouched', [System.Text.UTF8Encoding]::new($false))
	Assert-GeneratorFails { Invoke-Generator 'spectator-explore' $existingProjectName "$testId-preserved" @() } 'existing output is rejected'
	Assert-True ([System.IO.File]::ReadAllText($sentinel) -ceq 'untouched') 'existing output content is not overwritten'
	Write-Output 'PASS: exclusive output-directory creation preserves existing content'
} finally {
	foreach ($path in $outputPaths) {
		if (Test-Path -LiteralPath $path -PathType Container) {
			Remove-Item -LiteralPath $path -Recurse -Force
		}
	}
	if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
		Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
	}
	$finalCheckoutStatus = @(& git -C $repoRoot status --porcelain --untracked-files=all)
	if ($LASTEXITCODE -ne 0) { throw 'Could not verify the developer checkout status after testing.' }
	Assert-True (($finalCheckoutStatus -join "`n") -ceq ($initialCheckoutStatus -join "`n")) 'test suite leaves the developer checkout unchanged'
}
