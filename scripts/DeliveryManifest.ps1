# Shared rules for the delivery integrity manifest (SHA256SUMS.txt). Dot-sourced by
# New-DeliveryManifest.ps1, Test-DeliveryManifest.ps1 and their regression suite.
#
# This file is kept ASCII-only so Windows PowerShell 5.1 parses it without a BOM
# and both hosts read the same source.
#
# The contract, in one place (docs/04-package.md carries the operator-facing copy):
#   - bytes: UTF-8 without BOM, LF line endings only, a final LF, no empty line
#   - line:  <64 lowercase hex><two spaces><relative path with '/' separators>
#   - the path is relative to the directory that holds the manifest; that directory is
#     also the only working directory in which `sha256sum -c` is meaningful
#   - the set of paths equals DELIVERY.json artifacts[].filename, minus the kinds that
#     cannot contain their own hash (sha256sums, delivery_manifest)
#   - SHA-256 comes from .NET, never from Get-FileHash: that cmdlet is a module command
#     whose resolution depends on PSModulePath and can be absent on a Windows PowerShell 5.1 host.

Set-StrictMode -Version 2.0

# Kinds that cannot carry their own hash. The manifest cannot list itself, and DELIVERY.json
# holds the hashes of the other artifacts, so its own hash cannot be inside it either.
$script:DeliveryManifestSelfReferentialKinds = @('sha256sums', 'delivery_manifest')
$script:DeliveryManifestFileName = 'SHA256SUMS.txt'

function Get-DeliverySha256Hex([string]$Path) {
	$sha = [System.Security.Cryptography.SHA256]::Create()
	try {
		$stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
		try {
			$hash = $sha.ComputeHash($stream)
		} finally {
			$stream.Dispose()
		}
	} finally {
		$sha.Dispose()
	}
	return ([System.BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant())
}

# Returns the normalized relative path, or $null with a reason in $Reason.
function ConvertTo-DeliveryRelativePath([string]$Name, [ref]$Reason) {
	$Reason.Value = ''
	if ([string]::IsNullOrWhiteSpace($Name)) { $Reason.Value = 'the path is empty'; return $null }
	if ($Name -match '[\x00-\x1f\x7f]') { $Reason.Value = 'the path contains a control character'; return $null }
	$normalized = $Name.Replace('\', '/')
	if ($normalized.StartsWith('/')) { $Reason.Value = 'the path is absolute'; return $null }
	if ($normalized -match '^[A-Za-z]:') { $Reason.Value = 'the path names a drive'; return $null }
	if ($normalized.StartsWith('*')) { $Reason.Value = "the path starts with '*', which sha256sum reads as the binary flag"; return $null }
	if ($normalized -ne $normalized.Trim()) { $Reason.Value = 'the path has leading or trailing whitespace'; return $null }
	$segments = $normalized.Split('/')
	foreach ($segment in $segments) {
		if ($segment -eq '' -or $segment -eq '.' -or $segment -eq '..') {
			$Reason.Value = "the path has an empty, '.' or '..' segment"
			return $null
		}
	}
	return $normalized
}

# Checks the manifest bytes themselves. Returns a list of finding strings (empty = well formed)
# and, through $Entries, the parsed path -> hash map in file order.
function Get-DeliveryManifestFormatFindings([byte[]]$Bytes, [System.Collections.Specialized.OrderedDictionary]$Entries) {
	$findings = New-Object System.Collections.Generic.List[string]
	if ($Bytes.Length -eq 0) {
		$findings.Add('the manifest is empty')
		return $findings.ToArray()
	}
	if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
		$findings.Add('the manifest starts with a UTF-8 BOM (EF BB BF); sha256sum reads it as part of the first hash')
	}
	if (($Bytes.Length -ge 2) -and (($Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) -or ($Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF))) {
		$findings.Add('the manifest is UTF-16 (BOM FF FE or FE FF); it must be UTF-8 without BOM')
	}
	if ($Bytes -contains [byte]0) {
		$findings.Add('the manifest contains NUL bytes (UTF-16 or binary content)')
	}
	if ($Bytes -contains [byte]13) {
		$findings.Add('the manifest contains CR (0x0D); line endings must be LF only')
	}
	if ($findings.Count -gt 0) { return $findings.ToArray() }

	if ($Bytes[$Bytes.Length - 1] -ne 10) {
		$findings.Add('the manifest does not end with a LF')
	}
	$strict = New-Object System.Text.UTF8Encoding($false, $true)
	try {
		$text = $strict.GetString($Bytes)
	} catch {
		$findings.Add('the manifest is not valid UTF-8')
		return $findings.ToArray()
	}
	$lines = $text.Split([char]10)
	# The text ends with LF, so the final split element is the empty remainder.
	$lastIndex = $lines.Length - 1
	if ($lines[$lastIndex] -eq '') { $lastIndex = $lastIndex - 1 }
	for ($i = 0; $i -le $lastIndex; $i++) {
		$lineNo = $i + 1
		$line = $lines[$i]
		if ($line -eq '') {
			$findings.Add("line ${lineNo}: empty line")
			continue
		}
		$m = [regex]::Match($line, '^(?<hash>[0-9a-f]{64})  (?<path>.+)$')
		if (-not $m.Success) {
			$findings.Add("line ${lineNo}: not '<64 lowercase hex><two spaces><path>'")
			continue
		}
		$reason = ''
		$path = ConvertTo-DeliveryRelativePath $m.Groups['path'].Value ([ref]$reason)
		if ($null -eq $path) {
			$findings.Add("line ${lineNo}: $reason")
			continue
		}
		if ($path -cne $m.Groups['path'].Value) {
			$findings.Add("line ${lineNo}: the path uses a backslash; use '/'")
			continue
		}
		if ($Entries.Contains($path)) {
			$findings.Add("line ${lineNo}: duplicate path '$path'")
			continue
		}
		$Entries[$path] = $m.Groups['hash'].Value
	}
	return $findings.ToArray()
}

# Reads DELIVERY.json and returns the declared artifacts that must appear in the manifest.
# Throws on a malformed declaration so a caller never works from a half-read contract.
function Get-DeliveryDeclaredArtifacts([string]$DeliveryJsonPath) {
	if (-not (Test-Path -LiteralPath $DeliveryJsonPath -PathType Leaf)) {
		throw "DELIVERY.json was not found: $DeliveryJsonPath"
	}
	$json = [System.IO.File]::ReadAllText($DeliveryJsonPath, (New-Object System.Text.UTF8Encoding($false)))
	try {
		$delivery = $json | ConvertFrom-Json
	} catch {
		throw "DELIVERY.json is not valid JSON: $($_.Exception.Message)"
	}
	if ($null -eq $delivery.PSObject.Properties['artifacts']) { throw 'DELIVERY.json has no artifacts array' }
	$declared = New-Object System.Collections.Specialized.OrderedDictionary
	foreach ($artifact in @($delivery.artifacts)) {
		$kind = $null
		if ($null -ne $artifact.PSObject.Properties['kind']) { $kind = [string]$artifact.kind }
		if ($script:DeliveryManifestSelfReferentialKinds -contains $kind) { continue }
		$name = $null
		if ($null -ne $artifact.PSObject.Properties['filename']) { $name = [string]$artifact.filename }
		$reason = ''
		$path = ConvertTo-DeliveryRelativePath $name ([ref]$reason)
		if ($null -eq $path) { throw "artifact filename '$name' is not usable: $reason" }
		if ($declared.Contains($path)) { throw "artifact '$path' is declared twice" }
		if ($null -eq $artifact.PSObject.Properties['bytes'] -or $null -eq $artifact.bytes -or $artifact.bytes -isnot [ValueType] -or $artifact.bytes -is [bool]) {
			throw "artifact '$path' has no integer bytes value to check the file against"
		}
		$sha = $null
		if ($null -ne $artifact.PSObject.Properties['sha256'] -and $null -ne $artifact.sha256) { $sha = ([string]$artifact.sha256).ToLowerInvariant() }
		$declared[$path] = [pscustomobject]@{ Path = $path; Bytes = [long]$artifact.bytes; Sha256 = $sha }
	}
	return $declared
}
