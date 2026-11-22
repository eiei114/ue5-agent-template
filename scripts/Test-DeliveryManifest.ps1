[CmdletBinding()]
param(
	# The SHA256SUMS.txt to verify.
	[Parameter(Mandatory = $true)]
	[string]$ManifestPath,

	# DELIVERY.json of the same run. When given, the manifest path set must equal the declared
	# artifacts (both directions) and each file length must equal artifacts[].bytes.
	[string]$DeliveryJson = '',

	# Check only the manifest bytes and their syntax; do not open the listed files.
	[switch]$FormatOnly
)

# Exit codes: 0 = manifest verified, 1 = a violation was found, 2 = input defect (unreadable
# manifest or DELIVERY.json). Nothing here depends on the current working directory: every listed
# file is resolved from the directory that holds the manifest. That is the point. `sha256sum -c`
# resolves names from the caller's cwd, so a same-named stale copy in extracted-check/ makes a
# tampered file verify (docs/05-qa.md). This verifier cannot be fooled that way.
#
# ASCII-only source: Windows PowerShell 5.1 and pwsh 7 parse it the same way.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DeliveryManifest.ps1')

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
	Write-Output "INPUT: the manifest was not found: $ManifestPath"
	exit 2
}
$manifestFull = [System.IO.Path]::GetFullPath($ManifestPath)
$baseDirectory = [System.IO.Path]::GetDirectoryName($manifestFull)
$bytes = [System.IO.File]::ReadAllBytes($manifestFull)

$findings = New-Object System.Collections.Generic.List[string]
$entries = New-Object System.Collections.Specialized.OrderedDictionary
foreach ($finding in (Get-DeliveryManifestFormatFindings $bytes $entries)) { $findings.Add("format: $finding") }

if ($findings.Count -eq 0 -and $DeliveryJson -ne '') {
	try {
		$declared = Get-DeliveryDeclaredArtifacts $DeliveryJson
	} catch {
		Write-Output "INPUT: $($_.Exception.Message)"
		exit 2
	}
	if ($declared.Count -eq 0) {
		$findings.Add('set: DELIVERY.json declares no artifact that belongs in the manifest')
	}
	foreach ($path in $declared.Keys) {
		if (-not $entries.Contains($path)) { $findings.Add("set: declared artifact '$path' is missing from the manifest") }
	}
	foreach ($path in $entries.Keys) {
		if (-not $declared.Contains($path)) { $findings.Add("set: manifest entry '$path' is not a declared artifact") }
	}
}

if ($findings.Count -eq 0 -and -not $FormatOnly) {
	foreach ($path in $entries.Keys) {
		$full = [System.IO.Path]::GetFullPath((Join-Path $baseDirectory $path.Replace('/', [System.IO.Path]::DirectorySeparatorChar)))
		$prefix = $baseDirectory.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
		if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
			$findings.Add("file: '$path' resolves outside the manifest directory")
			continue
		}
		if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
			$findings.Add("file: '$path' does not exist next to the manifest ($baseDirectory)")
			continue
		}
		$actual = Get-DeliverySha256Hex $full
		if ($actual -cne $entries[$path]) {
			$findings.Add("hash: '$path' is $actual, the manifest says $($entries[$path])")
		}
		if ($DeliveryJson -ne '' -and $declared.Contains($path)) {
			$length = (New-Object System.IO.FileInfo($full)).Length
			if ($length -ne $declared[$path].Bytes) {
				$findings.Add("bytes: '$path' is $length bytes, DELIVERY.json declares $($declared[$path].Bytes)")
			}
		}
	}
}

if ($findings.Count -gt 0) {
	foreach ($finding in $findings) { Write-Output "FAIL: $finding" }
	exit 1
}
Write-Output ("PASS: {0} entries verified from {1}" -f $entries.Count, $baseDirectory)
exit 0
