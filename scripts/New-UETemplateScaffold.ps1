[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)]
	[ValidateSet('spectator-explore', 'vertical-loop', 'third-person-game')]
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

function Convert-TemplateName([string]$Text, [string]$TemplateName, [string]$Name) {
	# Same order as TemplateDefs.ini: UPPERCASE and lowercase (case-sensitive), then any case.
	$Text = $Text.Replace($TemplateName.ToUpperInvariant(), $Name.ToUpperInvariant())
	$Text = $Text.Replace($TemplateName.ToLowerInvariant(), $Name.ToLowerInvariant())
	return [regex]::Replace($Text, [regex]::Escape($TemplateName), $Name.Replace('$', '$$'), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Read-TemplateDefs([string]$Path, [string]$TemplateName) {
	$defs = [ordered]@{ FoldersToIgnore = @(); FilesToIgnore = @(); FolderRenames = @(); Extensions = @(); SharedContentPacks = @(); DetailLevel = 'High' }
	foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
		$trimmed = $line.Trim()
		if ($trimmed -match '^FoldersToIgnore=(.+)$') { $defs.FoldersToIgnore += $Matches[1].Trim('"').Replace('%TEMPLATENAME%', $TemplateName).Replace('\', '/') }
		elseif ($trimmed -match '^FilesToIgnore=(.+)$') { $defs.FilesToIgnore += $Matches[1].Trim('"').Replace('%TEMPLATENAME%', $TemplateName).Replace('\', '/') }
		elseif ($trimmed -match '^FolderRenames=\(From="([^"]+)",To="([^"]+)"\)') { $defs.FolderRenames += ,@($Matches[1].Replace('%TEMPLATENAME%', $TemplateName), $Matches[2]) }
		elseif ($trimmed -match '^ReplacementsInFiles=\(Extensions=\(([^)]*)\)') { $defs.Extensions += @($Matches[1].Split(',') | ForEach-Object { $_.Trim().Trim('"').ToLowerInvariant() }) }
		elseif ($trimmed -match '^SharedContentPacks=\(MountName="([^"]+)"') { $defs.SharedContentPacks += $Matches[1] }
		elseif ($trimmed -match '^EditDetailLevelPreference="?([^"]+)"?$') { $defs.DetailLevel = $Matches[1] }
	}
	$defs.Extensions = @($defs.Extensions | Select-Object -Unique)
	$defs.SharedContentPacks = @($defs.SharedContentPacks | Select-Object -Unique)
	return $defs
}

function Copy-TextWithReplacement([string]$From, [string]$To, [string]$TemplateName, [string]$Name) {
	$reader = [System.IO.StreamReader]::new($From, [System.Text.UTF8Encoding]::new($false), $true)
	try { $text = $reader.ReadToEnd(); $encoding = $reader.CurrentEncoding } finally { $reader.Dispose() }
	$hadBom = $false
	$bytes = [System.IO.File]::ReadAllBytes($From)
	if ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) -or ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) { $hadBom = $true }
	if (-not $hadBom -and $encoding -is [System.Text.UTF8Encoding]) { $encoding = [System.Text.UTF8Encoding]::new($false) }
	[System.IO.File]::WriteAllText($To, (Convert-TemplateName -Text $text -TemplateName $TemplateName -Name $Name), $encoding)
}

function Copy-MaterializedTemplate([string]$SourceTemplate, [string]$Destination, [string]$TemplateName, [string]$Name, [string]$EngineTemplateRoot) {
	$defsPath = Join-Path $SourceTemplate 'Config\TemplateDefs.ini'
	if (-not (Test-Path -LiteralPath $defsPath -PathType Leaf)) { throw "The template has no Config/TemplateDefs.ini to materialize from: $defsPath" }
	$defs = Read-TemplateDefs -Path $defsPath -TemplateName $TemplateName
	$sourceRoot = [System.IO.Path]::GetFullPath($SourceTemplate).TrimEnd('\', '/')
	foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force) {
		$relative = $file.FullName.Substring($sourceRoot.Length + 1).Replace('\', '/')
		if ($relative -ieq "$TemplateName.uproject") {
			Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $Destination "$Name.uproject")
			continue
		}
		if (@($defs.FilesToIgnore | Where-Object { $relative -ieq $_ }).Count -gt 0) { continue }
		if (@($defs.FoldersToIgnore | Where-Object { $relative.StartsWith($_.TrimEnd('/') + '/', [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { continue }
		$target = $relative
		foreach ($rename in $defs.FolderRenames) {
			$from = $rename[0].TrimEnd('/') + '/'
			if ($target.StartsWith($from, [System.StringComparison]::OrdinalIgnoreCase)) {
				$target = $rename[1].Replace('%PROJECTNAME%', $Name).TrimEnd('/') + '/' + $target.Substring($from.Length)
			}
		}
		$extension = [System.IO.Path]::GetExtension($file.Name).TrimStart('.').ToLowerInvariant()
		$isText = $defs.Extensions -contains $extension
		if ($isText) {
			$leaf = Convert-TemplateName -Text ([System.IO.Path]::GetFileName($target)) -TemplateName $TemplateName -Name $Name
			$target = ([System.IO.Path]::GetDirectoryName($target.Replace('/', '\')) + '\' + $leaf).TrimStart('\')
		}
		$targetPath = Join-Path $Destination $target.Replace('/', '\')
		[System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($targetPath)) | Out-Null
		if (Test-Path -LiteralPath $targetPath) { throw "Materialized template paths collide: $target" }
		if ($isText) { Copy-TextWithReplacement -From $file.FullName -To $targetPath -TemplateName $TemplateName -Name $Name }
		else { Copy-Item -LiteralPath $file.FullName -Destination $targetPath }
	}
	foreach ($mount in $defs.SharedContentPacks) {
		$packContent = Join-Path $EngineTemplateRoot ("TemplateResources\{0}\{1}\Content" -f $defs.DetailLevel, $mount)
		if (-not (Test-Path -LiteralPath $packContent -PathType Container)) { throw "Shared content pack is missing from the installed engine: $packContent" }
		$packTarget = Join-Path $Destination ("Content\" + $mount)
		[System.IO.Directory]::CreateDirectory($packTarget) | Out-Null
		Get-ChildItem -LiteralPath $packContent -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $packTarget $_.Name) -Recurse }
	}
	# Blueprints in the template Content were saved against /Script/<TemplateName>.
	$engineIni = Join-Path $Destination 'Config\DefaultEngine.ini'
	[System.IO.File]::AppendAllText($engineIni, [Environment]::NewLine + '[CoreRedirects]' + [Environment]::NewLine + ('+PackageRedirects=(OldName="/Script/{0}",NewName="/Script/{1}")' -f $TemplateName, $Name) + [Environment]::NewLine)
	$gameIni = Join-Path $Destination 'Config\DefaultGame.ini'
	if (Test-Path -LiteralPath $gameIni -PathType Leaf) {
		$guid = [Guid]::NewGuid().ToByteArray()
		$parts = 0..3 | ForEach-Object { [BitConverter]::ToInt32($guid, $_ * 4) }
		$gameText = [System.IO.File]::ReadAllText($gameIni)
		$gameText = [regex]::Replace($gameText, '(?m)^ProjectID=.*$', ('ProjectID=(A={0},B={1},C={2},D={3})' -f $parts[0], $parts[1], $parts[2], $parts[3]))
		$gameText = [regex]::Replace($gameText, '(?m)^ProjectName=.*$', ('ProjectName={0}' -f $Name))
		[System.IO.File]::WriteAllText($gameIni, $gameText, [System.Text.UTF8Encoding]::new($false))
	}
}

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
# materialize_project: apply the template's own Config/TemplateDefs.ini rules (as the UE New Project
# wizard does) so the output is <ProjectName>.uproject with renamed module/source, not TP_* names.
$materialize = ($null -ne $recipeData.PSObject.Properties['materialize_project']) -and [bool]$recipeData.materialize_project
if ($materialize -and $ProjectName -notmatch '^[A-Za-z][A-Za-z0-9_]{0,39}$') {
	throw 'Recipes that materialize a C++ project need a ProjectName that is a C++ identifier (letter first, letters/digits/underscore only).'
}
$projectFileName = if ($materialize) { $ProjectName + '.uproject' } else { $templateName + '.uproject' }

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
	if ($materialize) {
		Copy-MaterializedTemplate -SourceTemplate $sourceTemplate -Destination $destinationPath -TemplateName $templateName -Name $ProjectName -EngineTemplateRoot $engineTemplateRoot
	} else {
		Get-ChildItem -LiteralPath $sourceTemplate -Force | ForEach-Object {
			Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $destinationPath $_.Name) -Recurse
		}
	}

	$projectDescriptor = Get-Content -Raw -LiteralPath (Join-Path $destinationPath $projectFileName) | ConvertFrom-Json
	if ($materialize) {
		foreach ($module in @($projectDescriptor.Modules | Where-Object { $null -ne $_ })) {
			$module.Name = Convert-TemplateName -Text ([string]$module.Name) -TemplateName $templateName -Name $ProjectName
		}
		$projectDescriptor.EngineAssociation = '{0}.{1}' -f $buildData.MajorVersion, $buildData.MinorVersion
	}
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
	[System.IO.File]::WriteAllText((Join-Path $destinationPath $projectFileName), $projectJson + [Environment]::NewLine, $utf8NoBom)

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
	if ($Recipe -eq 'third-person-game') {
		Copy-Item -LiteralPath (Join-Path (Join-Path $recipeRoot $Recipe) 'Play.md') -Destination (Join-Path $recipeOutput 'Play.md')
	}
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

	$projectFile = Join-Path $destinationPath $projectFileName
	if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) {
		throw 'The installed template project file was not copied.'
	}
	Write-Output "Created $destinationName from the installed $templateName template (UE $engineVersion, recipe $Recipe)."
} catch {
	throw "Scaffold generation stopped. The exclusive output directory was left untouched by cleanup to avoid deleting work: $destinationPath. $($_.Exception.Message)"
}
