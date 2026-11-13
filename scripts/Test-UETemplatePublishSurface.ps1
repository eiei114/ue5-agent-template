[CmdletBinding()]
param(
	# Worktree to audit. Defaults to the repository that contains this script.
	[Parameter(Position = 0)]
	[string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
	$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
} else {
	$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
}

# ---------------------------------------------------------------------------
# Why this file, and not `git status` / `.gitignore`, is the source of truth
#
# 1. `git status --porcelain` is clean for a forbidden file that is already
#    committed. It cannot see the published surface at all.
# 2. Comparing `git check-ignore` against the tracked list reads "not ignored"
#    as "deliberately placed document", so archives, bundles and executables
#    that were force-added pass.
# 3. `.gitignore` never stops a *tracked* path. git's own documentation says so
#    (gitignore: "The purpose of gitignore files is to ensure that certain
#    files not tracked by Git remain untracked. To stop tracking a file that is
#    currently tracked, use `git rm --cached`").
#
# So the audit reads the **index** (`git ls-files`) and applies path-shape
# rules it owns itself, case-insensitively, without consulting `.gitignore`.
#
# `git ls-files -ci --exclude-standard` (tracked AND matching an exclude
# pattern) runs as a second, independent signal. That signal is
# configuration-dependent: with `core.ignorecase=false` (a Linux runner) a
# tracked `OUT/x.txt` does not match the `.gitignore` line `Out/`, so the same
# repository yields a different answer on a different host. Verdicts therefore
# never rest on it - the shape rules decide - and the cross-check is reported
# under its own category so the two detection paths cannot be confused.
#
# Paths are read with `-z` (NUL-terminated). `git ls-files` without `-z`
# splits a path that contains a line feed into two records, so the audit would
# inspect fragments instead of the real file name.
# ---------------------------------------------------------------------------

$script:Findings = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:SeeFindings = New-Object 'System.Collections.Generic.HashSet[string]'
$script:SeeWarnings = New-Object 'System.Collections.Generic.HashSet[string]'
$script:TrackedCount = 0

function ConvertTo-ReportPath([string]$Path) {
	# A record can carry a line feed or CR; keep it on one line and make the
	# escape visible so the reader knows it is part of the file name.
	$text = $Path.Replace("`r", '\r')
	$text = $text.Replace("`n", '\n')
	return $text
}

function Add-Finding([string]$Category, [string]$Path) {
	$text = ConvertTo-ReportPath $Path
	$key = $Category + '|' + $text
	if ($script:SeeFindings.Add($key)) {
		$script:Findings.Add(('FAIL: {0}: {1}' -f $Category, $text))
	}
}

function Add-Warning([string]$Category, [string]$Path) {
	$text = ConvertTo-ReportPath $Path
	$key = $Category + '|' + $text
	if ($script:SeeWarnings.Add($key)) {
		$script:Warnings.Add(('WARN: {0}: {1}' -f $Category, $text))
	}
}

function Complete-Audit([int]$Code) {
	foreach ($line in $script:Findings) { Write-Output $line }
	foreach ($line in $script:Warnings) { Write-Output $line }
	Write-Output ('SUMMARY: tracked={0} fail={1} warn={2}' -f $script:TrackedCount, $script:Findings.Count, $script:Warnings.Count)
	exit $Code
}

# ---------------------------------------------------------------- git plumbing

function Invoke-GitNul([string[]]$GitArguments) {
	$psi = New-Object System.Diagnostics.ProcessStartInfo
	$psi.FileName = 'git'
	$psi.Arguments = (@('-C', ('"' + $RepoRoot + '"')) + $GitArguments) -join ' '
	$psi.RedirectStandardOutput = $true
	$psi.RedirectStandardError = $true
	$psi.UseShellExecute = $false
	$psi.CreateNoWindow = $true
	$psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
	$psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
	$process = [System.Diagnostics.Process]::Start($psi)
	$stdout = $process.StandardOutput.ReadToEnd()
	$stderr = $process.StandardError.ReadToEnd()
	$process.WaitForExit()
	$code = $process.ExitCode
	$process.Dispose()
	$records = @()
	if ($stdout.Length -gt 0) {
		$records = @($stdout -split ([string][char]0) | Where-Object { $_ -ne '' })
	}
	return @{ ExitCode = $code; Records = $records; StdErr = $stderr.Trim() }
}

function Invoke-GitText([string[]]$GitArguments) {
	$arguments = @('-C', $RepoRoot) + $GitArguments
	$output = @(& git @arguments 2>&1)
	return @{ ExitCode = $LASTEXITCODE; Lines = @($output | ForEach-Object { [string]$_ }) }
}

# ------------------------------------------------------------- path-shape rules
# Case-insensitive on purpose: this host has core.ignorecase=true and a Linux
# runner does not, and the same committed file must produce the same verdict on
# both. `.gitignore` is never consulted here.

$script:ShapeRules = @(
	@{
		Category = 'generation-output'
		Pattern = '^(?:Production|Out|Art|Saved|Binaries|Intermediate|DerivedDataCache)(?:/|$)'
	},
	@{
		Category = 'distribution-binary'
		Pattern = '(?:\.(?:bundle|7z|rar|tar|gz|tgz|bz2|xz|exe|dll|pdb|lib|so|dylib|uasset|umap|pak|utoc|ucas|mp4|mov|wav|mp3|fbx|psd))$'
	},
	@{
		Category = 'credential'
		Pattern = '(?:^|/)(?:auth\.json|\.env[^/]*|id_rsa|id_ed25519|id_ecdsa|id_dsa|\.netrc|_netrc|\.npmrc|\.pypirc|secrets?\.(?:json|ya?ml)|token\.json|service-account\.json|keystore|gh_token|api-token\.txt|\.htpasswd)$'
	},
	@{
		Category = 'credential'
		Pattern = '(?:\.(?:pem|key|p12|pfx|jks|p8|ppk))$'
	},
	@{
		Category = 'credential'
		Pattern = '(?:^|/)[^/]*credentials[^/]*$'
	}
)

# The single tracked path allowed to live under Production/: it is what keeps
# the directory present in a fresh clone. Compared case-sensitively, so a
# differently-cased lookalike is still reported.
$script:ProductionAllowList = @('Production/PLACEHOLDER.md')

function Get-ShapeCategories([string]$Path) {
	$matched = New-Object System.Collections.Generic.List[string]
	foreach ($rule in $script:ShapeRules) {
		if ([regex]::IsMatch($Path, $rule.Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
			$matched.Add($rule.Category)
		}
	}
	if ($matched.Contains('generation-output') -and ($script:ProductionAllowList -ccontains $Path)) {
		# List<T>.Remove returns a bool; an unassigned return value would be
		# emitted into the pipeline and arrive here as a stray category.
		[void]$matched.Remove('generation-output')
	}
	return @($matched | Sort-Object -Unique)
}

# --------------------------------------------------------------- markdown links
# Acceptance 2 of docs/06-delivery.md asks for a link / placeholder check on a
# fresh clone. Links are resolved against the index with ordinal comparison, so
# a link that only resolves on a case-insensitive filesystem is a failure and
# not a silent pass.

function Resolve-RepoPath([string]$FromFile, [string]$Target) {
	$stack = New-Object System.Collections.Generic.List[string]
	$directory = $FromFile -replace '[^/]*$', ''
	foreach ($segment in ($directory -split '/')) {
		if ($segment -ne '') { $stack.Add($segment) }
	}
	foreach ($segment in ($Target -split '/')) {
		if ($segment -eq '' -or $segment -eq '.') { continue }
		if ($segment -eq '..') {
			if ($stack.Count -eq 0) { return $null }
			$stack.RemoveAt($stack.Count - 1)
			continue
		}
		$stack.Add($segment)
	}
	if ($stack.Count -eq 0) { return $null }
	return ($stack -join '/')
}

function Test-MarkdownLinks([string[]]$TrackedPaths) {
	$exact = New-Object 'System.Collections.Generic.HashSet[string]'
	$folded = New-Object 'System.Collections.Generic.HashSet[string]'
	foreach ($tracked in $TrackedPaths) {
		$exact.Add($tracked) | Out-Null
		$folded.Add($tracked.ToLowerInvariant()) | Out-Null
	}
	$linkPattern = '\[[^\]]*\]\(([^)\s]+)\)'
	foreach ($path in $TrackedPaths) {
		if (-not $path.ToLowerInvariant().EndsWith('.md')) { continue }
		$full = Join-Path $RepoRoot ($path -replace '/', '\')
		if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
		$lineNumber = 0
		foreach ($line in ([System.IO.File]::ReadAllText($full) -split "`r?`n")) {
			$lineNumber++
			foreach ($match in [regex]::Matches($line, $linkPattern)) {
				$target = $match.Groups[1].Value
				if ($target -match '^[a-zA-Z][a-zA-Z0-9+.-]*:') { continue }
				if ($target.StartsWith('#')) { continue }
				$target = ($target -split '#')[0]
				if ($target.Length -le 1) { continue }
				$resolved = Resolve-RepoPath $path $target
				if ($null -eq $resolved) {
					Add-Finding 'link' ('{0}:{1} -> {2} (escapes the repository root)' -f $path, $lineNumber, $target)
					continue
				}
				if ($target.EndsWith('/')) {
					$prefix = $resolved + '/'
					$present = $false
					foreach ($candidate in $TrackedPaths) {
						if ($candidate.StartsWith($prefix, [System.StringComparison]::Ordinal)) { $present = $true; break }
					}
					if (-not $present) {
						Add-Finding 'link' ('{0}:{1} -> {2} (directory has no tracked entry)' -f $path, $lineNumber, $target)
					}
					continue
				}
				if ($exact.Contains($resolved)) { continue }
				$reason = if ($folded.Contains($resolved.ToLowerInvariant())) { 'tracked only under a different letter case' } else { 'not tracked' }
				Add-Finding 'link' ('{0}:{1} -> {2} ({3})' -f $path, $lineNumber, $target, $reason)
			}
		}
	}
}

# ---------------------------------------------------------------------- audit

# A quote in the path would split the -C argument; refuse instead of auditing
# some other directory.
if ($RepoRoot.Contains('"')) {
	Add-Finding 'environment' 'the repository path contains a double quote, so the audit refuses to guess which directory to read'
	Complete-Audit 2
}

$toplevel = Invoke-GitText @('rev-parse', '--show-toplevel')
if ($toplevel.ExitCode -ne 0) {
	Add-Finding 'environment' ('{0} is not a git worktree: {1}' -f $RepoRoot, ($toplevel.Lines -join ' '))
	Complete-Audit 2
}

$tracked = Invoke-GitNul @('ls-files', '-z')
if ($tracked.ExitCode -ne 0) {
	Add-Finding 'environment' ('could not read the index: ' + $tracked.StdErr)
	Complete-Audit 2
}

if ($tracked.Records.Count -eq 0) {
	Add-Finding 'environment' 'the index is empty; there is no published surface to audit'
	Complete-Audit 2
}

$trackedPaths = @($tracked.Records)
$script:TrackedCount = $trackedPaths.Count

# The verdict comes from these rules only; `.gitignore` is not consulted.
foreach ($path in $trackedPaths) {
	foreach ($category in (Get-ShapeCategories $path)) {
		Add-Finding $category $path
	}
}

# Second signal: tracked AND matching an exclude pattern. Configuration
# dependent (see the header note), reported separately so a reader can tell the
# two detection paths apart.
$trackedIgnored = Invoke-GitNul @('ls-files', '-ci', '--exclude-standard', '-z')
if ($trackedIgnored.ExitCode -ne 0) {
	Add-Finding 'environment' ('git ls-files -ci --exclude-standard failed: ' + $trackedIgnored.StdErr)
} else {
	foreach ($path in $trackedIgnored.Records) {
		Add-Finding 'tracked-ignored' $path
	}
}

# Not a failure, but these enter the published surface on the next
# `git add -A`, so a publish review must see them before committing.
$untracked = Invoke-GitNul @('ls-files', '--others', '--exclude-standard', '-z')
if ($untracked.ExitCode -ne 0) {
	Add-Finding 'environment' ('git ls-files --others --exclude-standard failed: ' + $untracked.StdErr)
} else {
	foreach ($path in $untracked.Records) {
		$categories = @(Get-ShapeCategories $path)
		if ($categories.Count -eq 0) {
			Add-Warning 'untracked' $path
		} else {
			foreach ($category in $categories) { Add-Warning ('untracked-' + $category) $path }
		}
	}
}

# Placeholder: without this tracked file a fresh clone has no Production/
# directory at all, and the generator's exclusive output creation has nowhere
# to land.
$placeholderTracked = $false
foreach ($path in $trackedPaths) {
	if ([string]::Equals($path, 'Production/PLACEHOLDER.md', [System.StringComparison]::Ordinal)) { $placeholderTracked = $true; break }
}
if (-not $placeholderTracked) {
	Add-Finding 'placeholder' 'Production/PLACEHOLDER.md is not tracked, so a fresh clone loses Production/'
}

Test-MarkdownLinks $trackedPaths

if ($script:Findings.Count -gt 0) { Complete-Audit 1 }
Complete-Audit 0
