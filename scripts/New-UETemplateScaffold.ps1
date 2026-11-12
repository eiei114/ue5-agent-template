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

function Resolve-ContainedPath([string]$Root, [string]$Candidate, [string]$Label) {
	# Single containment rule for every write this generator performs: normalize the candidate and
	# require it to stay under $Root (the exclusive output directory) before anything is created.
	# TemplateDefs.ini decides the destination of individual files (FolderRenames / SharedContentPacks),
	# so a value containing `..` must be rejected here rather than trusted.
	$rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
	$rootPrefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
	$resolved = ''
	try {
		$resolved = [System.IO.Path]::GetFullPath($Candidate)
	} catch {
		throw ("Container escape stopped the scaffold: {0} could not be normalized as a file path ({1})." -f $Label, $_.Exception.Message)
	}
	if (-not $resolved.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
		throw ("Container escape stopped the scaffold: {0} resolved to '{1}', outside the allowed root '{2}'. Nothing outside '{2}' was written." -f $Label, $resolved, $rootFull)
	}
	return $resolved
}

function Resolve-SharedContentPack([string]$EngineTemplateRoot, [string]$Mount, [string]$PreferredDetailLevel) {
	# The installed engine only ships some mounts at some detail levels (TP_FirstPerson declares Weapons
	# at "Standard" while its EditDetailLevelPreference is "High"). The preference of the template is
	# tried first, then the remaining installed levels in a fixed order, so a declared pack is either
	# copied and recorded with the level it actually came from, or reported as missing. The per-mount
	# DetailLevels tuple written next to each MountName is not interpreted here.
	$candidates = @(@($PreferredDetailLevel, 'High', 'Standard') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
	foreach ($level in $candidates) {
		$packContent = Join-Path $EngineTemplateRoot ("TemplateResources\{0}\{1}\Content" -f $level, $Mount)
		if (Test-Path -LiteralPath $packContent -PathType Container) {
			return [pscustomobject]@{ Mount = $Mount; DetailLevel = $level; Path = $packContent }
		}
	}
	throw ("Shared content pack is missing from the installed engine: {0} (tried detail levels {1} below {2})" -f $Mount, ($candidates -join ', '), $EngineTemplateRoot)
}

function Copy-TemplateTree {
	# Single copy implementation for both the raw-copy and the materialize path. Every recipe reads the
	# template's own Config/TemplateDefs.ini: FoldersToIgnore / FilesToIgnore decide what is copied and
	# SharedContentPacks decide which installed content packs are mounted into Content/. Renaming
	# (FolderRenames, filename and in-file replacement, CoreRedirects, ProjectID) happens only when
	# -Materialize is set, because the raw-copy recipes keep the template's project and module names.
	param(
		[Parameter(Mandatory = $true)][string]$SourceTemplate,
		[Parameter(Mandatory = $true)][string]$Destination,
		[Parameter(Mandatory = $true)][string]$TemplateName,
		[Parameter(Mandatory = $true)][string]$ProjectFileName,
		[Parameter(Mandatory = $true)][string]$Name,
		[Parameter(Mandatory = $true)][string]$EngineTemplateRoot,
		[switch]$Materialize
	)

	$defsPath = Join-Path $SourceTemplate 'Config\TemplateDefs.ini'
	if (-not (Test-Path -LiteralPath $defsPath -PathType Leaf)) { throw "The template has no Config/TemplateDefs.ini to copy from: $defsPath" }
	$defs = Read-TemplateDefs -Path $defsPath -TemplateName $TemplateName
	$sourceRoot = [System.IO.Path]::GetFullPath($SourceTemplate).TrimEnd('\', '/')
	foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force) {
		$relative = $file.FullName.Substring($sourceRoot.Length + 1).Replace('\', '/')
		# TemplateDefs.ini names the template project file in FilesToIgnore, because the wizard writes a
		# renamed descriptor instead. Both paths still need that descriptor, so it is copied to the project
		# file name this run publishes and is exempt from the ignore rules.
		if ($relative -ieq "$TemplateName.uproject") {
			Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $Destination $ProjectFileName)
			continue
		}
		if (@($defs.FilesToIgnore | Where-Object { $relative -ieq $_ }).Count -gt 0) { continue }
		if (@($defs.FoldersToIgnore | Where-Object { $relative.StartsWith($_.TrimEnd('/') + '/', [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { continue }
		$target = $relative
		$isText = $false
		if ($Materialize) {
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
		}
		$targetPath = Resolve-ContainedPath -Root $Destination -Candidate (Join-Path $Destination $target.Replace('/', '\')) -Label "FolderRenames/ReplacementsInFiles target '$target' for template file '$relative'"
		[System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($targetPath)) | Out-Null
		if (Test-Path -LiteralPath $targetPath) { throw "Template copy paths collide: $target" }
		if ($isText) { Copy-TextWithReplacement -From $file.FullName -To $targetPath -TemplateName $TemplateName -Name $Name }
		else { Copy-Item -LiteralPath $file.FullName -Destination $targetPath }
	}
	$copiedPacks = [System.Collections.Generic.List[object]]::new()
	foreach ($mount in $defs.SharedContentPacks) {
		$pack = Resolve-SharedContentPack -EngineTemplateRoot $EngineTemplateRoot -Mount $mount -PreferredDetailLevel $defs.DetailLevel
		$packContent = $pack.Path
		$packTarget = Resolve-ContainedPath -Root $Destination -Candidate (Join-Path $Destination ("Content\" + $mount)) -Label "SharedContentPacks MountName '$mount' from TemplateDefs.ini"
		[System.IO.Directory]::CreateDirectory($packTarget) | Out-Null
		# The pack copy is a write target too: contain every entry under the output directory and
		# refuse to overwrite an existing file, exactly like the per-file copy above. Recurse explicitly
		# instead of Copy-Item -Recurse so each target is checked before it is written.
		$packPrefix = $packContent.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
		foreach ($packEntry in @(Get-ChildItem -LiteralPath $packContent -Recurse -Force)) {
			$packRelative = $packEntry.FullName.Substring($packPrefix.Length).Replace('\', '/')
			$entryTarget = Resolve-ContainedPath -Root $Destination -Candidate (Join-Path $packTarget $packEntry.FullName.Substring($packPrefix.Length)) -Label "shared content pack entry 'Content/$mount/$packRelative'"
			if ($packEntry.PSIsContainer) {
				# Directories may merge with the template's own tree; a file where the pack needs a
				# directory is a contradiction the caller has to resolve.
				if (Test-Path -LiteralPath $entryTarget -PathType Leaf) { throw "Materialized template paths collide: Content/$mount/$packRelative" }
				[System.IO.Directory]::CreateDirectory($entryTarget) | Out-Null
			} else {
				if (Test-Path -LiteralPath $entryTarget) { throw "Materialized template paths collide: Content/$mount/$packRelative" }
				[System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($entryTarget)) | Out-Null
				Copy-Item -LiteralPath $packEntry.FullName -Destination $entryTarget
			}
		}
		$copiedPacks.Add($pack)
	}
	if ($Materialize) {
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
	return [pscustomobject]@{
		SharedContentPacks = @($copiedPacks)
		FoldersToIgnore = @($defs.FoldersToIgnore).Count
		FilesToIgnore = @($defs.FilesToIgnore).Count
		DetailLevel = $defs.DetailLevel
	}
}

function Get-DeclaredGameMapPaths([string]$ProjectConfigPath) {
	# Returns the /Game/ map package paths a generated project declares as its default and editor
	# startup map. Non-/Game/ paths (engine content such as /Engine/Maps/Templates/OpenWorld) are not
	# part of the project tree and are not checked.
	$declared = [System.Collections.Generic.List[string]]::new()
	if (-not (Test-Path -LiteralPath $ProjectConfigPath -PathType Leaf)) { return @() }
	$inMapsSection = $false
	foreach ($line in [System.IO.File]::ReadAllLines($ProjectConfigPath)) {
		$trimmed = $line.Trim()
		if ($trimmed -match '^\[(.+)\]$') { $inMapsSection = $Matches[1] -eq '/Script/EngineSettings.GameMapsSettings'; continue }
		if (-not $inMapsSection) { continue }
		if ($trimmed -match '^(GameDefaultMap|EditorStartupMap)=(.*)$') {
			$value = $Matches[2].Split(';')[0].Trim()
			if ($value -match '^/Game/' -and -not $declared.Contains($value)) { $declared.Add($value) }
		}
	}
	return @($declared)
}

function Convert-GamePackagePathToAssetPath([string]$GamePackagePath) {
	# '/Game/FirstPerson/Lvl_FirstPerson.Lvl_FirstPerson' is Content/FirstPerson/Lvl_FirstPerson.umap.
	$body = $GamePackagePath.Substring('/Game/'.Length)
	$lastSlash = $body.LastIndexOf('/')
	if ($lastSlash -ge 0) {
		$directory = $body.Substring(0, $lastSlash)
		$leaf = $body.Substring($lastSlash + 1)
	} else {
		$directory = ''
		$leaf = $body
	}
	$dot = $leaf.IndexOf('.')
	if ($dot -ge 0) { $leaf = $leaf.Substring(0, $dot) }
	if ($directory) { return "Content/$directory/$leaf.umap" }
	return "Content/$leaf.umap"
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
$destinationPath = Resolve-ContainedPath -Root $productionRoot -Candidate (Join-Path $productionRoot $destinationName) -Label 'the output directory computed from Production'

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
	# Both paths go through the same copy implementation. The raw-copy recipes keep the template's
	# project file name and module names, but they still honour the template's own Config/TemplateDefs.ini
	# FoldersToIgnore / FilesToIgnore rules and its SharedContentPacks, because a project that is missing
	# the content the default map references opens with missing assets while still reporting success.
	$copyReport = Copy-TemplateTree -SourceTemplate $sourceTemplate -Destination $destinationPath -TemplateName $templateName -ProjectFileName $projectFileName -Name $ProjectName -EngineTemplateRoot $engineTemplateRoot -Materialize:$materialize

	$projectFile = Join-Path $destinationPath $projectFileName
	if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) {
		throw "The installed template project file was not copied to $projectFileName."
	}
	# The generated project's Config declares the map it will open. If that package is not in the
	# output, the first README step (open the project, press Play) lands on an unresolved map, so the
	# generator must stop instead of printing success. This is a bounded path check over the copied
	# tree, not an asset-registry load.
	[string[]]$declaredMaps = @(Get-DeclaredGameMapPaths -ProjectConfigPath (Join-Path $destinationPath 'Config\DefaultEngine.ini'))
	$missingMaps = [System.Collections.Generic.List[string]]::new()
	foreach ($declaredMap in $declaredMaps) {
		$assetRelative = Convert-GamePackagePathToAssetPath $declaredMap
		if (-not (Test-Path -LiteralPath (Join-Path $destinationPath $assetRelative.Replace('/', '\')) -PathType Leaf)) {
			$missingMaps.Add(('{0} -> {1}' -f $declaredMap, $assetRelative))
		}
	}
	if ($missingMaps.Count -gt 0) {
		throw ('Default map check stopped: the generated project declares maps that are not in the output, so opening it would show an unresolved map. Missing: ' + ($missingMaps -join '; '))
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
	$packDetailLevels = [ordered]@{}
	foreach ($pack in @($copyReport.SharedContentPacks)) { $packDetailLevels[$pack.Mount] = $pack.DetailLevel }
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
		# What the template's own Config/TemplateDefs.ini contributed to this output. Both copy paths
		# record it so a later reader can tell which installed content packs were mounted (and at which
		# detail level) and how many ignore rules were applied, without re-reading the engine install.
		shared_content_packs = @($copyReport.SharedContentPacks | ForEach-Object { $_.Mount })
		shared_content_pack_detail_levels = $packDetailLevels
		template_defs_ignore_rules = [ordered]@{
			folders_to_ignore = [int]$copyReport.FoldersToIgnore
			files_to_ignore = [int]$copyReport.FilesToIgnore
		}
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
