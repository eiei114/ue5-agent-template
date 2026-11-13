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

function Expand-TemplateTokens([string]$Value, [string]$TemplateName, [string]$Name) {
	# The installed engine templates write the two names through tokens instead of a fixed string, so
	# a declared rule is expanded before it is applied. A token this generator does not know is left as
	# written and reported: the rule would otherwise be applied to a literal '%SOMETHING%' and look
	# like it had run.
	$unknown = [System.Collections.Generic.List[string]]::new()
	$builder = [System.Text.StringBuilder]::new()
	$cursor = 0
	foreach ($match in [regex]::Matches($Value, '%([A-Za-z0-9_]+)%')) {
		$null = $builder.Append($Value.Substring($cursor, $match.Index - $cursor))
		$cursor = $match.Index + $match.Length
		$replacement = switch ($match.Groups[1].Value) {
			'TEMPLATENAME' { $TemplateName }
			'TEMPLATENAME_UPPERCASE' { $TemplateName.ToUpperInvariant() }
			'TEMPLATENAME_LOWERCASE' { $TemplateName.ToLowerInvariant() }
			'PROJECTNAME' { $Name }
			'PROJECTNAME_UPPERCASE' { $Name.ToUpperInvariant() }
			'PROJECTNAME_LOWERCASE' { $Name.ToLowerInvariant() }
			default { $null }
		}
		if ($null -eq $replacement) {
			$unknown.Add($match.Value)
			$null = $builder.Append($match.Value)
		} else {
			$null = $builder.Append($replacement)
		}
	}
	$null = $builder.Append($Value.Substring($cursor))
	return [pscustomobject]@{ Text = $builder.ToString(); UnknownTokens = @($unknown) }
}

function New-TemplateRule([string]$Line, [string]$Kind, [string]$TemplateName, [string]$Name) {
	# One FilenameReplacements / ReplacementsInFiles tuple. Field order is not fixed. A tuple this
	# reader cannot read is returned as $null so the caller reports it instead of applying a rule the
	# template author did not write.
	$extensionsMatch = [regex]::Match($Line, 'Extensions[ \t]*=[ \t]*\(([^)]*)\)')
	$fromMatch = [regex]::Match($Line, 'From[ \t]*=[ \t]*"([^"]*)"')
	$toMatch = [regex]::Match($Line, 'To[ \t]*=[ \t]*"([^"]*)"')
	$caseMatch = [regex]::Match($Line, 'bCaseSensitive[ \t]*=[ \t]*(true|false)')
	if (-not $extensionsMatch.Success -or -not $fromMatch.Success -or -not $toMatch.Success -or -not $caseMatch.Success) { return $null }
	$extensions = @($extensionsMatch.Groups[1].Value.Split(',') | ForEach-Object { $_.Trim().Trim('"').ToLowerInvariant() } | Where-Object { $_ -ne '' })
	if ($extensions.Count -eq 0) { return $null }
	$from = Expand-TemplateTokens -Value $fromMatch.Groups[1].Value -TemplateName $TemplateName -Name $Name
	$to = Expand-TemplateTokens -Value $toMatch.Groups[1].Value -TemplateName $TemplateName -Name $Name
	if (@($from.UnknownTokens).Count -gt 0 -or @($to.UnknownTokens).Count -gt 0) { return $null }
	if ([string]::IsNullOrEmpty([string]$from.Text)) { return $null }
	return [pscustomobject]@{
		Kind          = $Kind
		Extensions    = $extensions
		From          = [string]$from.Text
		To            = [string]$to.Text
		CaseSensitive = ($caseMatch.Groups[1].Value -eq 'true')
	}
}

function Invoke-TemplateRules([string]$Text, $Rules, [string]$Extension, [switch]$AnyExtension) {
	# Rules apply in declaration order, which is how the installed templates encode UPPERCASE /
	# lowercase / any-case as three separate tuples. Case sensitivity comes from the tuple, not from a
	# fixed three-pass order.
	foreach ($rule in @($Rules)) {
		if (-not $AnyExtension -and $null -ne $Extension -and -not (@($rule.Extensions) -contains $Extension.ToLowerInvariant())) { continue }
		if ($rule.CaseSensitive) {
			$Text = $Text.Replace($rule.From, $rule.To)
		} else {
			$Text = [regex]::Replace($Text, [regex]::Escape($rule.From), $rule.To.Replace('$', '$$'), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
		}
	}
	return $Text
}

function Read-TemplateDefs([string]$Path, [string]$TemplateName, [string]$Name) {
	$defs = [ordered]@{
		FoldersToIgnore    = @()
		FilesToIgnore      = @()
		FolderRenames      = @()
		FilenameRules      = @()
		ContentRules       = @()
		SharedContentPacks = @()
		DetailLevel        = 'High'
		AppliedKeys        = @()
		IgnoredKeys        = @()
		UnreadableLines    = @()
	}
	# File-name renaming and in-file replacement are separate declarations with separate extension
	# lists: read them separately so a template that renames .cpp file names without rewriting .cpp
	# contents gets exactly that. Whitespace around `=` and inside the tuple is optional because the
	# installed templates write both `From="...",To="..."` and `From="...", To="..."`.
	# A key this reader does not implement is recorded, never dropped quietly. The installed templates
	# carry wizard metadata (LocalizedDisplayNames, Categories, Variants, ClassTypes, ...) that cannot
	# be applied here, so warning and continuing is the fixed behaviour: stopping would reject every
	# real engine template. What was applied and what was ignored is written to template-lock.json.
	$implemented = @('FoldersToIgnore', 'FilesToIgnore', 'FolderRenames', 'FilenameReplacements', 'ReplacementsInFiles', 'SharedContentPacks', 'EditDetailLevelPreference')
	$applied = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	$ignored = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	$problems = [System.Collections.Generic.List[string]]::new()
	$lineNumber = 0
	foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
		$lineNumber++
		$trimmed = $line.Trim()
		if ($trimmed -eq '' -or $trimmed.StartsWith(';') -or $trimmed -match '^\[.+\]$') { continue }
		$keyMatch = [regex]::Match($trimmed, '^([A-Za-z][A-Za-z0-9_]*)[ \t]*=')
		if (-not $keyMatch.Success) { continue }
		$key = $keyMatch.Groups[1].Value
		$value = $trimmed.Substring($keyMatch.Length).Trim()
		$read = $false
		if ($key -eq 'FoldersToIgnore' -or $key -eq 'FilesToIgnore') {
			$entry = Expand-TemplateTokens -Value $value.Trim('"') -TemplateName $TemplateName -Name $Name
			if (@($entry.UnknownTokens).Count -eq 0) {
				$normalized = ([string]$entry.Text).Replace('\', '/')
				if ($key -eq 'FoldersToIgnore') { $defs.FoldersToIgnore += $normalized } else { $defs.FilesToIgnore += $normalized }
				$read = $true
			}
		} elseif ($key -eq 'FolderRenames') {
			$renameMatch = [regex]::Match($value, '^\([ \t]*From[ \t]*=[ \t]*"([^"]+)"[ \t]*,[ \t]*To[ \t]*=[ \t]*"([^"]+)"[ \t]*\)')
			if ($renameMatch.Success) {
				$from = Expand-TemplateTokens -Value $renameMatch.Groups[1].Value -TemplateName $TemplateName -Name $Name
				$to = Expand-TemplateTokens -Value $renameMatch.Groups[2].Value -TemplateName $TemplateName -Name $Name
				if (@($from.UnknownTokens).Count -eq 0 -and @($to.UnknownTokens).Count -eq 0) {
					$defs.FolderRenames += ,@([string]$from.Text, [string]$to.Text)
					$read = $true
				}
			}
		} elseif ($key -eq 'FilenameReplacements' -or $key -eq 'ReplacementsInFiles') {
			$kind = if ($key -eq 'FilenameReplacements') { 'Filename' } else { 'Content' }
			$rule = New-TemplateRule -Line $value -Kind $kind -TemplateName $TemplateName -Name $Name
			if ($null -ne $rule) {
				if ($kind -eq 'Filename') { $defs.FilenameRules += $rule } else { $defs.ContentRules += $rule }
				$read = $true
			}
		} elseif ($key -eq 'SharedContentPacks') {
			$mountMatch = [regex]::Match($value, 'MountName[ \t]*=[ \t]*"([^"]+)"')
			if ($mountMatch.Success) {
				$levels = @()
				$levelMatch = [regex]::Match($value, 'DetailLevels[ \t]*=[ \t]*\(([^)]*)\)')
				if ($levelMatch.Success) { $levels = @($levelMatch.Groups[1].Value.Split(',') | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ -ne '' }) }
				$defs.SharedContentPacks += [pscustomobject]@{ Mount = [string]$mountMatch.Groups[1].Value; DetailLevels = @($levels) }
				$read = $true
			}
		} elseif ($key -eq 'EditDetailLevelPreference') {
			$preferenceMatch = [regex]::Match($value, '^"?([^"\s]+)"?$')
			if ($preferenceMatch.Success) {
				$defs.DetailLevel = [string]$preferenceMatch.Groups[1].Value
				$read = $true
			}
		}
		if ($read) { $null = $applied.Add($key) }
		elseif ($implemented -contains $key) { $problems.Add(('line {0}: {1} was not understood and was not applied: {2}' -f $lineNumber, $key, $trimmed)) }
		else { $null = $ignored.Add($key) }
	}
	$defs.AppliedKeys = @($applied)
	[Array]::Sort($defs.AppliedKeys, [System.StringComparer]::OrdinalIgnoreCase)
	$defs.IgnoredKeys = @($ignored)
	[Array]::Sort($defs.IgnoredKeys, [System.StringComparer]::OrdinalIgnoreCase)
	$defs.UnreadableLines = @($problems)
	return $defs
}

function Copy-TextWithReplacement([string]$From, [string]$To, $Rules, [string]$Extension) {
	$reader = [System.IO.StreamReader]::new($From, [System.Text.UTF8Encoding]::new($false), $true)
	try { $text = $reader.ReadToEnd(); $encoding = $reader.CurrentEncoding } finally { $reader.Dispose() }
	$hadBom = $false
	$bytes = [System.IO.File]::ReadAllBytes($From)
	if ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) -or ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) { $hadBom = $true }
	if (-not $hadBom -and $encoding -is [System.Text.UTF8Encoding]) { $encoding = [System.Text.UTF8Encoding]::new($false) }
	[System.IO.File]::WriteAllText($To, (Invoke-TemplateRules -Text $text -Rules $Rules -Extension $Extension), $encoding)
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

function Resolve-SharedContentPack([string]$EngineTemplateRoot, $Pack, [string]$PreferredDetailLevel) {
	# A template may declare a different detail level per mount (TP_FirstPerson declares Weapons at
	# "Standard" while its EditDetailLevelPreference is "High"). The declared levels are tried first,
	# then the template preference, then the installed levels in a fixed order, so a mount that exists
	# is copied from the level the template asked for. A fall back to a level the template did not
	# declare is reported to the caller instead of passing as declared behaviour.
	$declared = @(@($Pack.DetailLevels) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
	$fallBack = @(@($PreferredDetailLevel, 'High', 'Standard') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
	$candidates = @($declared + $fallBack | Select-Object -Unique)
	foreach ($level in $candidates) {
		$packContent = Join-Path $EngineTemplateRoot ("TemplateResources\{0}\{1}\Content" -f $level, $Pack.Mount)
		if (Test-Path -LiteralPath $packContent -PathType Container) {
			return [pscustomobject]@{
				Mount               = [string]$Pack.Mount
				DetailLevel         = $level
				DeclaredDetailLevel = ($declared -contains $level)
				Path                = $packContent
			}
		}
	}
	throw ("Shared content pack is missing from the installed engine: {0} (declared detail levels {1}, tried {2}, below {3})" -f $Pack.Mount, $(if ($declared.Count -gt 0) { $declared -join ', ' } else { 'none' }), ($candidates -join ', '), $EngineTemplateRoot)
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
	$defs = Read-TemplateDefs -Path $defsPath -TemplateName $TemplateName -Name $Name
	foreach ($unreadable in @($defs.UnreadableLines)) {
		Write-Warning ('TemplateDefs.ini rule was not understood and was not applied ({0}): {1}' -f $defsPath, $unreadable)
	}
	foreach ($ignoredKey in @($defs.IgnoredKeys)) {
		# The installed templates carry wizard metadata that this generator cannot apply
		# (LocalizedDisplayNames, Categories, Variants, ...). Reporting it keeps a declared key from
		# disappearing silently, while continuing keeps a real engine template usable. What was
		# applied and what was ignored is also written to template-lock.json.
		Write-Warning ('TemplateDefs.ini key {0} is not implemented by this generator and was not applied ({1})' -f $ignoredKey, $defsPath)
	}
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
					$target = $rename[1].TrimEnd('/') + '/' + $target.Substring($from.Length)
				}
			}
			$extension = [System.IO.Path]::GetExtension($file.Name).TrimStart('.').ToLowerInvariant()
			# The file name is renamed by FilenameReplacements, the text by ReplacementsInFiles. They are
			# different declarations and may carry different extension lists, so neither decides for the
			# other: a template can rename .cpp file names without rewriting .cpp contents.
			$newLeaf = [System.IO.Path]::GetFileName($target)
			if (@($defs.FilenameRules).Count -gt 0) {
				$newLeaf = Invoke-TemplateRules -Text $newLeaf -Rules $defs.FilenameRules -Extension $extension
			}
			if ($newLeaf -cne [System.IO.Path]::GetFileName($target)) {
				$target = ([System.IO.Path]::GetDirectoryName($target.Replace('/', '\')) + '\' + $newLeaf).TrimStart('\')
			}
			# A declared ReplacementsInFiles extension list decides which files are rewritten as text;
			# everything else is byte-copied so binary content is never decoded.
			$isText = @($defs.ContentRules | Where-Object { $_.Extensions -contains $extension }).Count -gt 0
		}
		$targetPath = Join-Path $Destination $target.Replace('/', '\')
		[System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($targetPath)) | Out-Null
		if (Test-Path -LiteralPath $targetPath) { throw "Template copy paths collide: $target" }
		if ($isText) { Copy-TextWithReplacement -From $file.FullName -To $targetPath -Rules $defs.ContentRules -Extension $extension }
		else { Copy-Item -LiteralPath $file.FullName -Destination $targetPath }
	}
	$copiedPacks = [System.Collections.Generic.List[object]]::new()
	foreach ($pack in $defs.SharedContentPacks) {
		$resolved = Resolve-SharedContentPack -EngineTemplateRoot $EngineTemplateRoot -Pack $pack -PreferredDetailLevel $defs.DetailLevel
		if (-not $resolved.DeclaredDetailLevel) {
			Write-Warning ('Shared content pack {0} was declared for detail level(s) {1} but was copied from {2}; EditDetailLevelPreference={3}' -f $resolved.Mount, $(if (@($pack.DetailLevels).Count -gt 0) { @($pack.DetailLevels) -join ', ' } else { 'none' }), $resolved.DetailLevel, $defs.DetailLevel)
		}
		$packTarget = Join-Path $Destination ("Content\" + $resolved.Mount)
		[System.IO.Directory]::CreateDirectory($packTarget) | Out-Null
		Get-ChildItem -LiteralPath $resolved.Path -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $packTarget $_.Name) -Recurse }
		$copiedPacks.Add($resolved)
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
		ContentRules     = @($defs.ContentRules)
		AppliedKeys      = @($defs.AppliedKeys)
		IgnoredKeys      = @($defs.IgnoredKeys)
		UnreadableLines  = @($defs.UnreadableLines)
		SharedContentPacks = @($copiedPacks)
		EditDetailLevelPreference = $defs.DetailLevel
		FoldersToIgnore = @($defs.FoldersToIgnore).Count
		FilesToIgnore = @($defs.FilesToIgnore).Count
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
		# The descriptor is not covered by the extension lists a template writes (it is JSON), but
		# its Modules[].Name has to follow the same declared replacements as the Source/ tree, otherwise
		# the copied project would advertise a module whose Build.cs is not there. The declared rules are
		# applied to the module name as text; if no declared rule changes it, the identity check below
		# stops and names the unmatched paths instead of writing a descriptor nobody can explain.
		foreach ($module in @($projectDescriptor.Modules | Where-Object { $null -ne $_ })) {
			$module.Name = Invoke-TemplateRules -Text ([string]$module.Name) -Rules $copyReport.ContentRules -AnyExtension
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
		# Which TemplateDefs.ini keys the generator applied, which it could not apply, and every key or
		# line it does not understand. `main` still writes this under template_defs; the per-mount
		# detail level record is kept at the same place so a reader finds the whole rule report in
		# one object for both copy paths.
		template_defs = [ordered]@{
			applied_keys = @($copyReport.AppliedKeys)
			ignored_keys = @($copyReport.IgnoredKeys)
			unreadable_lines = @($copyReport.UnreadableLines)
			edit_detail_level_preference = $copyReport.EditDetailLevelPreference
			shared_content_packs = @($copyReport.SharedContentPacks | ForEach-Object { [ordered]@{ mount = $_.Mount; detail_level = $_.DetailLevel; declared = $_.DeclaredDetailLevel } })
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
