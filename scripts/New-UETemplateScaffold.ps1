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

$projectSettingsSection = '/Script/EngineSettings.GeneralProjectSettings'

function Get-ProjectIdBytes([string]$ProjectName) {
	# The identity is derived from the project name instead of a fresh random GUID so that regenerating
	# the same project in another run directory reproduces the same template-lock.json (the lock is the
	# reproducibility record, and a random ID inside it would defeat that). A different project name
	# still yields a different ID, which is the property that was missing while raw copies inherited
	# the template's own ProjectID. The online session identifier is name-derived for the same reason.
	$sha = [System.Security.Cryptography.SHA256]::Create()
	try { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes('ue5-agent-template:GeneralProjectSettings:ProjectID:' + $ProjectName)) } finally { $sha.Dispose() }
	return [byte[]]$hash[0..15]
}

function Split-IniSections {
	# Splits ini lines into blocks: the preamble (Name '') plus one block per section header. Moving
	# keys between sections therefore rewrites only the identity lines instead of regenerating the file.
	param([AllowEmptyCollection()][string[]]$Lines)
	$blocks = New-Object 'System.Collections.Generic.List[object]'
	$current = [pscustomobject]@{ Name = ''; Lines = (New-Object 'System.Collections.Generic.List[string]') }
	$blocks.Add($current)
	for ($index = 0; $index -lt $Lines.Count; $index++) {
		$trimmed = $Lines[$index].Trim()
		if ($trimmed -match '^\[(.+)\]$') {
			$current = [pscustomobject]@{ Name = $Matches[1].Trim(); Lines = (New-Object 'System.Collections.Generic.List[string]') }
			$blocks.Add($current)
			continue
		}
		$current.Lines.Add($Lines[$index])
	}
	# Unary comma keeps the List intact: enumerating it would hand the caller an Object[] without Add().
	return ,$blocks
}

function Get-ProjectIdentityEntries([string[]]$Lines) {
	# Reports every ProjectID / ProjectName line together with the section header it sits under, so a
	# caller can tell an effective identity from one the engine never reads. The engine matches section
	# names exactly (`FConfigFileMap` is a TMap with no short-name aliasing), so '[ProjectSettings]' is
	# not an alias of the canonical name.
	$entries = New-Object 'System.Collections.Generic.List[object]'
	$section = ''
	for ($index = 0; $index -lt $Lines.Count; $index++) {
		$trimmed = $Lines[$index].Trim()
		if ($trimmed -match '^\[(.+)\]$') { $section = $Matches[1].Trim(); continue }
		if ($trimmed -match '^(ProjectID|ProjectName)[ \t]*=[ \t]*(.*)$') {
			$entries.Add([pscustomobject]@{ Section = $section; Key = $Matches[1]; Value = $Matches[2].Trim() })
		}
	}
	return $entries
}

function Set-ProjectIdentity {
	# Writes the generated project's own ProjectID / ProjectName into Config/DefaultGame.ini under the
	# one section name the engine resolves. The installed templates are not uniform: TP_FirstPerson
	# declares the identity under the short '[ProjectSettings]' header, which UGeneralProjectSettings
	# (UCLASS(config=Game, defaultconfig), no OverrideConfigSection) never reads, and TP_BlankBP ships
	# a 2 byte file with no identity at all. Copying either one and appending a second block would keep
	# an identity the engine ignores, or give every generated project the template's own ID.
	# So normalize instead of guessing: identity keys move into the canonical section, a section that
	# held nothing else is dropped, and anything this function cannot fold deterministically stops
	# generation with the file, sections and keys named.
	param(
		[Parameter(Mandatory = $true)][string]$GameIniPath,
		[Parameter(Mandatory = $true)][string]$Name
	)

	$newLine = "`r`n"
	$text = ''
	if (Test-Path -LiteralPath $GameIniPath -PathType Leaf) { $text = [System.IO.File]::ReadAllText($GameIniPath) }
	$lines = @($text -split "`r`n|`n|`r")
	while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) { $lines = @($lines | Select-Object -First ($lines.Count - 1)) }

	$blocks = Split-IniSections -Lines $lines
	$entries = @(Get-ProjectIdentityEntries -Lines $lines)

	$duplicates = @($entries | Group-Object -Property Key | Where-Object { $_.Count -gt 1 })
	if ($duplicates.Count -gt 0) {
		$details = @($duplicates | ForEach-Object {
			$sections = @($_.Group | ForEach-Object { if ([string]::IsNullOrEmpty($_.Section)) { '<no section>' } else { '[' + $_.Section + ']' } })
			'{0} in {1}' -f $_.Name, ($sections -join ' and ')
		})
		throw ("Project identity check stopped: {0} declares the same identity key more than once ({1}), so it cannot be folded into {2} without guessing. Leave one {3} block in that file and regenerate." -f $GameIniPath, ($details -join '; '), $projectSettingsSection, $projectSettingsSection)
	}

	$removedFromSections = @($entries | Where-Object { -not [string]::IsNullOrEmpty($_.Section) -and $_.Section -ine $projectSettingsSection } | ForEach-Object { $_.Section })
	foreach ($block in $blocks) {
		$identityLines = @($block.Lines | Where-Object { $_.Trim() -match '^(ProjectID|ProjectName)[ \t]*=' })
		foreach ($identityLine in $identityLines) { [void]$block.Lines.Remove($identityLine) }
	}

	# A short header that held nothing but the identity is dead weight in the generated project: the
	# engine never reads it, and leaving it invites someone to put the identity back there.
	$blocksToDrop = New-Object 'System.Collections.Generic.List[object]'
	foreach ($block in $blocks) {
		if ([string]::IsNullOrEmpty($block.Name) -or $block.Name -ieq $projectSettingsSection) { continue }
		$hasContent = @($block.Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Trim()) }).Count -gt 0
		if (-not $hasContent -and ($removedFromSections -contains $block.Name)) { $blocksToDrop.Add($block) }
	}

	$guidBytes = Get-ProjectIdBytes -ProjectName $Name
	$parts = 0..3 | ForEach-Object { [BitConverter]::ToInt32($guidBytes, $_ * 4) }
	$projectIdText = '(A={0},B={1},C={2},D={3})' -f $parts[0], $parts[1], $parts[2], $parts[3]
	$identityBlockLines = @(('ProjectID={0}' -f $projectIdText), ('ProjectName={0}' -f $Name))

	$canonicalBlock = @($blocks | Where-Object { $_.Name -ieq $projectSettingsSection }) | Select-Object -First 1
	$createdSection = $null -eq $canonicalBlock
	if ($createdSection) {
		$canonicalBlock = [pscustomobject]@{ Name = $projectSettingsSection; Lines = (New-Object 'System.Collections.Generic.List[string]') }
		$blocks.Add($canonicalBlock)
	}
	# InsertRange keeps the template's other keys in that section (TP_FirstPerson and TP_ThirdPerson
	# carry nothing else today, installed templates may) while the identity always lands first.
	$canonicalBlock.Lines.InsertRange(0, [string[]]$identityBlockLines)

	$outputLines = New-Object 'System.Collections.Generic.List[string]'
	foreach ($block in $blocks) {
		if ($blocksToDrop -contains $block) { continue }
		if (-not [string]::IsNullOrEmpty($block.Name)) {
			# Separate an appended block from the previous content so the header starts on its own line.
			if ($block -eq $canonicalBlock -and $createdSection -and $outputLines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($outputLines[$outputLines.Count - 1])) { $outputLines.Add('') }
			$outputLines.Add('[' + $block.Name + ']')
			foreach ($line in $block.Lines) { $outputLines.Add($line) }
			continue
		}
		# Before the first header the template file may hold blank lines only (TP_BlankBP is just 2 bytes);
		# writing them back as the head of the file carries no setting and only misleads the reader.
		foreach ($line in $block.Lines) { if (-not [string]::IsNullOrWhiteSpace($line)) { $outputLines.Add($line) } }
	}

	$directory = [System.IO.Path]::GetDirectoryName($GameIniPath)
	[System.IO.Directory]::CreateDirectory($directory) | Out-Null
	[System.IO.File]::WriteAllText($GameIniPath, (($outputLines -join $newLine) + $newLine), [System.Text.UTF8Encoding]::new($false))

	# Read the file back: a write that landed under a header the engine ignores must not be reported as
	# success, so the effective identity is verified on the artifact rather than assumed from the input.
	$writtenEntries = @(Get-ProjectIdentityEntries -Lines ([System.IO.File]::ReadAllLines($GameIniPath)))
	if ($writtenEntries.Count -ne 2 -or
		$writtenEntries[0].Key -ne 'ProjectID' -or $writtenEntries[0].Section -ine $projectSettingsSection -or
		$writtenEntries[1].Key -ne 'ProjectName' -or $writtenEntries[1].Section -ine $projectSettingsSection) {
		$observed = @($writtenEntries | ForEach-Object { '{0} under [{1}]' -f $_.Key, $_.Section }) -join ', '
		throw ("Project identity check stopped: the ProjectID / ProjectName written to {0} are not both under {1} (observed: {2}). No identity was left in a section the engine ignores." -f $GameIniPath, $projectSettingsSection, $observed)
	}
	if ($writtenEntries[0].Value -cne $projectIdText -or $writtenEntries[1].Value -cne $Name) {
		throw ("Project identity check stopped: {0} does not carry the expected ProjectID / ProjectName after writing." -f $GameIniPath)
	}

	return [pscustomobject]@{
		Section = $projectSettingsSection
		ProjectId = $projectIdText
		ProjectName = $Name
		NormalizedFromSection = if ($removedFromSections.Count -gt 0) { $removedFromSections[0] } else { $null }
		CreatedSection = $createdSection
	}
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
	# Project identity is written once, in Set-ProjectIdentity, for materialized and copied recipes alike:
	# rewriting only the ProjectID / ProjectName lines (as this loop used to) keeps whichever section
	# header the template shipped, and the short one is invisible to the engine.
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

	# Every recipe owns its project identity. A raw copy carries the template's own ProjectID and
	# 'TP_* Template' ProjectName, so two projects generated from different names would share one ID.
	$gameIniPath = Join-Path $destinationPath 'Config\DefaultGame.ini'
	$gameIniIdentity = Set-ProjectIdentity -GameIniPath $gameIniPath -Name $ProjectName

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
		schema_version = 3
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
		default_game_ini_identity = [ordered]@{
			section = $gameIniIdentity.Section
			project_id = $gameIniIdentity.ProjectId
			project_name = $gameIniIdentity.ProjectName
			normalized_from_section = $gameIniIdentity.NormalizedFromSection
			created_section = $gameIniIdentity.CreatedSection
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
