[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)]
	[string]$Target
)

# Reads one delivered work's Content/ and CREDITS.md and decides whether the credits
# record explains the assets that are actually shipped.
#
# AGENTS.md places CREDITS.md under Out/run_<runid>/ while Content/ stays one level
# above, so a single target can see only one of the two. Both places are resolved
# here and the verdict comes from the same pair, which keeps "audit the delivery dir"
# and "audit the project root" from disagreeing (the former used to see 0 assets and
# PASS while the work shipped hundreds).
#
# The script is intentionally ASCII-only: Windows PowerShell 5.1 reads a BOM-less
# script as ANSI, so non-ASCII literals in the file would be mangled before parsing.
# The CREDITS.md header therefore carries ASCII tokens (origin / bundle) that this
# script matches instead of the Japanese column labels.

$ErrorActionPreference = 'Stop'

function Get-AssetGroupReport([string]$ContentRoot) {
	# One entry per top-level Content directory that holds .uasset/.umap files.
	# Assets placed directly in Content/ are reported as '(content-root)'.
	$groups = [ordered]@{}
	if (-not (Test-Path -LiteralPath $ContentRoot -PathType Container)) {
		return [pscustomobject]@{ Exists = $false; Groups = @(); Total = 0 }
	}
	foreach ($file in @(Get-ChildItem -LiteralPath $ContentRoot -Recurse -File -Force)) {
		$extension = [System.IO.Path]::GetExtension($file.Name).ToLowerInvariant()
		if ($extension -ne '.uasset' -and $extension -ne '.umap') { continue }
		$relative = $file.FullName.Substring($ContentRoot.Length).TrimStart('\', '/')
		$separatorIndex = $relative.IndexOfAny([char[]]@('\', '/'))
		$groupName = if ($separatorIndex -lt 0) { '(content-root)' } else { $relative.Substring(0, $separatorIndex) }
		if (-not $groups.Contains($groupName)) { $groups[$groupName] = 0 }
		$groups[$groupName] = $groups[$groupName] + 1
	}
	$entries = @()
	foreach ($name in $groups.Keys) {
		$entries += [pscustomobject]@{ Name = $name; Assets = $groups[$name] }
	}
	$total = 0
	foreach ($entry in $entries) { $total = $total + $entry.Assets }
	return [pscustomobject]@{ Exists = $true; Groups = $entries; Total = $total }
}

function Read-CreditsRows([string]$Path) {
	# Parses the CREDITS.md data table. A legacy record has no origin column and is read
	# as unverified rows instead of being rejected, so an existing work fails for its
	# missing origin rather than for an unrecognized header.
	$lines = [System.IO.File]::ReadAllLines($Path)
	$originIndex = -1
	$bundleIndex = -1
	$hasHeader = $false
	$inFence = $false
	$rows = @()
	foreach ($line in $lines) {
		$trimmed = $line.Trim()
		# A fenced block is documentation, not a record: CREDITS.md shows an example table inside
		# one, and that example must not be read as the work's own credits.
		if ($trimmed.StartsWith('```')) { $inFence = -not $inFence; continue }
		if ($inFence) { continue }
		if (-not $trimmed.StartsWith('|')) { continue }
		if ($trimmed -match '^\|[\s|:-]*-[\s|:-]*\|?$') { continue }
		$cells = @($trimmed.Trim('|').Split('|') | ForEach-Object { $_.Trim() })
		if (-not $hasHeader) {
			for ($i = 0; $i -lt $cells.Count; $i++) {
				if ($originIndex -lt 0 -and $cells[$i] -match '(?i)\borigin\b') { $originIndex = $i }
				if ($bundleIndex -lt 0 -and $cells[$i] -match '(?i)\bbundle\b') { $bundleIndex = $i }
			}
			$hasHeader = $true
			continue
		}
		$origin = if ($originIndex -ge 0 -and $originIndex -lt $cells.Count) { $cells[$originIndex] } else { '' }
		$bundle = if ($bundleIndex -ge 0 -and $bundleIndex -lt $cells.Count) { $cells[$bundleIndex] } else { '' }
		$rows += [pscustomobject]@{
			Text = ($cells -join ' | ')
			Origin = $origin
			Bundle = $bundle
			DeclaresOrigin = $origin -in @('engine-template', 'shared-content-pack', 'third-party', 'original')
		}
	}
	return [pscustomobject]@{ Rows = $rows; HasOriginColumn = ($originIndex -ge 0) }
}

function Resolve-AuditTargets([string]$TargetPath) {
	# Content/ and CREDITS.md are placed one directory apart by AGENTS.md, and a work can be
	# pointed at from either side. Every candidate found in the target and in its parent is
	# collected; more than one of either is ambiguous input, not a pass.
	$targetFull = [System.IO.Path]::GetFullPath($TargetPath)
	if (-not (Test-Path -LiteralPath $targetFull -PathType Container)) {
		return $null
	}
	# The delivery directory (Out/run_<runid>/) is one level below the project root that holds
	# Content/, so both sides of that gap are searched: the target itself, its parent (Out/), and
	# its grandparent (the project root).
	$ancestors = @($targetFull)
	$walk = $targetFull
	for ($level = 0; $level -lt 2; $level++) {
		$parent = Split-Path -Parent $walk
		if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $walk) { break }
		$ancestors += $parent
		$walk = $parent
	}
	$parentFull = if ($ancestors.Count -gt 1) { $ancestors[1] } else { Split-Path -Parent $targetFull }
	$contentCandidates = @()
	foreach ($ancestor in $ancestors) {
		$candidate = Join-Path $ancestor 'Content'
		if (Test-Path -LiteralPath $candidate -PathType Container) { $contentCandidates += $candidate }
		$outRoot = Join-Path $ancestor 'Out'
		if (Test-Path -LiteralPath $outRoot -PathType Container) {
			foreach ($runDir in @(Get-ChildItem -LiteralPath $outRoot -Directory -Force)) {
				$runContent = Join-Path $runDir.FullName 'Content'
				if (Test-Path -LiteralPath $runContent -PathType Container) { $contentCandidates += $runContent }
			}
		}
	}
	$creditsCandidates = @()
	foreach ($ancestor in $ancestors) {
		$directCredits = Join-Path $ancestor 'CREDITS.md'
		if (Test-Path -LiteralPath $directCredits -PathType Leaf) { $creditsCandidates += $directCredits }
		$outRoot = Join-Path $ancestor 'Out'
		if (Test-Path -LiteralPath $outRoot -PathType Container) {
			foreach ($runDir in @(Get-ChildItem -LiteralPath $outRoot -Directory -Force)) {
				$runCredits = Join-Path $runDir.FullName 'CREDITS.md'
				if (Test-Path -LiteralPath $runCredits -PathType Leaf) { $creditsCandidates += $runCredits }
			}
		}
	}
	$creditsCandidates = @($creditsCandidates | Select-Object -Unique)
	$contentCandidates = @($contentCandidates | Select-Object -Unique)
	return [pscustomobject]@{
		Target = $targetFull
		Content = $contentCandidates
		Credits = $creditsCandidates
	}
}

$targetInfo = Resolve-AuditTargets -TargetPath $Target
if ($null -eq $targetInfo) {
	Write-Output ("FAIL: the audit target is not an existing directory: {0}" -f $Target)
	exit 2
}
if ($targetInfo.Content.Count -gt 1) {
	Write-Output ("FAIL: more than one Content/ is reachable from the audit target: {0}" -f ($targetInfo.Content -join ', '))
	exit 2
}
if ($targetInfo.Credits.Count -gt 1) {
	Write-Output ("FAIL: more than one CREDITS.md is reachable from the audit target: {0}" -f ($targetInfo.Credits -join ', '))
	exit 2
}

$creditsPath = if ($targetInfo.Credits.Count -eq 1) { $targetInfo.Credits[0] } else { $null }
$contentPath = if ($targetInfo.Content.Count -eq 1) { $targetInfo.Content[0] } else { $null }
if ($null -eq $creditsPath) {
	Write-Output ("FAIL: CREDITS.md not found for the audit target (looked in the target and its Out/run_*/ runs): {0}" -f $targetInfo.Target)
	exit 2
}
if ($null -eq $contentPath) {
	Write-Output ("NOTE: no Content/ directory is reachable from the audit target; only the credits rows are checked: {0}" -f $targetInfo.Target)
}

$credits = Read-CreditsRows -Path $creditsPath
$assetReport = if ($null -eq $contentPath) {
	[pscustomobject]@{ Exists = $false; Groups = @(); Total = 0 }
} else {
	Get-AssetGroupReport -ContentRoot $contentPath
}

$failures = @()
if ($assetReport.Total -gt 0 -and @($credits.Rows | Where-Object { $_.DeclaresOrigin }).Count -eq 0) {
	$failures += ('CREDITS.md states no origin for any of the {0} asset(s) shipped in Content/ (not one row says engine-template / shared-content-pack / third-party / original)' -f $assetReport.Total)
	Write-Output ("FAIL: {0}" -f $failures[$failures.Count - 1])
}
foreach ($group in $assetReport.Groups) {
	$matched = @($credits.Rows | Where-Object { $_.DeclaresOrigin -and $_.Text.Contains($group.Name) })
	if ($matched.Count -eq 0) {
		$failures += ('Content group "{0}" ({1} asset(s)) is not named by any CREDITS.md row that states its origin' -f $group.Name, $group.Assets)
		Write-Output ("FAIL: {0}" -f $failures[$failures.Count - 1])
	}
}

Write-Output ("assets total={0} groups={1} credits_rows={2} stated_origin_rows={3}" -f $assetReport.Total, @($assetReport.Groups).Count, @($credits.Rows).Count, @($credits.Rows | Where-Object { $_.DeclaresOrigin }).Count)
foreach ($group in $assetReport.Groups) { Write-Output ("asset group: {0} ({1})" -f $group.Name, $group.Assets) }
Write-Output ("credits: {0}" -f $creditsPath)
if ($null -ne $contentPath) { Write-Output ("content: {0}" -f $contentPath) }

if ($failures.Count -gt 0) { exit 1 }
Write-Output 'PASS: every shipped asset group is named by a CREDITS.md row that states its origin'
exit 0
