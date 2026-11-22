[CmdletBinding()]
param(
	# DELIVERY.json of the run (Out/run_<runid>/DELIVERY.json). artifacts[].filename is the input.
	[Parameter(Mandatory = $true)]
	[string]$DeliveryJson,

	# Directory that artifact filenames are relative to, and that receives SHA256SUMS.txt.
	# Defaults to the directory of DELIVERY.json. The manifest and the artifacts share one root
	# so that `sha256sum -c` run in that directory resolves the same files this script hashed.
	[string]$BaseDirectory = ''
)

# Writes SHA256SUMS.txt for the artifacts DELIVERY.json declares, or throws and writes nothing.
# It stops on: no declared artifact, a missing file, a bytes mismatch, a declared sha256 that does
# not match, an unusable path. After writing it re-reads the file and runs the same checks as
# Test-DeliveryManifest.ps1; a manifest that fails them is deleted and the script throws.
#
# ASCII-only source: Windows PowerShell 5.1 and pwsh 7 parse it the same way.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DeliveryManifest.ps1')

$deliveryFull = [System.IO.Path]::GetFullPath($DeliveryJson)
if ($BaseDirectory -eq '') {
	$baseFull = [System.IO.Path]::GetDirectoryName($deliveryFull)
} else {
	$baseFull = [System.IO.Path]::GetFullPath($BaseDirectory)
}
if (-not (Test-Path -LiteralPath $baseFull -PathType Container)) { throw "the base directory does not exist: $baseFull" }

$declared = Get-DeliveryDeclaredArtifacts $deliveryFull
if ($declared.Count -eq 0) {
	throw 'DELIVERY.json declares no artifact that belongs in the manifest; refusing to write an empty manifest.'
}

$problems = New-Object System.Collections.Generic.List[string]
$hashes = @{}
$prefix = $baseFull.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
foreach ($path in $declared.Keys) {
	$full = [System.IO.Path]::GetFullPath((Join-Path $baseFull $path.Replace('/', [System.IO.Path]::DirectorySeparatorChar)))
	if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
		$problems.Add("'$path' resolves outside the base directory")
		continue
	}
	if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
		$problems.Add("declared artifact '$path' does not exist under $baseFull")
		continue
	}
	$length = (New-Object System.IO.FileInfo($full)).Length
	if ($length -ne $declared[$path].Bytes) {
		$problems.Add("'$path' is $length bytes but DELIVERY.json declares $($declared[$path].Bytes)")
		continue
	}
	$hex = Get-DeliverySha256Hex $full
	$declaredSha = $declared[$path].Sha256
	if ($null -ne $declaredSha -and $declaredSha -cne $hex) {
		$problems.Add("'$path' hashes to $hex but DELIVERY.json declares sha256 $declaredSha")
		continue
	}
	$hashes[$path] = $hex
}
if ($problems.Count -gt 0) {
	throw ("SHA256SUMS.txt was not written:`n  " + ($problems -join "`n  "))
}

$builder = New-Object System.Text.StringBuilder
$ordered = [string[]]@($declared.Keys)
[System.Array]::Sort($ordered, [System.StringComparer]::Ordinal)
foreach ($path in $ordered) {
	[void]$builder.Append($hashes[$path]).Append('  ').Append($path).Append("`n")
}
$manifestPath = Join-Path $baseFull $script:DeliveryManifestFileName
[System.IO.File]::WriteAllBytes($manifestPath, (New-Object System.Text.UTF8Encoding($false)).GetBytes($builder.ToString()))

# Self-check: byte format, path set and hashes, by the same verifier an operator runs later.
$verifier = Join-Path $PSScriptRoot 'Test-DeliveryManifest.ps1'
$report = @(& $verifier -ManifestPath $manifestPath -DeliveryJson $deliveryFull 2>&1 | ForEach-Object { [string]$_ })
if ($LASTEXITCODE -ne 0) {
	Remove-Item -LiteralPath $manifestPath -Force
	throw ("the generated manifest failed its own verification and was removed:`n  " + ($report -join "`n  "))
}
Write-Output $manifestPath
