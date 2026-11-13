[CmdletBinding()]
param(
	# Manifest that fixes the CI decoder: source URL, archive hash, binary hash and expected version.
	# Resolved in the body: a parameter default that reads $PSScriptRoot is empty when this script is
	# invoked through `powershell -File` on Windows PowerShell 5.1.
	[string]$PinPath = '',

	# Where the verified ffprobe.exe is placed. Defaults to a per-run directory under the temp path.
	[string]$OutputDirectory = '',

	# Use an already downloaded archive instead of fetching the pinned URL (the pin is still enforced).
	[string]$ArchivePath = '',

	# Copy the verified archive here so a later step can re-check it without downloading again.
	[string]$ArchiveCachePath = '',

	[ValidateRange(30, 900)]
	[int]$DownloadTimeoutSeconds = 300,

	[ValidateRange(1, 60)]
	[int]$VersionTimeoutSeconds = 15
)

# Resolves, verifies and installs the decoder that the render artifact inspection runs against.
# The CI job must not accept whatever ffprobe a runner image happens to ship: the archive and the
# extracted binary are compared with the hashes recorded in the pin manifest, and the extracted
# binary's own `-version` line has to match the pinned version. Any mismatch fails explicitly.
#
# The binary is written outside the checkout (temp by default) so nothing is vendored into the
# template or a delivered artifact. The resolved path is the only thing on the output stream;
# version and hash records go to the host log.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FfprobePin.ps1')
if ([string]::IsNullOrWhiteSpace($PinPath)) { $PinPath = Join-Path $PSScriptRoot 'ffprobe-pin.json' }

function Assert-True([bool]$Condition, [string]$Message) {
	if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Get-FileSha256([string]$Path) {
	return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$pin = Read-FfprobePin $PinPath
$shapeViolations = @(Get-FfprobePinShapeViolations $pin)
Assert-True ($shapeViolations.Count -eq 0) ("the pin manifest is complete: " + ($shapeViolations -join '; '))

$expectedArchiveHash = $pin.archive.sha256.ToLowerInvariant()
$expectedBinaryHash = $pin.ffprobe.sha256.ToLowerInvariant()

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
	$OutputDirectory = Join-Path ([System.IO.Path]::GetTempPath()) 'ffprobe-pin'
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
[System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$encoderPath = Join-Path $OutputDirectory $pin.ffprobe.name

$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ffprobe-pin-' + [Guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($stagingRoot) | Out-Null
$downloadPath = Join-Path $stagingRoot (Split-Path -Leaf ([System.Uri]::new($pin.archive.url).AbsolutePath))

try {
	if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
		Write-Host "decoder pin: $($pin.publisher) $($pin.version)"
		Write-Host "decoder archive: $($pin.archive.url)"
		[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
		$ProgressPreference = 'SilentlyContinue'
		Invoke-WebRequest -Uri $pin.archive.url -OutFile $downloadPath -TimeoutSec $DownloadTimeoutSeconds -UseBasicParsing
	} else {
		Assert-True (Test-Path -LiteralPath $ArchivePath -PathType Leaf) "the supplied archive exists: $ArchivePath"
		Copy-Item -LiteralPath $ArchivePath -Destination $downloadPath -Force
		Write-Host "decoder archive: $ArchivePath (local copy; the pinned hash is still required)"
	}

	$archiveHash = Get-FileSha256 $downloadPath
	Write-Host "decoder archive sha256: $archiveHash"
	Assert-True ($archiveHash -ceq $expectedArchiveHash) "the decoder archive does not match the pinned sha256 (expected $expectedArchiveHash, got $archiveHash)"

	Expand-Archive -LiteralPath $downloadPath -DestinationPath $stagingRoot -Force
	$entryPath = Join-Path $stagingRoot $pin.archive.entry
	Assert-True (Test-Path -LiteralPath $entryPath -PathType Leaf) "the pinned archive entry exists: $($pin.archive.entry)"
	Copy-Item -LiteralPath $entryPath -Destination $encoderPath -Force

	$binaryHash = Get-FileSha256 $encoderPath
	Write-Host "decoder sha256: $binaryHash"
	Assert-True ($binaryHash -ceq $expectedBinaryHash) "the extracted ffprobe does not match the pinned sha256 (expected $expectedBinaryHash, got $binaryHash)"

	if (-not [string]::IsNullOrWhiteSpace($ArchiveCachePath)) {
		# Copies the archive that just passed the hash check, so the regression suite can re-run
		# the install from a local file instead of downloading the same bytes twice.
		$cachePath = [System.IO.Path]::GetFullPath($ArchiveCachePath)
		$cacheDirectory = Split-Path -Parent $cachePath
		if (-not [string]::IsNullOrWhiteSpace($cacheDirectory)) { [System.IO.Directory]::CreateDirectory($cacheDirectory) | Out-Null }
		Copy-Item -LiteralPath $downloadPath -Destination $cachePath -Force
		Assert-True ((Get-FileSha256 $cachePath) -ceq $expectedArchiveHash) 'the cached archive is still the pinned archive'
		Write-Host "decoder archive cache: $cachePath"
	}

	$pinViolations = @(Get-FfprobePinViolations -Path $encoderPath -ExpectedSha256 $expectedBinaryHash -VersionLinePrefix $pin.ffprobe.version_line_prefix -TimeoutMilliseconds ($VersionTimeoutSeconds * 1000))
	Assert-True ($pinViolations.Count -eq 0) ("the installed decoder satisfies the pin: " + ($pinViolations -join '; '))
	$probe = Invoke-FfprobeVersionProbe -FilePath $encoderPath -TimeoutMilliseconds ($VersionTimeoutSeconds * 1000)
	Write-Host "decoder version: $($probe.VersionLine)"
} finally {
	if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force }
}

Write-Host "decoder ready: $encoderPath"
Write-Output $encoderPath
