[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)]
	# The selectable recipes are data, not a hardcoded list: any directory under
	# templates/recipes/ that carries a valid recipe.json is a recipe, so adding a genre layer
	# must not require editing this script. The pattern only keeps the name a safe path segment.
	[ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$')]
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

	[switch]$AllowDirtyTemplate,

	# Permits a lock whose template commit is not proven retrievable from the recorded template
	# repository. The probe still runs when a repository is recorded, so the lock carries the real
	# outcome (true/false) or null when the probe could not answer. It is never true for an
	# unverified commit.
	[switch]$AllowUnpublishedTemplate,

	# Skips the retrieval probe entirely and records template_commit_published = null (未検査).
	# Use it when the recorded repository cannot be reached from this host (offline work), never to
	# turn an unpublished commit into a published one.
	[switch]$SkipTemplatePublishCheck,

	# Budget for the longest path the generator is about to write, in characters. The default
	# follows this repository's own recorded failure (docs/08-online-foundations.md:47, 2026-11-01:
	# a UE Editor build had to move the checkout to a temporary drive because of the 260-character
	# path limit) and the Windows MAX_PATH default documented by Microsoft. It is a declared budget,
	# not a claim that every toolchain fails at this length. Raise it explicitly and record why in QA
	# instead of letting the generator write a tree nobody measured.
	[ValidateRange(1, 32767)]
	[int]$MaxPathLength = 260
)

$ErrorActionPreference = 'Stop'

# The only recipe.json contract this generator implements. A file declaring another version is rejected
# rather than partially honoured, so a future field cannot be silently ignored.
$recipeSchemaVersion = 1
$knownPluginNames = @('MovieRenderPipeline', 'MulticaOnlineStarter', 'OnlineSubsystem', 'OnlineSubsystemNull', 'OnlineSubsystemUtils')

function Read-RecipeData {
	# Validates the recipe contract before anything is generated. Every value that reaches the lock comes
	# from here, so an unknown value is a stop condition and never an empty string in the record.
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][string]$DirectoryName
	)

	try { $data = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json } catch {
		throw "recipe.json is not readable JSON: $Path. $($_.Exception.Message)"
	}
	if ($data -isnot [pscustomobject]) { throw "recipe.json must be a JSON object, not an array or a scalar: $Path" }

	$schemaEntry = $data.PSObject.Properties['schema_version']
	$schemaValue = if ($null -ne $schemaEntry -and $null -ne $schemaEntry.Value) { [string]$schemaEntry.Value } else { '' }
	if ([string]::IsNullOrWhiteSpace($schemaValue)) {
		throw "recipe.json does not declare schema_version, so the generator cannot tell which recipe contract it follows: $Path"
	}
	if ($schemaValue -notmatch '^[0-9]+$' -or [int]$schemaValue -ne $recipeSchemaVersion) {
		throw "recipe.json declares schema_version '$schemaValue', but this generator implements only schema_version ${recipeSchemaVersion}: $Path"
	}

	foreach ($field in @('recipe', 'purpose', 'engine_template')) {
		$entry = $data.PSObject.Properties[$field]
		$value = if ($null -ne $entry) { $entry.Value } else { $null }
		if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
			throw "recipe.json must declare $field as a non-empty string; an unknown value is never recorded as an empty string: $Path"
		}
	}
	# One identity, not two: the directory is what the generator synthesizes, so a recipe.json naming
	# another recipe would make the lock disagree with the generated tree.
	if ([string]$data.recipe -cne $DirectoryName) {
		throw "recipe.json declares recipe '$($data.recipe)' but lives in templates/recipes/$DirectoryName; the generated project records the directory it was generated from, so both names must match: $Path"
	}

	$pluginEntry = $data.PSObject.Properties['required_plugins']
	if ($null -eq $pluginEntry -or $null -eq $pluginEntry.Value) {
		throw "recipe.json does not declare required_plugins, so nothing selects the plugin payload: $Path"
	}
	if ($pluginEntry.Value -is [string]) {
		throw "recipe.json must declare required_plugins as a JSON array of plugin names, not a single string: $Path"
	}
	[string[]]$pluginNames = @()
	foreach ($item in @($pluginEntry.Value)) {
		if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace($item)) {
			throw "recipe.json contains a required_plugins entry that is not a non-empty plugin name: $Path"
		}
		$trimmedPluginName = $item.Trim()
		if ($pluginNames -ccontains $trimmedPluginName) {
			throw "recipe.json lists the plugin '$trimmedPluginName' more than once: $Path"
		}
		$pluginNames += $trimmedPluginName
	}

	$materialize = $false
	$materializeEntry = $data.PSObject.Properties['materialize_project']
	if ($null -ne $materializeEntry -and $null -ne $materializeEntry.Value) {
		if ($materializeEntry.Value -isnot [bool]) {
			throw "recipe.json must declare materialize_project as true or false, not '$($materializeEntry.Value)': $Path"
		}
		$materialize = [bool]$materializeEntry.Value
	}

	return [pscustomobject]@{
		Recipe = $DirectoryName
		Purpose = [string]$data.purpose
		EngineTemplate = [string]$data.engine_template
		RequiredPlugins = $pluginNames
		MaterializeProject = $materialize
		SchemaVersion = $recipeSchemaVersion
	}
}

function Get-PluginDescriptorPath {
	# Resolves a declared plugin name to the descriptor whose version the lock records. The repository's
	# own plugin comes from this checkout; engine plugins come from the installed engine. Any other name
	# is data the generator cannot honour, so it stops instead of generating a partial plugin tree.
	param(
		[Parameter(Mandatory = $true)][string]$PluginName,
		[Parameter(Mandatory = $true)][string]$RepositoryRoot,
		[Parameter(Mandatory = $true)][string]$EngineRootPath
	)

	switch ($PluginName) {
		'MulticaOnlineStarter' { return Join-Path $RepositoryRoot 'templates\online\MulticaOnlineStarter\MulticaOnlineStarter.uplugin' }
		'OnlineSubsystem' { return Join-Path $EngineRootPath 'Engine\Plugins\Online\OnlineSubsystem\OnlineSubsystem.uplugin' }
		'OnlineSubsystemNull' { return Join-Path $EngineRootPath 'Engine\Plugins\Online\OnlineSubsystemNull\OnlineSubsystemNull.uplugin' }
		'OnlineSubsystemUtils' { return Join-Path $EngineRootPath 'Engine\Plugins\Online\OnlineSubsystemUtils\OnlineSubsystemUtils.uplugin' }
		'MovieRenderPipeline' { return Join-Path $EngineRootPath 'Engine\Plugins\MovieScene\MovieRenderPipeline\MovieRenderPipeline.uplugin' }
		default {
			throw ("recipe.json requires the plugin '{0}', which has no descriptor in this generator, so the generated project cannot record its version. Known plugins: {1}. Nothing was generated." -f $PluginName, ($knownPluginNames -join ', '))
		}
	}
}

function Convert-TemplateName([string]$Text, [string]$TemplateName, [string]$Name) {
	# Same order as TemplateDefs.ini: UPPERCASE and lowercase (case-sensitive), then any case.
	$Text = $Text.Replace($TemplateName.ToUpperInvariant(), $Name.ToUpperInvariant())
	$Text = $Text.Replace($TemplateName.ToLowerInvariant(), $Name.ToLowerInvariant())
	return [regex]::Replace($Text, [regex]::Escape($TemplateName), $Name.Replace('$', '$$'), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Read-TemplateDefs([string]$Path, [string]$TemplateName) {

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

function Test-IsReflectedHeader([string]$Path) {
	# The UE New Project wizard treats a renamed header as a UObject class only when the *copied*
	# file's contents contain the UHT include (DefaultTemplateProjectDefs.cpp IsClassRename).
	# Log-category headers, interfaces without that include, and everything that is not a header
	# must not produce a class redirect.
	# IndexOf rather than Contains(string, StringComparison): the latter needs .NET Core and the
	# suite is also run under Windows PowerShell 5.1.
	return [System.IO.File]::ReadAllText($Path).IndexOf('.generated.h"', [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Add-IniSectionEntries([string]$IniPath, [string]$SectionName, [string[]]$Entries = @()) {
	# Writes `+Key=(...)` entries into `SectionName`, creating the section at the end of the file when
	# it is absent. The wizard's SaveConfigValues() appends these values to the generated project's
	# DefaultEngine.ini, so the generator uses the same owner and placement instead of inventing a
	# second redirect mechanism.
	if ($Entries.Count -eq 0) { return }
	$newLine = [Environment]::NewLine
	$text = if (Test-Path -LiteralPath $IniPath -PathType Leaf) { [System.IO.File]::ReadAllText($IniPath) } else { '' }
	$block = ($Entries -join $newLine) + $newLine
	$sectionPattern = '(?im)^\[' + [regex]::Escape($SectionName) + '\][ \t]*\r?\n'
	if ([regex]::IsMatch($text, $sectionPattern)) {
		$sectionRegex = [regex]::new($sectionPattern)
		$text = $sectionRegex.Replace($text, [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $match.Value + $block }, 1)
	} else {
		$text = $text.TrimEnd("`r", "`n") + $newLine + $newLine + $SectionName + $newLine + $block
	}
	[System.IO.File]::WriteAllText($IniPath, $text, [System.Text.UTF8Encoding]::new($false))
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
    Copy-TemplateTreeImpl -SourceTemplate $SourceTemplate -Destination $Destination -TemplateName $TemplateName -ProjectFileName $ProjectFileName -Name $Name -EngineTemplateRoot $EngineTemplateRoot -Materialize:$Materialize
}


# Single source of truth for "where does this template file land", used both by the copy and by
# the pre-copy path budget, so the measured paths are the paths that actually get written.
function Get-MaterializedTarget([string]$RelativePath, $Defs, [string]$TemplateName, [string]$Name) {
	if ($RelativePath -ieq "$TemplateName.uproject") {
		return [pscustomobject]@{ Target = "$Name.uproject"; IsCopy = $true }
	}
	if (@($Defs.FilesToIgnore | Where-Object { $RelativePath -ieq $_ }).Count -gt 0) { return $null }
	if (@($Defs.FoldersToIgnore | Where-Object { $RelativePath.StartsWith($_.TrimEnd('/') + '/', [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { return $null }
	$target = $RelativePath
	foreach ($rename in $Defs.FolderRenames) {
		$from = $rename[0].TrimEnd('/') + '/'
		if ($target.StartsWith($from, [System.StringComparison]::OrdinalIgnoreCase)) {
			$target = $rename[1].Replace('%PROJECTNAME%', $Name).TrimEnd('/') + '/' + $target.Substring($from.Length)
		}
	}
	$extension = [System.IO.Path]::GetExtension([System.IO.Path]::GetFileName($RelativePath)).TrimStart('.').ToLowerInvariant()
	$isText = $Defs.Extensions -contains $extension
	if ($isText) {
		$leaf = Convert-TemplateName -Text ([System.IO.Path]::GetFileName($target)) -TemplateName $TemplateName -Name $Name
		$target = ([System.IO.Path]::GetDirectoryName($target.Replace('/', '\')) + '\' + $leaf).TrimStart('\')
	}
	return [pscustomobject]@{ Target = $target; IsCopy = -not $isText }
}

function Get-SharedContentPackRoot([string]$EngineTemplateRoot, $Defs, [string]$MountName) {
	return Join-Path $EngineTemplateRoot ("TemplateResources\{0}\{1}\Content" -f $Defs.DetailLevel, $MountName)
}

function Measure-GeneratedPathBudget([string]$Destination, $RelativePaths) {
	# Length of the longest path the generator is about to write, measured as the real absolute
	# path string (Windows counts every character of it, separators included).
	$longestPath = $Destination
	$longestRelative = '(the output directory itself)'
	foreach ($relative in $RelativePaths) {
		$normalized = $relative.Replace('/', '\')
		$candidate = $Destination + '\' + $normalized
		if ($candidate.Length -gt $longestPath.Length) {
			$longestPath = $candidate
			$longestRelative = $normalized
		}
	}
	return [pscustomobject]@{ Path = $longestPath; Relative = $longestRelative; Length = $longestPath.Length }
}

function Get-PlannedOutputRelativePaths([string]$SourceTemplate, [string]$EngineTemplateRoot, [string]$TemplateName, [string]$Name, [string[]]$GeneratorOwnedPaths) {
	# Every relative path the generator plans to write: the copied template tree (projected through
	# the materialize rules when the recipe materializes), the shared content packs, and the files the
	# generator writes itself (recipe payload and lock). Engine build output (Intermediate/, *.obj)
	# is not generated here and is therefore out of scope here; docs/01-start.md warns about it.
	$planned = [System.Collections.Generic.List[string]]::new()
	$sourceRoot = [System.IO.Path]::GetFullPath($SourceTemplate).TrimEnd('\', '/')
	if ($null -ne $Name -and $Name -ne '') {
		$defsPath = Join-Path $SourceTemplate 'Config\TemplateDefs.ini'
		if (-not (Test-Path -LiteralPath $defsPath -PathType Leaf)) { throw "The template has no Config/TemplateDefs.ini to materialize from: $defsPath" }
		$defs = Read-TemplateDefs -Path $defsPath -TemplateName $TemplateName
		foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force) {
			$relative = $file.FullName.Substring($sourceRoot.Length + 1).Replace('\', '/')
			$target = Get-MaterializedTarget -RelativePath $relative -Defs $defs -TemplateName $TemplateName -Name $Name
			if ($null -ne $target) { $planned.Add($target.Target) }
		}
		foreach ($mount in $defs.SharedContentPacks) {
			$packContent = Get-SharedContentPackRoot -EngineTemplateRoot $EngineTemplateRoot -Defs $defs -MountName $mount
			if (-not (Test-Path -LiteralPath $packContent -PathType Container)) { throw "Shared content pack is missing from the installed engine: $packContent" }
			$packRoot = [System.IO.Path]::GetFullPath($packContent).TrimEnd('\', '/')
			foreach ($packFile in Get-ChildItem -LiteralPath $packRoot -Recurse -File -Force) {
				$planned.Add((Join-Path ("Content\" + $mount) $packFile.FullName.Substring($packRoot.Length + 1)))
			}
		}
	} else {
		foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force) {
			$planned.Add($file.FullName.Substring($sourceRoot.Length + 1).Replace('\', '/'))
		}
	}
	foreach ($owned in $GeneratorOwnedPaths) { $planned.Add($owned) }
	return , $planned
}

function Copy-TemplateTreeImpl([string]$SourceTemplate, [string]$Destination, [string]$TemplateName, [string]$Name, [string]$EngineTemplateRoot, [string]$ProjectFileName, [switch]$Materialize) {

# Plugin identity contract: the `.uproject` is what the engine reads, so the lock records every
# plugin entry of the generated project (not only the recipe's required_plugins) and every enabled
# entry's `.uplugin` is resolved on this install before anything is copied. UE 5.8 nests plugins
# one to four directories under Engine/Plugins, so the search walks the category directories first
# and only then scans the whole tree. A version that cannot be read is recorded as the explicit
# value `unknown`; it is never invented.
function Find-PluginDescriptor {
	# Returns the resolved `.uplugin` path for one plugin name, or a Path of $null. `Searched` carries
	# every path that was tried, so a stop can list them instead of saying "missing plugin".
	param(
		[Parameter(Mandatory = $true)][string]$PluginName,
		[Parameter(Mandatory = $true)][string]$EngineRoot,
		[Parameter(Mandatory = $true)][string]$RepositoryRoot,
		[Parameter(Mandatory = $true)][string]$ProjectRoot
	)
	$enginePluginsRoot = Join-Path $EngineRoot 'Engine\Plugins'
	$searched = [System.Collections.Generic.List[string]]::new()
	# The generated project's own Plugins directory wins: it is the copy the opened project loads.
	$direct = @(
		[pscustomobject]@{ Source = 'project'; Path = (Join-Path $ProjectRoot ('Plugins\{0}\{0}.uplugin' -f $PluginName)) },
		[pscustomobject]@{ Source = 'repository'; Path = (Join-Path $RepositoryRoot ('templates\online\{0}\{0}.uplugin' -f $PluginName)) },
		[pscustomobject]@{ Source = 'engine'; Path = (Join-Path $enginePluginsRoot ('{0}\{0}.uplugin' -f $PluginName)) }
	)
	foreach ($candidate in $direct) {
		$searched.Add($candidate.Path)
		if (Test-Path -LiteralPath $candidate.Path -PathType Leaf) {
			return [pscustomobject]@{ Name = $PluginName; Path = [System.IO.Path]::GetFullPath($candidate.Path); Source = $candidate.Source; Searched = $searched.ToArray() }
		}
	}
	if (Test-Path -LiteralPath $enginePluginsRoot -PathType Container) {
		foreach ($category in @(Get-ChildItem -LiteralPath $enginePluginsRoot -Directory -Force)) {
			$categoryPath = Join-Path $category.FullName ('{0}\{0}.uplugin' -f $PluginName)
			$searched.Add($categoryPath)
			if (Test-Path -LiteralPath $categoryPath -PathType Leaf) {
				return [pscustomobject]@{ Name = $PluginName; Path = [System.IO.Path]::GetFullPath($categoryPath); Source = 'engine'; Searched = $searched.ToArray() }
			}
		}
		foreach ($nestedPath in @([System.IO.Directory]::EnumerateFiles($enginePluginsRoot, '*.uplugin', [System.IO.SearchOption]::AllDirectories))) {
			if ([System.IO.Path]::GetFileName($nestedPath) -cne ('{0}.uplugin' -f $PluginName)) { continue }
			$resolvedPath = [System.IO.Path]::GetFullPath($nestedPath)
			$searched.Add($resolvedPath)
			return [pscustomobject]@{ Name = $PluginName; Path = $resolvedPath; Source = 'engine'; Searched = $searched.ToArray() }
		}
	}
	return [pscustomobject]@{ Name = $PluginName; Path = $null; Source = 'unresolved'; Searched = $searched.ToArray() }
}

function Get-PluginRecords {
	# Builds the `plugins` block of the lock from the plugin entries of the generated descriptor.
	# Every entry is recorded with its version, where it came from and whether the project enables
	# it. An enabled entry that resolves to no `.uplugin` stops the run and names every path that
	# was searched, so a project that cannot open is never written with exit 0.
	param(
		[Parameter(Mandatory = $true)][AllowEmptyCollection()]$Plugins,
		[Parameter(Mandatory = $true)][string]$EngineRoot,
		[Parameter(Mandatory = $true)][string]$RepositoryRoot,
		[Parameter(Mandatory = $true)][string]$ProjectRoot
	)
	$problems = [System.Collections.Generic.List[string]]::new()
	$nameSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
	foreach ($entry in @($Plugins | Where-Object { $null -ne $_ })) {
		$pluginName = [string]$entry.Name
		if ([string]::IsNullOrWhiteSpace($pluginName)) {
			$problems.Add('the project descriptor has a Plugins entry without a Name')
			continue
		}
		$null = $nameSet.Add($pluginName)
	}
	[string[]]$orderedNames = @($nameSet)
	[Array]::Sort($orderedNames, [System.StringComparer]::Ordinal)
	$records = [ordered]@{}
	[string[]]$enabledNames = @()
	foreach ($pluginName in $orderedNames) {
		$enabled = @($Plugins | Where-Object { $null -ne $_ -and [string]$_.Name -ceq $pluginName -and $_.Enabled -eq $true }).Count -gt 0
		$resolution = Find-PluginDescriptor -PluginName $pluginName -EngineRoot $EngineRoot -RepositoryRoot $RepositoryRoot -ProjectRoot $ProjectRoot
		$version = 'unknown'
		if (-not [string]::IsNullOrWhiteSpace([string]$resolution.Path)) {
			$pluginJson = Get-Content -Raw -LiteralPath $resolution.Path | ConvertFrom-Json
			if (-not [string]::IsNullOrWhiteSpace([string]$pluginJson.VersionName)) { $version = [string]$pluginJson.VersionName }
			elseif (-not [string]::IsNullOrWhiteSpace([string]$pluginJson.Version)) { $version = [string]$pluginJson.Version }
		} elseif ($enabled) {
			$problems.Add(('enabled plugin "{0}" has no readable .uplugin on this install; searched: {1}' -f $pluginName, (@($resolution.Searched) -join '; ')))
		}
		$records[$pluginName] = [ordered]@{
			version = $version
			source = [string]$resolution.Source
			enabled_in_project = $enabled
		}
		if ($enabled) { $enabledNames += $pluginName }
	}
	if ($problems.Count -gt 0) {
		throw ('Plugin identity check stopped: the generated project would enable plugin(s) that cannot be resolved on this install, so no project was produced. ' + ($problems -join ' | '))
	}
	return [pscustomobject]@{ Records = $records; EnabledNames = $enabledNames }
}

function Get-ProjectPluginEntries {
	# The plugin entries the generated descriptor will carry: the installed template's own entries
	# plus the recipe's required_plugins, which are always enabled. Returns plain objects so the
	# caller can compare and record them before anything is copied.
	param(
		[Parameter(Mandatory = $true)][AllowEmptyCollection()]$TemplatePlugins,
		[Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$RequiredPlugins
	)
	$entries = @($TemplatePlugins | Where-Object { $null -ne $_ })
	foreach ($pluginName in $RequiredPlugins) {
		$existing = $entries | Where-Object { [string]$_.Name -ceq [string]$pluginName } | Select-Object -First 1
		if ($null -eq $existing) {
			$entries += [pscustomobject]@{ Name = [string]$pluginName; Enabled = $true }
		} else {
			$existing.Enabled = $true
		}
	}
	return $entries
}

function Copy-MaterializedTemplate([string]$SourceTemplate, [string]$Destination, [string]$TemplateName, [string]$Name, [string]$EngineTemplateRoot) {
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
	$classRenames = [System.Collections.Generic.List[object]]::new()
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
		$targetPath = Resolve-ContainedPath -Root $Destination -Candidate (Join-Path $Destination $target.Replace('/', '\')) -Label "FolderRenames/ReplacementsInFiles target '$target' for template file '$relative'"
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
	# Blueprints in the template Content were saved against /Script/<TemplateName>. A package redirect
	# only rewrites the /Script package, and source headers that were renamed (Character, GameMode,
	# PlayerController, ...) keep their old class name inside those Blueprints, so the wizard's
	# +ActiveClassRedirects are required in addition -- never instead of -- the package redirect.
	$engineIni = Join-Path $Destination 'Config\DefaultEngine.ini'
	$orderedClassRenames = @($classRenames | Sort-Object -Property OldClassName)
	$classRedirectEntries = @($orderedClassRenames | ForEach-Object { '+ActiveClassRedirects=(OldClassName="{0}",NewClassName="{1}")' -f $_.OldClassName, $_.NewClassName })
	Add-IniSectionEntries -IniPath $engineIni -SectionName '[/Script/Engine.Engine]' -Entries $classRedirectEntries
	return [pscustomobject]@{
		ContentRules     = @($defs.ContentRules)
		AppliedKeys      = @($defs.AppliedKeys)
		IgnoredKeys      = @($defs.IgnoredKeys)
		UnreadableLines  = @($defs.UnreadableLines)
		SharedContentPacks = @($copiedPacks)
		EditDetailLevelPreference = $defs.DetailLevel
		FoldersToIgnore = @($defs.FoldersToIgnore).Count
		FilesToIgnore = @($defs.FilesToIgnore).Count
		DetailLevel = $defs.DetailLevel
		ClassRedirects = @($orderedClassRenames)
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
	# Only directories that actually carry recipe.json are selectable. Listing every directory would
	# advertise support directories such as templates/recipes/common, which has no recipe data and
	# fails with this same message when chosen.
	$availableRecipes = @(Get-ChildItem -LiteralPath $recipeRoot -Directory -Force |
		Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'recipe.json') -PathType Leaf } |
		Select-Object -ExpandProperty Name | Sort-Object)
	$recipeChoices = if ($availableRecipes.Count -gt 0) { $availableRecipes -join ', ' } else { '(none: no directory under templates/recipes/ carries recipe.json)' }
	throw ("Unknown recipe '{0}': templates/recipes/{0}/recipe.json does not exist, so there is no recipe data to synthesize. Add the directory under templates/recipes/ or pick one of: {1}. Nothing was generated." -f $Recipe, $recipeChoices)
}
$recipeData = Read-RecipeData -Path $recipeFile -DirectoryName $Recipe
$recipeSourceDir = Join-Path $recipeRoot $Recipe
# Capture.md is the one delta every recipe promises. Play.md is optional, and its presence is the only
# switch that decides whether a play delta is synthesized: composition never reads a recipe name.
$captureSource = Join-Path $recipeSourceDir 'Capture.md'
if (-not (Test-Path -LiteralPath $captureSource -PathType Leaf)) {
	throw "Recipe '$Recipe' does not ship Capture.md, so its capture delta cannot be synthesized: $captureSource. Nothing was generated."
}
$playSource = Join-Path $recipeSourceDir 'Play.md'
$hasPlayDelta = Test-Path -LiteralPath $playSource -PathType Leaf

# Plugin descriptors and versions are resolved before the exclusive output directory is created, so a
# recipe that declares an unknown or missing plugin stops with no partially generated project.
# Two orders are kept on purpose: the descriptor is written in the recipe's declared order (so an
# existing recipe keeps its generated .uproject byte-for-byte), and the lock records the versions in
# ordinal order (the recorded-order the lock has always used).
[string[]]$pluginNames = @($recipeData.RequiredPlugins)
[string[]]$sortedPluginNames = @($recipeData.RequiredPlugins)
[Array]::Sort($sortedPluginNames, [System.StringComparer]::Ordinal)
$pluginVersions = [ordered]@{}
foreach ($pluginName in $sortedPluginNames) {
	$pluginPath = Get-PluginDescriptorPath -PluginName $pluginName -RepositoryRoot $repoRoot -EngineRootPath $engineRootFull
	if (-not (Test-Path -LiteralPath $pluginPath -PathType Leaf)) {
		throw "Required plugin metadata is missing for '$pluginName': $pluginPath. Nothing was generated."
	}
	$pluginJson = Get-Content -Raw -LiteralPath $pluginPath | ConvertFrom-Json
	$pluginVersion = $null
	foreach ($field in @('VersionName', 'Version')) {
		if ($null -ne $pluginJson.PSObject.Properties[$field] -and -not [string]::IsNullOrWhiteSpace([string]$pluginJson.$field)) {
			$pluginVersion = [string]$pluginJson.$field
			break
		}
	}
	$pluginVersions[$pluginName] = $pluginVersion
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

# Template provenance. A lock that names a repository must name a commit that repository can serve,
# otherwise the recorded template version cannot be reproduced by anyone else. The repository is the
# measured origin (never a constant) and the publication state is a probe result, not a claim.
$templateOrigin = Get-TemplateOriginInfo -RepositoryRoot $repoRoot
$templateRepository = $templateOrigin.Repository
$templateSourceKind = $templateOrigin.Kind
$templateCommitPublished = $null
if (-not $SkipTemplatePublishCheck) {
	if ($null -ne $templateRepository) {
		$templateCommitPublished = Test-TemplateCommitPublished -Repository $templateRepository -Commit $gitCommit -SourceKind $templateSourceKind
	}
	if ($templateCommitPublished -ne $true -and -not $AllowUnpublishedTemplate) {
		$remedy = 'Publish the template commit to the recorded repository, or pass -AllowUnpublishedTemplate to record template_commit_published = false, or -SkipTemplatePublishCheck when the repository cannot be reached from this host.'
		if ($null -eq $templateRepository) {
			throw ("The template checkout has no 'origin' remote ($templateSourceKind), so the lock would name no repository and no retrievable commit. $remedy")
		}
		if ($templateSourceKind -eq 'bundle') {
			throw ("The template checkout was cloned from the bundle {0}, which is an offline hand-off file rather than a repository another party can fetch from, so the lock cannot claim a published template. Clone from the repository instead, or pass -AllowUnpublishedTemplate to record template_commit_published = null as an unverified hand-off. $remedy" -f $templateRepository)
		}
		if ($templateCommitPublished -eq $false) {
			throw ("The template commit {0} is not retrievable from the recorded template repository ({1}): the repository answers 'not our ref', so a lock written now would name a commit nobody else can fetch. $remedy" -f $gitCommit, $templateRepository)
		}
		throw ("Could not determine whether the template commit {0} is retrievable from the recorded template repository ({1}). $remedy" -f $gitCommit, $templateRepository)
	}
}

# `$Data.<Field>` on a missing key yields $null, and `[long]$null` is 0 while `[string]$null` is ''.
# Both would be written to the lock as if the engine had said so, so every field is read only
# after its PSObject property is proven to exist (engine build identity contract, UE-LOCK-001).
function Get-BuildVersionField($Data, [string]$Name) {
	if ($null -eq $Data.PSObject.Properties[$Name]) { return $null }
	return $Data.$Name
}

$buildData = Get-Content -Raw -LiteralPath $engineBuildFile | ConvertFrom-Json
# A missing, empty or non-numeric version field cannot produce a describable EngineAssociation: the
# derived value would be a fragment such as '.8', which the descriptor and the lock would then
# record as fact. Reject before anything is copied.
foreach ($requiredBuildField in @('MajorVersion', 'MinorVersion', 'PatchVersion')) {
	$buildFieldValue = if ($null -ne $buildData.PSObject.Properties[$requiredBuildField]) { [string]$buildData.$requiredBuildField } else { '' }
	if ($buildFieldValue -notmatch '^[0-9]+$') {
		throw "Engine/Build/Build.version does not define a numeric $requiredBuildField, so the project engine association and the lock's engine build identity cannot be recorded: $engineBuildFile"
	}
}
$engineVersion = '{0}.{1}.{2}' -f $buildData.MajorVersion, $buildData.MinorVersion, $buildData.PatchVersion

# The optional build-identity fields stay optional: a mirror or an older installer may omit them.
# Absent means 'unknown' and is recorded as JSON null, never as 0 / ''.
$engineCompatibleChangelist = Get-BuildVersionField $buildData 'CompatibleChangelist'
if ($null -ne $engineCompatibleChangelist) {
	if ([string]$engineCompatibleChangelist -notmatch '^[0-9]+$') {
		throw "Engine/Build/Build.version defines a non-numeric CompatibleChangelist, so the lock's engine build identity cannot be recorded: $engineBuildFile"
	}
	$engineCompatibleChangelist = [long]$engineCompatibleChangelist
}
$engineIsLicenseeVersion = Get-BuildVersionField $buildData 'IsLicenseeVersion'
if ($null -ne $engineIsLicenseeVersion) {
	if ([string]$engineIsLicenseeVersion -notmatch '^(?:[0-9]+|(?i:true)|(?i:false))$') {
		throw "Engine/Build/Build.version defines a non-numeric IsLicenseeVersion, so the lock's engine build identity cannot be recorded: $engineBuildFile"
	}
}
$engineIsPromotedBuild = Get-BuildVersionField $buildData 'IsPromotedBuild'
if ($null -ne $engineIsPromotedBuild) {
	if ([string]$engineIsPromotedBuild -notmatch '^(?:[0-9]+|(?i:true)|(?i:false))$') {
		throw "Engine/Build/Build.version defines a non-numeric IsPromotedBuild, so the lock's engine build identity cannot be recorded: $engineBuildFile"
	}
}
$engineBranchName = Get-BuildVersionField $buildData 'BranchName'
if ($null -ne $engineBranchName) {
	$engineBranchName = [string]$engineBranchName
	if ([string]::IsNullOrWhiteSpace($engineBranchName)) { $engineBranchName = $null }
}
# UE itself does not use the raw Changelist as the build identity, and it does not simply prefer the
# larger number either. Epic's Engine/Source/Runtime/Core/Private/Modules/BuildVersion.cpp:21-24
# (read from the installed 5.8.4 tree, 2026-11-03) defines:
#   int FBuildVersion::GetEffectiveCompatibleChangelist() const
#   { return (Changelist != 0 && CompatibleChangelist != 0) ? CompatibleChangelist : Changelist; }
# The effective value follows that rule, and every raw field the rule consumed is recorded next to
# it, so an install that only differs in CompatibleChangelist never yields the same lock as another.
# `Changelist` stays optional: UE's parser leaves the field at its default (0) when the file omits it,
# but 'the file did not say' is not the same evidence as 'the file said 0', so an absent key makes the
# derived value unknown (null) instead of throwing or silently writing 0.
$engineChangelistRaw = Get-BuildVersionField $buildData 'Changelist'
if ($null -ne $engineChangelistRaw) {
	if ([string]$engineChangelistRaw -notmatch '^[0-9]+$') {
		throw "Engine/Build/Build.version defines a non-numeric Changelist, so the lock's engine build identity cannot be recorded: $engineBuildFile"
	}
	$engineChangelistRaw = [long]$engineChangelistRaw
}
if ($null -eq $engineChangelistRaw) {
	$engineChangelist = $null
	$engineChangelistSource = $null
} else {
	$engineCompatibleChangelistForRule = if ($null -eq $engineCompatibleChangelist) { 0 } else { $engineCompatibleChangelist }
	if ($engineChangelistRaw -ne 0 -and $engineCompatibleChangelistForRule -ne 0) {
		$engineChangelist = [long]$engineCompatibleChangelistForRule
		$engineChangelistSource = 'CompatibleChangelist'
	} else {
		$engineChangelist = [long]$engineChangelistRaw
		$engineChangelistSource = 'Changelist'
	}
}
$templateName = $recipeData.EngineTemplate
$sourceTemplate = Join-Path $engineTemplateRoot $templateName
$templateProjectFile = Join-Path $sourceTemplate ($templateName + '.uproject')
if (-not (Test-Path -LiteralPath $templateProjectFile -PathType Leaf)) {
	throw "The installed engine does not contain the selected official project template: $templateProjectFile"
}
# materialize_project: apply the template's own Config/TemplateDefs.ini rules (as the UE New Project
# wizard does) so the output is <ProjectName>.uproject with renamed module/source, not TP_* names.
$materialize = [bool]$recipeData.MaterializeProject
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

# Plugin identity check, before anything exists on disk: the project descriptor this run will write
# enables the installed template's own plugins plus the recipe's required_plugins, so every one of
# them has to resolve to a real `.uplugin` on this install. Stopping here keeps a run that would emit
# a project nobody can open from leaving an output directory behind, and it is the only place where
# a byte-identical lock for two different engine installs can be refused.
$templatePlugins = @($templateDescriptor.Plugins | Where-Object { $null -ne $_ })
$projectPluginEntries = @(Get-ProjectPluginEntries -TemplatePlugins $templatePlugins -RequiredPlugins @($recipeData.required_plugins))

$destinationName = '{0}_{1}' -f $ProjectName, $RunId
$destinationPath = [System.IO.Path]::GetFullPath((Join-Path $productionRoot $destinationName))
$separator = [System.IO.Path]::DirectorySeparatorChar
$productionPrefix = $productionRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + $separator
if (-not $destinationPath.StartsWith($productionPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
	throw 'The computed output directory escapes Production.'
}
# This is the pre-copy gate: it throws before the exclusive output directory is created, so a run
# that would enable an unresolvable plugin leaves nothing on disk.
$null = Get-PluginRecords -Plugins $projectPluginEntries -EngineRoot $engineRootFull -RepositoryRoot $repoRoot -ProjectRoot $destinationPath


# ---------------------------------------------------------------------------------------------
# Path-length budget. The repository records 260 characters as a real failure it already hit
# (docs/08-online-foundations.md:47), so the generator must not emit a tree nobody measured and
# still call it a success. The check runs before the exclusive mkdir: a rejected run leaves no
# Production/<Name>_<RunId>/ behind.
# ---------------------------------------------------------------------------------------------
[string[]]$generatorOwnedPaths = @('template-lock.json')
foreach ($payloadName in @('SET.md', 'recipe.json', 'Capture.md')) {
	$generatorOwnedPaths += ('Recipe\' + $payloadName)
}
if ($Recipe -eq 'spectator-explore' -or $Recipe -eq 'third-person-game') {
	$generatorOwnedPaths += 'Recipe\Play.md'
}
if ($Recipe -eq 'spectator-explore') { $generatorOwnedPaths += 'docs\08-online-foundations.md' }
$templateSourceName = if ($materialize) { $ProjectName } else { $null }
$plannedPaths = Get-PlannedOutputRelativePaths -SourceTemplate $sourceTemplate -EngineTemplateRoot $engineTemplateRoot -TemplateName $templateName -Name $templateSourceName -GeneratorOwnedPaths $generatorOwnedPaths
if (@($recipeData.required_plugins) -contains 'MulticaOnlineStarter') {
	# The online payload is copied from this repository, not from the engine template, so it is
	# measured separately instead of being folded into the template walk above.
	$pluginSourceRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'templates\online\MulticaOnlineStarter')).TrimEnd('\', '/')
	foreach ($pluginFile in Get-ChildItem -LiteralPath $pluginSourceRoot -Recurse -File -Force) {
		$plannedPaths.Add('Plugins\MulticaOnlineStarter\' + $pluginFile.FullName.Substring($pluginSourceRoot.Length + 1).Replace('\', '/'))
	}
}
$pathBudget = Measure-GeneratedPathBudget -Destination $destinationPath -RelativePaths $plannedPaths
$pathMargin = $MaxPathLength - $pathBudget.Length
if ($pathMargin -lt 0) {
	$overBy = [Math]::Abs($pathMargin)
	$suggestedRoot = [Math]::Max(1, $repoRoot.Length - $overBy)
	throw ('Path length budget stopped generation before anything was written: the longest planned path would be {0} characters ({1}), which is {2} over the {3}-character budget. Nothing was created at {4}. Shorten it by one of: clone the template repository into a shallower directory (this checkout root is {5} characters, and roughly {6} characters or fewer would fit this run: {7}), or use a shorter ProjectName/RunId. Engine build output (Intermediate/, *.obj) is not generated here and is not measured; see docs/01-start.md.' -f $pathBudget.Length, $pathBudget.Relative, $overBy, $MaxPathLength, $destinationPath, $repoRoot.Length, $suggestedRoot, $repoRoot)
}
Write-Output (('Path budget: longest planned path {0} characters, {1} characters of headroom under the {2}-character budget ({3}).' -f $pathBudget.Length, $pathMargin, $MaxPathLength, $pathBudget.Relative))

# Nothing is written under Production/<Name>_<runid>/ directly. The whole set is built in a sibling
# staging directory and published with a single rename, so a run that stops halfway cannot leave a
# partial project that the "existing output stops" rule would then treat as a real one. The staging
# name carries this run's id plus a fresh nonce, so two runs never share a staging directory and
# cleanup can only ever remove the one this run created.
$stagingName = '.stage-{0}-{1}' -f $RunId, [Guid]::NewGuid().ToString('N')
$stagingPath = [System.IO.Path]::GetFullPath((Join-Path $productionRoot $stagingName))
if (-not $stagingPath.StartsWith($productionPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
	throw 'The computed staging directory escapes Production.'
}
# Fail fast with the wording the rename would produce. The rename below stays the authoritative
# exclusivity decision; this check only avoids copying for an output that already exists.
if (Test-Path -LiteralPath $destinationPath) {
	throw "Output already exists; it was not modified: $destinationPath"
}

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
function Get-ExistingOutputDiagnosis([string]$Path) {
	# The refusal of an existing output directory is correct, but one message for every case makes
	# an agent read an ordering error as "this run already produced a project". The start procedure
	# writes preflight and lease to Production/.runs/run_<runid>/, outside the generated project, so a
	# directory that is empty or holds only that run bookkeeping means an earlier step occupied the
	# generated path. Report which case this is and never delete or overwrite anything.
	$names = @()
	try {
		$names = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop | ForEach-Object { $_.Name })
	} catch {
		return 'The existing directory could not be listed, so it was not modified: ' + $_.Exception.Message
	}
	$runBookkeeping = @('LEASE.json', 'Out', 'QA.md', 'preflight.md')
	if ($names.Count -eq 0) {
		return 'This is an ordering error, not an existing project: the directory is empty, so an earlier step created the generated project path itself. Preflight and lease belong in Production/.runs/run_<runid>/, outside the generated project. Nothing was deleted or overwritten.'
	}
	$unknownNames = @($names | Where-Object { $runBookkeeping -notcontains $_ })
	if ($unknownNames.Count -eq 0) {
		return ('This is an ordering error, not an existing project: the directory holds only run bookkeeping ({0}), so an earlier step created the generated project path itself. Preflight and lease belong in Production/.runs/run_<runid>/, outside the generated project. Nothing was deleted or overwritten.' -f ($names -join ', '))
	}
	return ('An existing output is present and was not modified. Existing entries: {0}. If these are this run''s own artifacts, generate under a new -RunId instead of deleting or overwriting them.' -f ($names -join ', '))
}

if (-not [MulticaTemplateDirectory]::CreateDirectory($destinationPath, [IntPtr]::Zero)) {
	$win32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
	if ($win32Error -eq 183) {
		throw "Output already exists; it was not modified: $destinationPath. $(Get-ExistingOutputDiagnosis -Path $destinationPath)"
	}
	throw "Could not exclusively create the output directory (Win32 $win32Error): $destinationPath"

if (-not [MulticaTemplateDirectory]::CreateDirectory($stagingPath, [IntPtr]::Zero)) {
	$win32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
	throw "Could not exclusively create the staging directory (Win32 $win32Error): $stagingPath"
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
try {
	# Both paths go through the same copy implementation. The raw-copy recipes keep the template's
	# project file name and module names, but they still honour the template's own Config/TemplateDefs.ini
	# FoldersToIgnore / FilesToIgnore rules and its SharedContentPacks, because a project that is missing
	# the content the default map references opens with missing assets while still reporting success.
	$copyReport = Copy-TemplateTree -SourceTemplate $sourceTemplate -Destination $stagingPath -TemplateName $templateName -ProjectFileName $projectFileName -Name $ProjectName -EngineTemplateRoot $engineTemplateRoot -Materialize:$materialize

	$projectFile = Join-Path $stagingPath $projectFileName
	if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) {
		throw "The installed template project file was not copied to $projectFileName."
	}
	# The generated project's Config declares the map it will open. If that package is not in the
	# output, the first README step (open the project, press Play) lands on an unresolved map, so the
	# generator must stop instead of printing success. This is a bounded path check over the copied
	# tree, not an asset-registry load.
	[string[]]$declaredMaps = @(Get-DeclaredGameMapPaths -ProjectConfigPath (Join-Path $stagingPath 'Config\DefaultEngine.ini'))
	$missingMaps = [System.Collections.Generic.List[string]]::new()
	foreach ($declaredMap in $declaredMaps) {
		$assetRelative = Convert-GamePackagePathToAssetPath $declaredMap
		if (-not (Test-Path -LiteralPath (Join-Path $stagingPath $assetRelative.Replace('/', '\')) -PathType Leaf)) {
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
	$copiedIdentity = Get-ScaffoldIdentityReport -Descriptor $projectDescriptor -SourceRoot (Join-Path $stagingPath 'Source') -ProjectFileName $projectFileName
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
	foreach ($pluginName in $pluginNames) {
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


	# The copy is now on disk, so the descriptor that was actually written is what the lock has to
	# describe. Its plugin set must be exactly the set the pre-copy check resolved.
	$writtenPlugins = @($projectDescriptor.Plugins | Where-Object { $null -ne $_ })
	$writtenPluginNames = @($writtenPlugins | ForEach-Object { [string]$_.Name })
	[Array]::Sort($writtenPluginNames, [System.StringComparer]::Ordinal)
	$checkedPluginNames = @($projectPluginEntries | ForEach-Object { [string]$_.Name })
	[Array]::Sort($checkedPluginNames, [System.StringComparer]::Ordinal)
	if (($writtenPluginNames -join ',') -cne ($checkedPluginNames -join ',')) {
		throw 'Plugin identity check stopped: the written project descriptor carries a plugin set the pre-copy check did not verify, so the lock was not written.'
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
		schema_version = 4
		template_repository = $templateRepository
		template_commit = $gitCommit
		template_source_kind = $templateSourceKind
		template_commit_published = $templateCommitPublished
		template_worktree_dirty = $templateDirty
		engine_template = $templateName
		engine_version = $engineVersion
		engine_changelist = $engineChangelist
		engine_changelist_source = $engineChangelistSource
		engine_changelist_raw = $engineChangelistRaw
		engine_compatible_changelist = $engineCompatibleChangelist
		engine_is_licensee_version = $engineIsLicenseeVersion
		engine_is_promoted_build = $engineIsPromotedBuild
		engine_branch_name = $engineBranchName
		identity = [ordered]@{
			project_file = $projectFileName
			project_modules = @($moduleNames)
			engine_association = $engineAssociationValue
		}
		recipe = $recipeData.Recipe
		purpose = $recipeData.Purpose
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
		online_session_identifier = if ($pluginNames -contains 'MulticaOnlineStarter') { 'eiei114.ue5-agent-template:{0}' -f $ProjectName } else { $null }
		project_differences = $projectDifferences
	}
	$lockJson = ConvertTo-Json -InputObject $lock -Depth 12

	$recipeOutput = Join-Path $stagingPath 'Recipe'
	[System.IO.Directory]::CreateDirectory($recipeOutput) | Out-Null
	Copy-Item -LiteralPath (Join-Path $recipeRoot 'common\SET.md') -Destination (Join-Path $recipeOutput 'SET.md')
	Copy-Item -LiteralPath $recipeFile -Destination (Join-Path $recipeOutput 'recipe.json')
	Copy-Item -LiteralPath $captureSource -Destination (Join-Path $recipeOutput 'Capture.md')
	if ($hasPlayDelta) {
		Copy-Item -LiteralPath $playSource -Destination (Join-Path $recipeOutput 'Play.md')
	}
	if ($pluginNames -contains 'MulticaOnlineStarter') {
		$onlineGuideTarget = Join-Path $destinationPath 'docs'
		[System.IO.Directory]::CreateDirectory($onlineGuideTarget) | Out-Null
		Copy-Item -LiteralPath (Join-Path $repoRoot 'docs\08-online-foundations.md') -Destination (Join-Path $onlineGuideTarget '08-online-foundations.md')
		$onlinePluginTarget = Join-Path $stagingPath 'Plugins\MulticaOnlineStarter'
		[System.IO.Directory]::CreateDirectory($onlinePluginTarget) | Out-Null
		Get-ChildItem -LiteralPath (Join-Path $repoRoot 'templates\online\MulticaOnlineStarter') -Force | ForEach-Object {
			Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $onlinePluginTarget $_.Name) -Recurse
		}
		Set-OnlineSessionProjectIdentifier `
			-ProjectConfigPath (Join-Path $stagingPath 'Config\DefaultEngine.ini') `
			-Identifier ('eiei114.ue5-agent-template:{0}' -f $ProjectName)
	}

	# Every copy that can place a `.uplugin` under the project is done, so the records are built with
	# the output directory as the project root: a bundled plugin then resolves to the copy the opened
	# project loads, not to the repository source. A plugin that is enabled and still unresolved here
	# stops the run before the lock is written.
	$pluginRecords = (Get-PluginRecords -Plugins $writtenPlugins -EngineRoot $engineRootFull -RepositoryRoot $repoRoot -ProjectRoot $destinationPath).Records
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
		recipe = [string]$recipeData.recipe
		purpose = [string]$recipeData.purpose
		plugins = $pluginRecords
		online_session_identifier = if (@($recipeData.required_plugins) -contains 'MulticaOnlineStarter') { 'eiei114.ue5-agent-template:{0}' -f $ProjectName } else { $null }
		project_differences = $projectDifferences
	}
	$lockJson = ConvertTo-Json -InputObject $lock -Depth 12
	$lockPath = Join-Path $destinationPath 'template-lock.json'

	$lockPath = Join-Path $stagingPath 'template-lock.json'
	# template-lock.json is written last and is the completion marker: a published directory that
	# lacks it is not a finished project, whatever else it contains.
	[System.IO.File]::WriteAllText($lockPath, $lockJson + [Environment]::NewLine, $utf8NoBom)

	if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) {
		throw "The installed template project file was not copied to $projectFileName."
	}
	$writtenDescriptor = Get-Content -Raw -LiteralPath $projectFile | ConvertFrom-Json
	if ([string]$writtenDescriptor.EngineAssociation -ne $engineAssociationValue) {
		throw "Project identity check stopped: $projectFileName was written without the expected EngineAssociation '$engineAssociationValue'."
	}
	Write-Output "Created $destinationName from the installed $templateName template ($projectFileName, EngineAssociation '$engineAssociationValue', UE $engineVersion, recipe $($recipeData.Recipe), purpose $($recipeData.Purpose))."

	$provenanceSummary = if ($null -eq $templateRepository) { "template source $templateSourceKind (no repository recorded)" } else { "template source $templateSourceKind $templateRepository" }
	$publishedSummary = if ($templateCommitPublished -eq $true) { 'commit published' } elseif ($templateCommitPublished -eq $false) { 'commit NOT retrievable from that repository (template_commit_published = false)' } else { 'publication not verified (template_commit_published = null)' }
	Write-Output "Created $destinationName from the installed $templateName template ($projectFileName, EngineAssociation '$engineAssociationValue', UE $engineVersion, recipe $Recipe; $provenanceSummary; $publishedSummary)."

	if ($classRedirects.Count -gt 0) {
		Write-Output ('Class redirects: ' + (@($classRedirects | ForEach-Object { '{0} -> {1}' -f $_.OldClassName, $_.NewClassName }) -join ', '))
	} elseif ($materialize) {
		Write-Output 'Class redirects: none (no copied reflected header was renamed)'
	}

	if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
		throw "The completion marker was not written, so the staged project is incomplete: $lockPath"
	}

	# Publish: a single rename of the fully built staging directory. Directory.Move refuses an
	# existing target, so this is both the atomic publication and the final exclusivity decision.
	try {
		[System.IO.Directory]::Move($stagingPath, $destinationPath)
	} catch {
		if (Test-Path -LiteralPath $destinationPath) {
			throw "Output already exists; it was not modified: $destinationPath"
		}
		throw "The staged project could not be published and $destinationPath was not created: $($_.Exception.Message)"
	}
	$stagingPath = $null
	Write-Output "Created $destinationName from the installed $templateName template ($projectFileName, EngineAssociation '$engineAssociationValue', UE $engineVersion, recipe $Recipe)."
} catch {
	# Only this run's staging directory may be removed. The published path and any other run's
	# output are never touched: a failed run must not delete somebody else's project.
	$generationError = $_
	$cleanupNote = ''
	if ($null -ne $stagingPath -and (Test-Path -LiteralPath $stagingPath)) {
		try {
			[System.IO.Directory]::Delete($stagingPath, $true)
			$cleanupNote = " Its own staging directory was removed: $stagingPath."
		} catch {
			$cleanupNote = " Warning: its own staging directory could not be removed and remains incomplete: $stagingPath ($($_.Exception.Message))."
		}
	}
	throw "Scaffold generation stopped. Nothing was published, so no output directory exists at $destinationPath.$cleanupNote $($generationError.Exception.Message)"
}
