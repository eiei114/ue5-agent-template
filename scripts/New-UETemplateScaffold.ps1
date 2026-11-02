[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)]
	[ValidateSet('spectator-explore', 'vertical-loop')]
	[string]$Recipe,

	[Parameter(Mandatory = $true)]
	[ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$')]
	[string]$ProjectName,

	[Parameter(Mandatory = $true)]
	[ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,63}$')]
	[string]$RunId,

	[Parameter(Mandatory = $true)]
	[string]$EngineRoot,

	[string[]]$ProjectDiff = @(),

	[switch]$AllowDirtyTemplate
)

$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$productionRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'Production'))
$engineRootFull = [System.IO.Path]::GetFullPath($EngineRoot)
$recipeRoot = Join-Path $repoRoot 'templates\recipes'
$recipeFile = Join-Path (Join-Path $recipeRoot $Recipe) 'recipe.json'
$engineBuildFile = Join-Path $engineRootFull 'Engine\Build\Build.version'
$engineTemplateRoot = Join-Path $engineRootFull 'Templates'

if (-not (Test-Path -LiteralPath $productionRoot -PathType Container)) {
	throw "The repository Production directory is missing: $productionRoot"
}
$productionItem = Get-Item -LiteralPath $productionRoot
if (($productionItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
	throw 'Production must not be a junction or symbolic link.'
}
if (-not (Test-Path -LiteralPath $engineBuildFile -PathType Leaf) -or
	-not (Test-Path -LiteralPath $engineTemplateRoot -PathType Container)) {
	throw 'EngineRoot must be an installed UE directory containing Engine/Build/Build.version and Templates/.'
}
if (-not (Test-Path -LiteralPath $recipeFile -PathType Leaf)) {
	throw "Unknown recipe data file: $recipeFile"
}

$gitCommit = (& git -C $repoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $gitCommit -notmatch '^[0-9a-f]{40}$') {
	throw 'Could not record the template repository commit.'
}
$gitStatus = @(& git -C $repoRoot status --porcelain --untracked-files=normal)
if ($LASTEXITCODE -ne 0) {
	throw 'Could not verify the template working tree.'
}
$templateDirty = $gitStatus.Count -gt 0
if ($templateDirty -and -not $AllowDirtyTemplate) {
	throw 'The template working tree is dirty. Commit the template before generating a reproducible project.'
}

$recipeData = Get-Content -Raw -LiteralPath $recipeFile | ConvertFrom-Json
$buildData = Get-Content -Raw -LiteralPath $engineBuildFile | ConvertFrom-Json
$engineVersion = '{0}.{1}.{2}' -f $buildData.MajorVersion, $buildData.MinorVersion, $buildData.PatchVersion
$templateName = [string]$recipeData.engine_template
$sourceTemplate = Join-Path $engineTemplateRoot $templateName
$templateProjectFile = Join-Path $sourceTemplate ($templateName + '.uproject')
if (-not (Test-Path -LiteralPath $templateProjectFile -PathType Leaf)) {
	throw "The installed engine does not contain the selected official project template: $templateProjectFile"
}

$destinationName = '{0}_{1}' -f $ProjectName, $RunId
$destinationPath = [System.IO.Path]::GetFullPath((Join-Path $productionRoot $destinationName))
$separator = [System.IO.Path]::DirectorySeparatorChar
$productionPrefix = $productionRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + $separator
if (-not $destinationPath.StartsWith($productionPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
	throw 'The computed output directory escapes Production.'
}

if (-not ('MulticaTemplateDirectory' -as [type])) {
	Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class MulticaTemplateDirectory {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CreateDirectory(string path, IntPtr securityAttributes);
}
'@
}
if (-not [MulticaTemplateDirectory]::CreateDirectory($destinationPath, [IntPtr]::Zero)) {
	$win32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
	if ($win32Error -eq 183) {
		throw "Output already exists; it was not modified: $destinationPath"
	}
	throw "Could not exclusively create the output directory (Win32 $win32Error): $destinationPath"
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
try {
	Get-ChildItem -LiteralPath $sourceTemplate -Force | ForEach-Object {
		Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $destinationPath $_.Name) -Recurse
	}

	$projectDescriptor = Get-Content -Raw -LiteralPath (Join-Path $destinationPath ($templateName + '.uproject')) | ConvertFrom-Json
	$projectPlugins = @($projectDescriptor.Plugins | Where-Object { $null -ne $_ })
	foreach ($pluginName in $recipeData.required_plugins) {
		$existing = $projectPlugins | Where-Object { $_.Name -eq $pluginName } | Select-Object -First 1
		if ($null -eq $existing) {
			$projectPlugins += [pscustomobject]@{ Name = [string]$pluginName; Enabled = $true }
		} else {
			$existing.Enabled = $true
		}
	}
	if ($null -eq $projectDescriptor.PSObject.Properties['Plugins']) {
		$projectDescriptor | Add-Member -MemberType NoteProperty -Name Plugins -Value $projectPlugins
	} else {
		$projectDescriptor.Plugins = $projectPlugins
	}
	$projectJson = ConvertTo-Json -InputObject $projectDescriptor -Depth 30
	[System.IO.File]::WriteAllText((Join-Path $destinationPath ($templateName + '.uproject')), $projectJson + [Environment]::NewLine, $utf8NoBom)

	$requiredPlugins = @($recipeData.required_plugins)
	foreach ($pluginName in $requiredPlugins) {
		if ($pluginName -eq 'MulticaOnlineStarter') {
			$pluginDescriptor = Join-Path $repoRoot 'templates\online\MulticaOnlineStarter\MulticaOnlineStarter.uplugin'
		} else {
			switch ($pluginName) {
				'OnlineSubsystem' { $pluginDescriptor = Join-Path $engineRootFull 'Engine\Plugins\Online\OnlineSubsystem\OnlineSubsystem.uplugin' }
				'OnlineSubsystemNull' { $pluginDescriptor = Join-Path $engineRootFull 'Engine\Plugins\Online\OnlineSubsystemNull\OnlineSubsystemNull.uplugin' }
				'OnlineSubsystemUtils' { $pluginDescriptor = Join-Path $engineRootFull 'Engine\Plugins\Online\OnlineSubsystemUtils\OnlineSubsystemUtils.uplugin' }
				'MovieRenderPipeline' { $pluginDescriptor = Join-Path $engineRootFull 'Engine\Plugins\MovieScene\MovieRenderPipeline\MovieRenderPipeline.uplugin' }
				default { throw "No installed plugin path is defined for $pluginName" }
			}
		}
		if (-not (Test-Path -LiteralPath $pluginDescriptor -PathType Leaf)) {
			throw "Required plugin metadata is missing: $pluginDescriptor"
		}
	}

	[string[]]$orderedPluginNames = @($requiredPlugins)
	[Array]::Sort($orderedPluginNames, [System.StringComparer]::Ordinal)
	$pluginVersions = [ordered]@{}
	foreach ($pluginName in $orderedPluginNames) {
		if ($pluginName -eq 'MulticaOnlineStarter') {
			$pluginPath = Join-Path $repoRoot 'templates\online\MulticaOnlineStarter\MulticaOnlineStarter.uplugin'
		} else {
			switch ($pluginName) {
				'OnlineSubsystem' { $pluginPath = Join-Path $engineRootFull 'Engine\Plugins\Online\OnlineSubsystem\OnlineSubsystem.uplugin' }
				'OnlineSubsystemNull' { $pluginPath = Join-Path $engineRootFull 'Engine\Plugins\Online\OnlineSubsystemNull\OnlineSubsystemNull.uplugin' }
				'OnlineSubsystemUtils' { $pluginPath = Join-Path $engineRootFull 'Engine\Plugins\Online\OnlineSubsystemUtils\OnlineSubsystemUtils.uplugin' }
				'MovieRenderPipeline' { $pluginPath = Join-Path $engineRootFull 'Engine\Plugins\MovieScene\MovieRenderPipeline\MovieRenderPipeline.uplugin' }
			}
		}
		$pluginJson = Get-Content -Raw -LiteralPath $pluginPath | ConvertFrom-Json
		$pluginVersion = if (-not [string]::IsNullOrWhiteSpace([string]$pluginJson.VersionName)) {
			[string]$pluginJson.VersionName
		} else {
			[string]$pluginJson.Version
		}
		$pluginVersions[$pluginName] = $pluginVersion
	}

	$differenceSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
	foreach ($difference in $ProjectDiff) {
		$normalizedDifference = $difference.Trim()
		if (-not [string]::IsNullOrWhiteSpace($normalizedDifference)) { $null = $differenceSet.Add($normalizedDifference) }
	}
	[string[]]$projectDifferences = @($differenceSet)
	[Array]::Sort($projectDifferences, [System.StringComparer]::Ordinal)
	$lock = [ordered]@{
		schema_version = 1
		template_repository = 'https://github.com/eiei114/ue5-agent-template'
		template_commit = $gitCommit
		template_worktree_dirty = $templateDirty
		engine_template = $templateName
		engine_version = $engineVersion
		engine_changelist = [long]$buildData.Changelist
		recipe = [string]$recipeData.recipe
		purpose = [string]$recipeData.purpose
		plugins = $pluginVersions
		project_differences = $projectDifferences
	}
	$lockJson = ConvertTo-Json -InputObject $lock -Depth 12

	$recipeOutput = Join-Path $destinationPath 'Recipe'
	[System.IO.Directory]::CreateDirectory($recipeOutput) | Out-Null
	Copy-Item -LiteralPath (Join-Path $recipeRoot 'common\SET.md') -Destination (Join-Path $recipeOutput 'SET.md')
	Copy-Item -LiteralPath (Join-Path (Join-Path $recipeRoot $Recipe) 'recipe.json') -Destination (Join-Path $recipeOutput 'recipe.json')
	Copy-Item -LiteralPath (Join-Path (Join-Path $recipeRoot $Recipe) 'Capture.md') -Destination (Join-Path $recipeOutput 'Capture.md')
	if ($Recipe -eq 'spectator-explore') {
		Copy-Item -LiteralPath (Join-Path (Join-Path $recipeRoot $Recipe) 'Play.md') -Destination (Join-Path $recipeOutput 'Play.md')
		$onlinePluginTarget = Join-Path $destinationPath 'Plugins\MulticaOnlineStarter'
		[System.IO.Directory]::CreateDirectory($onlinePluginTarget) | Out-Null
		Get-ChildItem -LiteralPath (Join-Path $repoRoot 'templates\online\MulticaOnlineStarter') -Force | ForEach-Object {
			Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $onlinePluginTarget $_.Name) -Recurse
		}
	}

	$lockPath = Join-Path $destinationPath 'template-lock.json'
	[System.IO.File]::WriteAllText($lockPath, $lockJson + [Environment]::NewLine, $utf8NoBom)

	$projectFile = Join-Path $destinationPath ($templateName + '.uproject')
	if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) {
		throw 'The installed template project file was not copied.'
	}
	Write-Output "Created $destinationName from the installed $templateName template (UE $engineVersion, recipe $Recipe)."
} catch {
	throw "Scaffold generation stopped. The exclusive output directory was left untouched by cleanup to avoid deleting work: $destinationPath. $($_.Exception.Message)"
}
