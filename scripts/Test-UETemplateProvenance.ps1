[CmdletBinding()]
param(
	# The default is resolved in the body: Windows PowerShell 5.1 does not populate $PSScriptRoot
	# inside a param() default expression, so it is empty there.
	[string]$RepoRoot,
	[string]$InventoryPath = 'docs/PROVENANCE.inventory.json'
)

# docs/PROVENANCE.md is the repository's declared source of truth for what is shipped and what is
# not. Prose cannot be checked by keyword matching: a corrected sentence such as "UE本体は同梱しない"
# would be a false positive, and a stale sentence such as "scriptは同梱しない" reads exactly like a
# correct one. The machine-checkable copy of those claims therefore lives in
# docs/PROVENANCE.inventory.json, and this guard compares it with the tracked tree.
#
# Rules
#   R1  every not_bundled pattern matches no tracked path   (a false "not shipped" claim)
#   R2  every bundled pattern matches a tracked path        (a dangling "shipped" claim)
#   R3  every tracked top-level area is classified          (a new layer added without provenance)
#   R4  every relative markdown link in the source document resolves to a tracked path
#
# Output is one line per finding, `FAIL: <rule>: <detail>`. exit 0 = all rules passed, exit 1 = at
# least one failed, exit 2 = the guard itself could not run (bad inventory, git failure). The guard
# reads only; it never writes to the checkout.

$ErrorActionPreference = 'Stop'
$failures = New-Object 'System.Collections.Generic.List[string]'
$guardError = $false

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
	$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}

function Add-Failure([string]$Rule, [string]$Detail) {
	$script:failures.Add(('FAIL: {0}: {1}' -f $Rule, $Detail))
}

function ConvertTo-RepoPattern([string]$Pattern) {
	$p = $Pattern.Trim().Replace('\', '/')
	while ($p.StartsWith('./')) { $p = $p.Substring(2) }
	return $p.TrimStart('/')
}

function Test-RepoPatternMatch([string]$Pattern, [string]$Path) {
	# git records paths with '/'. The comparison is case-insensitive because a Windows checkout
	# cannot distinguish case (git's core.ignorecase is on for this repository's workflow).
	return $Path -ilike $Pattern
}

function Get-TopLevelArea([string]$Pattern) {
	# Only a directory (first segment, no wildcard) or a repository-root file name (no separator,
	# no wildcard) names an area. A bare suffix such as `*.uasset` names a file shape and must not
	# be treated as classifying an area.
	if ($Pattern.IndexOf('/') -ge 0) {
		$head = $Pattern.Split('/')[0]
		if ($head.IndexOfAny([char[]]@('*', '?', '[')) -ge 0) { return '' }
		return $head
	}
	if ($Pattern.IndexOfAny([char[]]@('*', '?', '[')) -ge 0) { return '' }
	return $Pattern
}

function Get-TrackedFiles([string]$Root) {
	# `git ls-files -z` keeps a path containing a space, tab or newline intact; splitting the raw
	# stdout on NUL also keeps such a path out of the line-oriented comparison.
	$rootForGit = $Root
	while ($rootForGit.Length -gt 1 -and ($rootForGit.EndsWith('\') -or $rootForGit.EndsWith('/'))) {
		$rootForGit = $rootForGit.Substring(0, $rootForGit.Length - 1)
	}
	$startInfo = New-Object System.Diagnostics.ProcessStartInfo
	$startInfo.FileName = 'git'
	$startInfo.UseShellExecute = $false
	$startInfo.RedirectStandardOutput = $true
	$startInfo.RedirectStandardError = $true
	$startInfo.CreateNoWindow = $true
	if ($startInfo.PSObject.Properties['ArgumentList']) {
		# Preferred: no manual quoting, so a path containing a quote or a trailing separator is
		# passed verbatim instead of being re-split by the Windows command-line parser.
		$startInfo.ArgumentList.Add('-C')
		$startInfo.ArgumentList.Add($rootForGit)
		$startInfo.ArgumentList.Add('ls-files')
		$startInfo.ArgumentList.Add('-z')
	} else {
		if ($rootForGit.IndexOf('"') -ge 0) {
			throw 'the repository root contains a double quote, so the git argument cannot be quoted unambiguously'
		}
		$startInfo.Arguments = '-C "' + $rootForGit + '" ls-files -z'
	}
	$process = [System.Diagnostics.Process]::Start($startInfo)
	$raw = $process.StandardOutput.ReadToEnd()
	$rawError = $process.StandardError.ReadToEnd()
	$process.WaitForExit()
	$code = $process.ExitCode
	$process.Dispose()
	if ($code -ne 0) {
		throw ('git ls-files -z exited {0}: {1}' -f $code, $rawError.Trim())
	}
	$paths = @($raw.Split([char]0) | Where-Object { $_.Length -gt 0 })
	if ($paths.Count -eq 0) { throw ('git reported no tracked files in ' + $Root) }
	return $paths
}

function Resolve-RepoRelative([string]$BaseDirectory, [string]$Target) {
	$full = $Target
	if (-not [System.IO.Path]::IsPathRooted($full)) {
		$full = Join-Path $BaseDirectory $Target
	}
	$full = [System.IO.Path]::GetFullPath($full)
	$rootFull = [System.IO.Path]::GetFullPath((Join-Path $script:repoRootFull ''))
	if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
		return $null
	}
	return $full.Substring($rootFull.Length).Replace('\', '/')
}

try {
	$script:repoRootFull = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot ''))

	$inventoryFullPath = $InventoryPath
	if (-not [System.IO.Path]::IsPathRooted($inventoryFullPath)) {
		$inventoryFullPath = Join-Path $script:repoRootFull $InventoryPath
	}

	$tracked = Get-TrackedFiles $script:repoRootFull

	if (-not (Test-Path -LiteralPath $inventoryFullPath -PathType Leaf)) {
		Add-Failure 'inventory' ('the inventory file does not exist: ' + $inventoryFullPath)
		$guardError = $true
		throw 'stop'
	}

	$inventoryRel = Resolve-RepoRelative $script:repoRootFull $inventoryFullPath
	if ($null -eq $inventoryRel) {
		Add-Failure 'inventory' ('the inventory file is outside the repository root: ' + $inventoryFullPath)
		$guardError = $true
		throw 'stop'
	}

	$inventory = $null
	try {
		$inventory = (Get-Content -LiteralPath $inventoryFullPath -Raw -Encoding UTF8) | ConvertFrom-Json
	} catch {
		Add-Failure 'inventory' ('the inventory is not valid JSON: ' + $_.Exception.Message)
		$guardError = $true
		throw 'stop'
	}

	$bundled = @()
	$notBundled = @()
	foreach ($field in @('bundled', 'not_bundled')) {
		$value = $inventory.$field
		if ($null -eq $value -or -not ($value -is [System.Array]) -or $value.Count -eq 0) {
			Add-Failure 'inventory' ('the inventory field ' + $field + ' is missing or empty')
			$guardError = $true
			throw 'stop'
		}
		$patterns = @()
		foreach ($item in $value) {
			if (-not ($item -is [string]) -or [string]::IsNullOrWhiteSpace($item)) {
				Add-Failure 'inventory' ('the inventory field ' + $field + ' contains a non-string or empty entry')
				$guardError = $true
				throw 'stop'
			}
			$normalized = ConvertTo-RepoPattern $item
			if ([string]::IsNullOrWhiteSpace($normalized)) {
				Add-Failure 'inventory' ('the inventory field ' + $field + ' contains an empty pattern')
				$guardError = $true
				throw 'stop'
			}
			$patterns += $normalized
		}
		if ($field -eq 'bundled') { $bundled = $patterns } else { $notBundled = $patterns }
	}

	# The inventory is the machine copy of the claims, so it is itself part of the delivered tree.
	if (@($tracked | Where-Object { $_ -ieq $inventoryRel }).Count -eq 0) {
		Add-Failure 'inventory' ('the inventory file is not tracked by git: ' + $inventoryRel)
	}

	$sourceDocument = [string]$inventory.source_document
	if ([string]::IsNullOrWhiteSpace($sourceDocument)) {
		Add-Failure 'inventory' 'the inventory does not name its source_document'
		$guardError = $true
		throw 'stop'
	}
	$sourceRel = ConvertTo-RepoPattern $sourceDocument
	if (@($tracked | Where-Object { $_ -ieq $sourceRel }).Count -eq 0) {
		Add-Failure 'inventory' ('the declared source_document is not tracked by git: ' + $sourceRel)
		$guardError = $true
		throw 'stop'
	}

	# R1
	foreach ($pattern in $notBundled) {
		foreach ($path in $tracked) {
			if (Test-RepoPatternMatch $pattern $path) {
				Add-Failure 'R1' ('not_bundled pattern ''' + $pattern + ''' matches tracked path ''' + $path + '''')
			}
		}
	}

	# R2
	foreach ($pattern in $bundled) {
		if (@($tracked | Where-Object { Test-RepoPatternMatch $pattern $_ }).Count -eq 0) {
			Add-Failure 'R2' ('bundled pattern ''' + $pattern + ''' matches no tracked path')
		}
	}

	# R3
	$classified = New-Object 'System.Collections.Generic.List[string]'
	foreach ($pattern in ($bundled + $notBundled)) {
		$area = Get-TopLevelArea $pattern
		if ($area.Length -gt 0 -and -not ($classified -contains $area)) { $classified.Add($area) }
	}
	$unclassified = New-Object 'System.Collections.Generic.List[string]'
	foreach ($path in $tracked) {
		$area = $path
		$slash = $path.IndexOf('/')
		if ($slash -ge 0) { $area = $path.Substring(0, $slash) }
		$known = $false
		foreach ($candidate in $classified) {
			if ($candidate -ieq $area) { $known = $true; break }
		}
		if (-not $known -and -not ($unclassified -contains $area)) { $unclassified.Add($area) }
	}
	foreach ($area in $unclassified) {
		Add-Failure 'R3' ('tracked top-level area ''' + $area + ''' is classified by neither bundled nor not_bundled')
	}

	# R4
	$documentFullPath = Join-Path $script:repoRootFull $sourceRel
	$documentDirectory = Split-Path -Parent $documentFullPath
	$documentText = [System.IO.File]::ReadAllText($documentFullPath)
	foreach ($match in [regex]::Matches($documentText, '\]\(([^)\s]+)')) {
		$target = $match.Groups[1].Value
		if ($target -match '^(?i)(https?|mailto):') { continue }
		if ($target.StartsWith('#')) { continue }
		$target = $target.Split('#')[0].Split('?')[0]
		if ([string]::IsNullOrWhiteSpace($target)) { continue }
		$resolvedRel = $null
		try {
			$resolvedRel = Resolve-RepoRelative $documentDirectory $target
		} catch {
			$resolvedRel = $null
		}
		if ($null -eq $resolvedRel) {
			Add-Failure 'R4' ('the document link ''' + $target + ''' resolves outside the repository, where git tracks nothing')
			continue
		}
		if (@($tracked | Where-Object { $_ -ieq $resolvedRel }).Count -eq 0) {
			Add-Failure 'R4' ('the document link ''' + $target + ''' resolves to ''' + $resolvedRel + ''', which git does not track')
		}
	}

	if ($failures.Count -eq 0) {
		Write-Output ('PASS: R1 {0} not_bundled pattern(s) match no tracked path' -f $notBundled.Count)
		Write-Output ('PASS: R2 {0} bundled pattern(s) resolve to tracked path(s)' -f $bundled.Count)
		Write-Output ('PASS: R3 {0} tracked top-level area(s) classified' -f $classified.Count)
		Write-Output ('PASS: R4 every relative markdown link in {0} resolves to a tracked path' -f $sourceRel)
	}
} catch {
	if ($_.Exception.Message -ne 'stop') {
		Add-Failure 'guard' $_.Exception.Message
		$guardError = $true
	}
}

foreach ($line in $failures) { Write-Output $line }
if ($failures.Count -gt 0) {
	# 2 keeps "the guard is broken" distinguishable from "the tree violates a rule".
	if ($guardError) { exit 2 }
	exit 1
}
exit 0
