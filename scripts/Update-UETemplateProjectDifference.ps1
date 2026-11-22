[CmdletBinding()]
param(
	# The generated project's template-lock.json (Production/<Name>_<runid>/template-lock.json).
	[Parameter(Mandatory = $true)]
	[string]$LockPath,

	# One or more `<label>: <value>` differences to add (docs/07-architecture.md, the project_differences contract section).
	[Parameter(Mandatory = $true)]
	[string[]]$Difference
)

# The one supported way to record a project difference AFTER generation (DOT-3452). It reads the lock,
# checks it, and replaces only the text of the `project_differences` array. Every other byte of the lock
# stays as written. Any failed check stops the run before the lock is touched; nothing is repaired.
#
# Stop conditions: the lock is missing or not valid JSON; it has no identity-bearing schema
# (schema_version >= 5, identity, template_commit, plugins, project_differences array of strings); its
# identity does not match the project files beside it; a value breaks the contract (also checked for
# values already in the lock); the lock changed between the read and the write; or the result would
# change any field other than project_differences.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UETemplateProjectDifference.ps1')

$strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)

# Values first: a bad value must stop the run before any file is read.
[string[]]$requested = @(ConvertTo-UETemplateProjectDifferences -Values $Difference)

if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) {
	throw "Project difference update stopped: no lock file at $LockPath. A lock is written only by the generator and is never created or repaired here."
}
$lockFull = [System.IO.Path]::GetFullPath($LockPath)
if ((Split-Path -Leaf $lockFull) -cne 'template-lock.json') {
	throw "Project difference update stopped: $lockFull is not named template-lock.json."
}
$projectRoot = Split-Path -Parent $lockFull

function Get-BytesSha256([byte[]]$Bytes) {
	$sha = [System.Security.Cryptography.SHA256]::Create()
	try { return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') } finally { $sha.Dispose() }
}

function Read-LockText([string]$Path) {
	$bytes = [System.IO.File]::ReadAllBytes($Path)
	try { $text = $strictUtf8.GetString($bytes) } catch { throw "Project difference update stopped: $Path is not valid UTF-8; it was not modified." }
	return [pscustomobject]@{ Bytes = $bytes; Text = $text; Sha256 = (Get-BytesSha256 $bytes) }
}

function ConvertFrom-LockText([string]$Text, [string]$Label) {
	$json = $Text.TrimStart([char]0xFEFF)
	try { return ($json | ConvertFrom-Json) } catch { throw "Project difference update stopped: $Label is not valid JSON ($($_.Exception.Message)); it was not modified and is not repaired." }
}

$before = Read-LockText $lockFull
$lock = ConvertFrom-LockText $before.Text 'the lock'

# Shape check. A lock without these fields is not a lock this repository's generator wrote.
if ($lock -isnot [pscustomobject]) { throw 'Project difference update stopped: the lock is not a JSON object.' }
foreach ($required in @('schema_version', 'identity', 'template_commit', 'plugins', 'project_differences')) {
	if ($null -eq $lock.PSObject.Properties[$required]) {
		throw "Project difference update stopped: the lock has no '$required' field, so it is not an identity-bearing lock (schema_version 5 or later). It was not modified."
	}
}
if (($lock.schema_version -isnot [int] -and $lock.schema_version -isnot [long]) -or [int64]$lock.schema_version -lt 5) {
	throw "Project difference update stopped: schema_version '$($lock.schema_version)' is older than 5, which is the first version that records identity. Regenerate with a new RunId instead of editing an old lock."
}
$existing = @($lock.project_differences | Where-Object { $null -ne $_ })
foreach ($item in $existing) {
	if ($item -isnot [string]) { throw 'Project difference update stopped: project_differences holds a value that is not a string.' }
}

# Identity check: the lock must still describe the project it sits beside.
$identity = $lock.identity
foreach ($field in @('project_file', 'project_modules', 'engine_association')) {
	if ($null -eq $identity.PSObject.Properties[$field]) { throw "Project difference update stopped: lock identity has no '$field'. It was not modified." }
}
$projectFileName = [string]$identity.project_file
if ($projectFileName -cnotmatch '^[A-Za-z0-9_.-]+\.uproject$') {
	throw "Project difference update stopped: lock identity.project_file '$projectFileName' is not a plain .uproject file name."
}
$projectFilePath = Join-Path $projectRoot $projectFileName
if (-not (Test-Path -LiteralPath $projectFilePath -PathType Leaf)) {
	throw "Project difference update stopped: lock identity.project_file '$projectFileName' does not exist beside the lock. The lock or the project was changed after generation; it was not modified."
}
$descriptor = ConvertFrom-LockText ([System.IO.File]::ReadAllText($projectFilePath)) $projectFileName
$descriptorModules = @($descriptor.Modules | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.Name })
[Array]::Sort($descriptorModules, [System.StringComparer]::Ordinal)
$lockModules = @($identity.project_modules | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
[Array]::Sort($lockModules, [System.StringComparer]::Ordinal)
if (($descriptorModules -join ',') -cne ($lockModules -join ',')) {
	throw "Project difference update stopped: lock identity.project_modules ($($lockModules -join ', ')) does not match the modules in $projectFileName ($($descriptorModules -join ', ')). The lock was not modified."
}
if ([string]$descriptor.EngineAssociation -cne [string]$identity.engine_association) {
	throw "Project difference update stopped: lock identity.engine_association '$($identity.engine_association)' does not match $projectFileName ('$($descriptor.EngineAssociation)'). The lock was not modified."
}

# Existing values are held to the same contract, so the written array is valid as a whole.
[string[]]$merged = @(ConvertTo-UETemplateProjectDifferences -Values (@($existing) + @($requested)))
[string[]]$existingNormalized = @(ConvertTo-UETemplateProjectDifferences -Values $existing)
$added = @($merged | Where-Object { $existingNormalized -cnotcontains $_ })
if ($added.Count -eq 0 -and (($existing -join "`n") -ceq ($merged -join "`n"))) {
	Write-Output "No change: every requested difference is already recorded. Lock left as is (SHA256 $($before.Sha256))."
	return
}

# Replace only the text of the project_differences array.
$arrayPattern = '("project_differences"\s*:\s*)\[(?:[^"\]]|"(?:[^"\\]|\\.)*")*\]'
$arrayMatches = [regex]::Matches($before.Text, $arrayPattern)
if ($arrayMatches.Count -ne 1) {
	throw "Project difference update stopped: expected exactly one project_differences array in the lock text, found $($arrayMatches.Count). It was not modified."
}
$match = $arrayMatches[0]
$newline = if ($before.Text.Contains("`r`n")) { "`r`n" } else { "`n" }
$lineStart = $before.Text.LastIndexOf("`n", $match.Index)
$indent = $before.Text.Substring($lineStart + 1, $match.Index - $lineStart - 1)
$encodedItems = @($merged | ForEach-Object { ConvertTo-Json -InputObject ([string]$_) -Compress })
if ($merged.Count -eq 0) {
	$arrayText = '[]'
} elseif ($lineStart -ge 0 -and $indent.Length -gt 0 -and $indent.Trim(' ').Length -eq 0) {
	$itemIndent = $indent + $indent
	$arrayText = '[' + $newline + (($encodedItems | ForEach-Object { $itemIndent + $_ }) -join (',' + $newline)) + $newline + $indent + ']'
} else {
	$arrayText = '[' + ($encodedItems -join ',') + ']'
}
$newText = $before.Text.Substring(0, $match.Index) + $match.Groups[1].Value + $arrayText + $before.Text.Substring($match.Index + $match.Length)

# Prove the result before it is written: same fields, same values, only project_differences differs.
$after = ConvertFrom-LockText $newText 'the updated lock text'
function Get-LockWithoutDifferences($Lock) {
	$copy = [ordered]@{}
	foreach ($property in $Lock.PSObject.Properties) {
		if ($property.Name -ne 'project_differences') { $copy[$property.Name] = $property.Value }
	}
	return (ConvertTo-Json -InputObject $copy -Depth 20 -Compress)
}
if ((Get-LockWithoutDifferences $lock) -cne (Get-LockWithoutDifferences $after)) {
	throw 'Project difference update stopped: the update would change a field other than project_differences. The lock was not modified.'
}
if ((@($after.project_differences) -join "`n") -cne ($merged -join "`n")) {
	throw 'Project difference update stopped: the updated array does not read back as the merged values. The lock was not modified.'
}

# Write through a sibling temp file and an atomic replace, so an interrupted run cannot leave a torn
# lock. The lock is re-read first: a lock that changed since the check is somebody else's write.
$tempPath = Join-Path $projectRoot ('.template-lock.json.{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
try {
	$recheck = [System.IO.File]::ReadAllBytes($lockFull)
	if ((Get-BytesSha256 $recheck) -cne $before.Sha256) {
		throw 'Project difference update stopped: the lock changed while it was being checked. It was not modified; run the update again.'
	}
	[System.IO.File]::WriteAllBytes($tempPath, $strictUtf8.GetBytes($newText))
	[System.IO.File]::Replace($tempPath, $lockFull, [NullString]::Value)
} finally {
	if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
}

$written = Read-LockText $lockFull
Write-Output "Updated $lockFull"
Write-Output "SHA256 before: $($before.Sha256)"
Write-Output "SHA256 after:  $($written.Sha256)"
Write-Output ("Added {0} difference(s); project_differences now holds {1}. No other field changed." -f $added.Count, $merged.Count)
