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
	$defs = [ordered]@{
		FoldersToIgnore    = @()
		FilesToIgnore      = @()
		FolderRenames      = @()
		Extensions         = @()
		SharedContentPacks = @()
		DetailLevel        = 'High'
		UnreadableLines    = @()
	}
	# The installed engine templates write the same rule two ways — `FolderRenames=(From="...", To="...")`
	# and the unspaced `,To="` form — so whitespace around `=` and between tuple fields is optional here.
	# This only widens what parses: a rule this reader drops is applied by nobody, and the output then
	# keeps the template's own module directory while the descriptor claims the project name. The two
	# patterns therefore stay unanchored at the end, as before: a rule followed by trailing text was
	# applied by the previous reader, and nobody can tell whether some installed template relies on it.
	$ruleSection = '[/Script/GameProjectGeneration.TemplateProjectDefs]'
	$parsedKeys = @('FoldersToIgnore', 'FilesToIgnore', 'FolderRenames', 'ReplacementsInFiles', 'SharedContentPacks', 'EditDetailLevelPreference')
	$section = $null
	$lineNumber = 0
	foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
		$lineNumber++
		$trimmed = $line.Trim()
		if ($trimmed -match '^\[(.+)\]$') { $section = $trimmed; continue }
		if ($trimmed -eq '' -or $trimmed.StartsWith(';')) { continue }
		# Rules are applied from every section, as before, so no file that parsed previously is rejected
		# now; only the unreadable-line report is scoped to the section that is supposed to hold them.
		$inRuleSection = ($null -eq $section) -or ($section -ceq $ruleSection)
		$key = ''
		if ($trimmed -match '^([A-Za-z]+)[ \t]*=') { $key = $Matches[1] }
		elseif ($trimmed -match '^([A-Za-z]+)$') { $key = $Matches[1] }
		$wasRead = $false
		# The key comparison stays case-insensitive (PowerShell's default) so the spellings this reader
		# accepted before still parse; nothing that used to be read is now rejected.
		switch ($key) {
			'FoldersToIgnore' {
				if ($trimmed -match '^FoldersToIgnore[ \t]*=[ \t]*(.+)$') {
					$defs.FoldersToIgnore += $Matches[1].Trim().Trim('"').Replace('%TEMPLATENAME%', $TemplateName).Replace('\', '/')
					$wasRead = $true
				}
			}
			'FilesToIgnore' {
				if ($trimmed -match '^FilesToIgnore[ \t]*=[ \t]*(.+)$') {
					$defs.FilesToIgnore += $Matches[1].Trim().Trim('"').Replace('%TEMPLATENAME%', $TemplateName).Replace('\', '/')
					$wasRead = $true
				}
			}
			'FolderRenames' {
				if ($trimmed -match '^FolderRenames[ \t]*=[ \t]*\([ \t]*From[ \t]*=[ \t]*"([^"]+)"[ \t]*,[ \t]*To[ \t]*=[ \t]*"([^"]+)"[ \t]*\)') {
					$defs.FolderRenames += ,@($Matches[1].Replace('%TEMPLATENAME%', $TemplateName), $Matches[2])
					$wasRead = $true
				}
			}
			'ReplacementsInFiles' {
				if ($trimmed -match '^ReplacementsInFiles[ \t]*=[ \t]*\([ \t]*Extensions[ \t]*=[ \t]*\(([^)]*)\)') {
					$defs.Extensions += @($Matches[1].Split(',') | ForEach-Object { $_.Trim().Trim('"').ToLowerInvariant() })
					$wasRead = $true
				}
			}
			'SharedContentPacks' {
				if ($trimmed -match '^SharedContentPacks[ \t]*=[ \t]*\([ \t]*MountName[ \t]*=[ \t]*"([^"]+)"') {
					$defs.SharedContentPacks += $Matches[1]
					$wasRead = $true
				}
			}
			'EditDetailLevelPreference' {
				# The value stays any run of characters up to the closing quote, as before, so a quoted
				# multi-word preference ("High Quality") is still read instead of silently reverting to
				# the default; surrounding spaces are trimmed because the value becomes a path segment.
				if ($trimmed -match '^EditDetailLevelPreference[ \t]*=[ \t]*"?([^"]+)"?$') {
					$defs.DetailLevel = $Matches[1].Trim()
					$wasRead = $true
				}
			}
		}
		if ($wasRead) { continue }
		# A rule the reader claims to apply but produced nothing is reported instead of being skipped
		# quietly: a rule nobody applied must not look like a successful materialization. The run
		# continues, because a template may still carry a form this reader does not know; the
		# post-copy identity check below is what turns a dropped folder rename into a stop.
		# `FilenameReplacements` is not listed: whether it is implemented is the
		# materialization-fidelity issue (DOT-3135), and one owner keeps that layer.
		if ($inRuleSection -and ($parsedKeys -contains $key)) {
			$defs.UnreadableLines += ('line {0}: {1}' -f $lineNumber, $trimmed)
		}
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

function Set-OnlineSessionProjectIdentifier([string]$ProjectConfigPath, [string]$Identifier) {
	# The switch has to live in the project's Config/DefaultEngine.ini: a plugin's own
	# Config/DefaultEngine.ini is never merged, because engine and project branches take
	# precedence over plugin layers, so the setting would never reach GEngineIni.
	$configText = ''
	if (Test-Path -LiteralPath $ProjectConfigPath -PathType Leaf) {
		$configText = [System.IO.File]::ReadAllText($ProjectConfigPath)
	} elseif (-not (Test-Path -LiteralPath (Split-Path -Parent $ProjectConfigPath) -PathType Container)) {
		throw "The generated project has no Config directory: $ProjectConfigPath"
	}
	if ([regex]::IsMatch($configText, '(?m)^\[MulticaOnlineStarter\][ \t]*\r?$') -or
		[regex]::IsMatch($configText, '(?m)^SessionProjectIdentifier=')) {
		throw 'The generated project engine config already defines the online session identifier.'
	}
	if ([regex]::IsMatch($configText, '(?m)^\[OnlineSubsystem\][ \t]*\r?$')) {
		# Keep one owner for the provider selection: append only our own section.
		$configText = $configText.TrimEnd("`r", "`n") + [Environment]::NewLine +
			'[MulticaOnlineStarter]' + [Environment]::NewLine +
			('SessionProjectIdentifier={0}' -f $Identifier) + [Environment]::NewLine
	} else {
		$configText = $configText.TrimEnd("`r", "`n") + [Environment]::NewLine +
			'[OnlineSubsystem]' + [Environment]::NewLine +
			'DefaultPlatformService=Null' + [Environment]::NewLine + [Environment]::NewLine +
			'[MulticaOnlineStarter]' + [Environment]::NewLine +
			('SessionProjectIdentifier={0}' -f $Identifier) + [Environment]::NewLine
	}
	[System.IO.File]::WriteAllText($ProjectConfigPath, $configText, [System.Text.UTF8Encoding]::new($false))
}

function Copy-MaterializedTemplate([string]$SourceTemplate, [string]$Destination, [string]$TemplateName, [string]$Name, [string]$EngineTemplateRoot) {
	$defsPath = Join-Path $SourceTemplate 'Config\TemplateDefs.ini'
	if (-not (Test-Path -LiteralPath $defsPath -PathType Leaf)) { throw "The template has no Config/TemplateDefs.ini to materialize from: $defsPath" }
	$defs = Read-TemplateDefs -Path $defsPath -TemplateName $TemplateName
	foreach ($unreadable in @($defs.UnreadableLines)) {
		Write-Warning ('TemplateDefs.ini rule was not understood and was skipped ({0}): {1}' -f $defsPath, $unreadable)
	}
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
# A missing, empty or non-numeric field cannot produce a describable EngineAssociation: the
# derived value would be a fragment such as '.8', which the descriptor and the lock would then
# record as fact. Reject it before anything is copied.
foreach ($requiredBuildField in @('MajorVersion', 'MinorVersion', 'PatchVersion', 'Changelist')) {
	$buildFieldValue = if ($null -ne $buildData.PSObject.Properties[$requiredBuildField]) { [string]$buildData.$requiredBuildField } else { '' }
	if ($buildFieldValue -notmatch '^[0-9]+$') {
		throw "Engine/Build/Build.version does not define a numeric $requiredBuildField, so the project engine association cannot be recorded: $engineBuildFile"
	}
}
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

# Project identity contract: the generated project keeps the installed template's project file
# name and module names, and always carries a concrete EngineAssociation. The identity is
# checked against Source/ before anything is copied, so an unmatched template layout stops the
# run instead of emitting a raw copy whose identity nobody can explain.
function Get-ScaffoldIdentityReport {
	# Compares a project descriptor's Modules[].Name against a Source/ tree and reports both
	# directions of a mismatch. Returns one object so callers do not depend on pipeline output.
	param(
		[Parameter(Mandatory = $true)]$Descriptor,
		[Parameter(Mandatory = $true)][string]$SourceRoot,
		[Parameter(Mandatory = $true)][string]$ProjectFileName
	)

	[string[]]$declaredModules = @()
	foreach ($moduleEntry in @($Descriptor.Modules | Where-Object { $null -ne $_ })) {
		$moduleName = [string]$moduleEntry.Name
		if ([string]::IsNullOrWhiteSpace($moduleName)) {
			throw "Project identity check stopped: $ProjectFileName contains a Modules entry without a Name. No project was copied."
		}
		$declaredModules += $moduleName
	}
	[Array]::Sort($declaredModules, [System.StringComparer]::Ordinal)

	$problems = [System.Collections.Generic.List[string]]::new()
	[string[]]$sourceModuleNames = @()
	if (Test-Path -LiteralPath $SourceRoot -PathType Container) {
		foreach ($moduleDirectory in @(Get-ChildItem -LiteralPath $SourceRoot -Directory -Force)) {
			$moduleBuildFile = Join-Path $moduleDirectory.FullName ($moduleDirectory.Name + '.Build.cs')
			if (Test-Path -LiteralPath $moduleBuildFile -PathType Leaf) {
				$sourceModuleNames += $moduleDirectory.Name
			} else {
				$problems.Add(('Source/{0}/ is not a module directory: Source/{0}/{0}.Build.cs is missing' -f $moduleDirectory.Name))
			}
		}
	}
	[Array]::Sort($sourceModuleNames, [System.StringComparer]::Ordinal)
	foreach ($moduleName in $declaredModules) {
		if ($sourceModuleNames -notcontains $moduleName) {
			$problems.Add(('Modules[].Name "{0}" in {1} has no Source/{0}/{0}.Build.cs' -f $moduleName, $ProjectFileName))
		}
	}
	foreach ($moduleName in $sourceModuleNames) {
		if ($declaredModules -notcontains $moduleName) {
			$problems.Add(('Source/{0}/{0}.Build.cs is missing from {1} Modules[].Name' -f $moduleName, $ProjectFileName))
		}
	}

	return [pscustomobject]@{
		Modules = $declaredModules
		Problems = $problems
	}
}

$templateDescriptor = Get-Content -Raw -LiteralPath $templateProjectFile | ConvertFrom-Json
$templateIdentity = Get-ScaffoldIdentityReport -Descriptor $templateDescriptor -SourceRoot (Join-Path $sourceTemplate 'Source') -ProjectFileName ($templateName + '.uproject')
if ($templateIdentity.Problems.Count -gt 0) {
	throw ('Project identity check stopped: the installed template project/module identity does not match the expected pattern, so no raw-copied project was produced. Unmatched paths: ' + ($templateIdentity.Problems -join '; '))
}
$engineAssociationValue = [string]$templateDescriptor.EngineAssociation
if ([string]::IsNullOrWhiteSpace($engineAssociationValue)) {
	$engineAssociationValue = '{0}.{1}' -f $buildData.MajorVersion, $buildData.MinorVersion
}
if ([string]::IsNullOrWhiteSpace($engineAssociationValue)) {
	throw "Project identity check stopped: no EngineAssociation could be derived for $projectFileName. No project was copied."
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
	if ($materialize) {
		Copy-MaterializedTemplate -SourceTemplate $sourceTemplate -Destination $destinationPath -TemplateName $templateName -Name $ProjectName -EngineTemplateRoot $engineTemplateRoot
	} else {
		Get-ChildItem -LiteralPath $sourceTemplate -Force | ForEach-Object {
			Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $destinationPath $_.Name) -Recurse
		}
	}

	$projectFile = Join-Path $destinationPath $projectFileName
	if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) {
		throw "The installed template project file was not copied to $projectFileName."
	}
	# The identity contract describes the generated project, so verify the descriptor that was
	# actually copied against the Source/ tree that was actually copied. The pre-copy check above
	# proves the template is sound; this proves the artifact matches it. A materialized recipe is
	# checked after its module rename, so the descriptor and Source/ are compared in the shape the
	# generated project actually has.
	$projectDescriptor = Get-Content -Raw -LiteralPath $projectFile | ConvertFrom-Json
	if ($materialize) {
		foreach ($module in @($projectDescriptor.Modules | Where-Object { $null -ne $_ })) {
			$module.Name = Convert-TemplateName -Text ([string]$module.Name) -TemplateName $templateName -Name $ProjectName
		}
	}
	$copiedIdentity = Get-ScaffoldIdentityReport -Descriptor $projectDescriptor -SourceRoot (Join-Path $destinationPath 'Source') -ProjectFileName $projectFileName
	if ($copiedIdentity.Problems.Count -gt 0) {
		throw ('Project identity check stopped: the copied project/module identity does not match the copied Source/ tree, so the project descriptor was not rewritten. Unmatched paths: ' + ($copiedIdentity.Problems -join '; '))
	}
	[string[]]$moduleNames = @($copiedIdentity.Modules)
	if ($null -eq $projectDescriptor.PSObject.Properties['EngineAssociation']) {
		$projectDescriptor | Add-Member -MemberType NoteProperty -Name EngineAssociation -Value $engineAssociationValue
	} else {
		$projectDescriptor.EngineAssociation = $engineAssociationValue
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
	[System.IO.File]::WriteAllText($projectFile, $projectJson + [Environment]::NewLine, $utf8NoBom)

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
		schema_version = 2
		template_repository = 'https://github.com/eiei114/ue5-agent-template'
		template_commit = $gitCommit
		template_worktree_dirty = $templateDirty
		engine_template = $templateName
		engine_version = $engineVersion
		engine_changelist = [long]$buildData.Changelist
		identity = [ordered]@{
			project_file = $projectFileName
			project_modules = @($moduleNames)
			engine_association = $engineAssociationValue
		}
		recipe = [string]$recipeData.recipe
		purpose = [string]$recipeData.purpose
		plugins = $pluginVersions
		online_session_identifier = if (@($recipeData.required_plugins) -contains 'MulticaOnlineStarter') { 'eiei114.ue5-agent-template:{0}' -f $ProjectName } else { $null }
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
		$onlineGuideTarget = Join-Path $destinationPath 'docs'
		[System.IO.Directory]::CreateDirectory($onlineGuideTarget) | Out-Null
		Copy-Item -LiteralPath (Join-Path $repoRoot 'docs\08-online-foundations.md') -Destination (Join-Path $onlineGuideTarget '08-online-foundations.md')
		$onlinePluginTarget = Join-Path $destinationPath 'Plugins\MulticaOnlineStarter'
		[System.IO.Directory]::CreateDirectory($onlinePluginTarget) | Out-Null
		Get-ChildItem -LiteralPath (Join-Path $repoRoot 'templates\online\MulticaOnlineStarter') -Force | ForEach-Object {
			Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $onlinePluginTarget $_.Name) -Recurse
		}
		Set-OnlineSessionProjectIdentifier `
			-ProjectConfigPath (Join-Path $destinationPath 'Config\DefaultEngine.ini') `
			-Identifier ('eiei114.ue5-agent-template:{0}' -f $ProjectName)
	}

	$lockPath = Join-Path $destinationPath 'template-lock.json'
	[System.IO.File]::WriteAllText($lockPath, $lockJson + [Environment]::NewLine, $utf8NoBom)

	if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) {
		throw "The installed template project file was not copied to $projectFileName."
	}
	$writtenDescriptor = Get-Content -Raw -LiteralPath $projectFile | ConvertFrom-Json
	if ([string]$writtenDescriptor.EngineAssociation -ne $engineAssociationValue) {
		throw "Project identity check stopped: $projectFileName was written without the expected EngineAssociation '$engineAssociationValue'."
	}
	Write-Output "Created $destinationName from the installed $templateName template ($projectFileName, EngineAssociation '$engineAssociationValue', UE $engineVersion, recipe $Recipe)."
} catch {
	throw "Scaffold generation stopped. The exclusive output directory was left untouched by cleanup to avoid deleting work: $destinationPath. $($_.Exception.Message)"
}
