[CmdletBinding()]
param(
	# Resolved in the body: a parameter default that reads $PSScriptRoot is empty when this script is
	# invoked through `powershell -File` on Windows PowerShell 5.1.
	[string]$PinPath = '',

	# Use an already downloaded archive instead of fetching the pinned URL.
	[string]$ArchivePath = '',

	[ValidateRange(30, 900)]
	[int]$DownloadTimeoutSeconds = 300
)

# Regression check for the CI decoder pin (DOT-3404).
#
# `.github/workflows/verify.yml` used to accept whatever ffprobe a `windows-latest` runner image
# happened to ship and fell back to an unversioned `choco install ffmpeg`, so the decode assertion
# could change verdict with no change to this repository. This suite supplies the missing negative
# evidence: an incomplete manifest, a changed archive and a different ffprobe ahead on PATH must all
# be refused, and only the pinned binary's exact bytes plus version may be accepted.
#
# The installer is driven with -ArchivePath here so the suite downloads the pinned archive at most
# once; the workflow's own step exercises the same installer through the manifest URL.
#
# It never writes inside the checkout. Everything it builds lives in a temp directory removed in
# `finally`, so the repository tree is identical before and after.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FfprobePin.ps1')
if ([string]::IsNullOrWhiteSpace($PinPath)) { $PinPath = Join-Path $PSScriptRoot 'ffprobe-pin.json' }

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$installScript = Join-Path $PSScriptRoot 'Install-PinnedFfprobe.ps1'
$workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ffprobe-pin-test-' + [Guid]::NewGuid().ToString('N'))
$originalPath = $env:PATH

function Assert-True([bool]$Condition, [string]$Message) {
	if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Get-InitialCheckoutStatus {
	$status = @(& git -C $repoRoot status --porcelain --untracked-files=all)
	if ($LASTEXITCODE -ne 0) { throw 'Could not record the developer checkout status before testing.' }
	return $status
}

function Invoke-Installer([hashtable]$Arguments) {
	# The installer's refusal has to be observable as a captured message, not an unlabelled exception.
	try {
		$null = & $installScript @Arguments
		return [pscustomobject]@{ Threw = $false; Error = '' }
	} catch {
		return [pscustomobject]@{ Threw = $true; Error = $_.Exception.Message }
	}
}

function Set-PathPrefix([string]$Directory) {
	$env:PATH = $Directory + [System.IO.Path]::PathSeparator + $originalPath
}

function Get-PathFfprobe {
	return @(Get-Command -Name 'ffprobe' -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
}

function Get-Sha256([string]$Path) {
	return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$initialCheckoutStatus = @(Get-InitialCheckoutStatus)
$suiteError = $null

try {
	[System.IO.Directory]::CreateDirectory($workRoot) | Out-Null
	$pin = Read-FfprobePin $PinPath

	# ============================================================ group 1: the manifest is complete
	$shapeViolations = @(Get-FfprobePinShapeViolations $pin)
	Assert-True ($shapeViolations.Count -eq 0) ("the committed pin manifest declares url, entry, both hashes and the version prefix: " + ($shapeViolations -join '; '))
	Assert-True ($pin.archive.url.StartsWith('https://')) 'the pinned archive URL is HTTPS'
	Assert-True ($pin.archive.sha256 -cmatch '^[0-9a-f]{64}$') 'the pinned archive sha256 is recorded in lower-case hex'
	Assert-True ($pin.ffprobe.sha256 -cmatch '^[0-9a-f]{64}$') 'the pinned ffprobe sha256 is recorded in lower-case hex'

	# A manifest that loses its guarantees must be rejected before any download happens. The broken
	# copy declares an http:// URL and a truncated hash, so each violation has to be named.
	$brokenPinPath = Join-Path $workRoot 'broken-pin.json'
	$brokenPin = [System.IO.File]::ReadAllText($PinPath) | ConvertFrom-Json
	$brokenPin.archive.url = ($brokenPin.archive.url -replace '^https://', 'http://')
	$brokenPin.archive.sha256 = $pin.archive.sha256.Substring(0, 32)
	[System.IO.File]::WriteAllText($brokenPinPath, ($brokenPin | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
	$brokenShape = @(Get-FfprobePinShapeViolations (Read-FfprobePin $brokenPinPath))
	Assert-True ($brokenShape.Count -ge 2) ("a manifest with an http URL and a truncated hash reports both violations, got: " + ($brokenShape -join '; '))
	Assert-True (($brokenShape -join '; ').Contains('archive.url is not absolute HTTPS')) 'the manifest check names the insecure URL'
	Assert-True (($brokenShape -join '; ').Contains('archive.sha256 is not a 64-character hex SHA-256')) 'the manifest check names the malformed hash'
	$brokenArchive = Join-Path $workRoot 'broken-input.zip'
	[System.IO.File]::WriteAllBytes($brokenArchive, [byte[]](1, 2, 3, 4))
	$brokenInstall = Invoke-Installer @{
		PinPath = $brokenPinPath
		ArchivePath = $brokenArchive
		OutputDirectory = (Join-Path $workRoot 'broken-out')
	}
	Assert-True ($brokenInstall.Threw) 'the installer refuses an incomplete pin manifest instead of installing anyway'
	Assert-True ($brokenInstall.Error.Contains('the pin manifest is complete')) "the refusal names the manifest rule, got: $($brokenInstall.Error)"
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $workRoot 'broken-out\ffprobe.exe'))) 'the refused manifest produced no decoder'
	Write-Output 'PASS: the pin manifest must declare an HTTPS URL, both SHA-256 values and the version prefix, and an incomplete one is refused before install'

	# ============================================================ group 2: the pinned archive installs and the hashes are enforced
	if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
		$ArchivePath = Join-Path $workRoot (Split-Path -Leaf ([System.Uri]::new($pin.archive.url).AbsolutePath))
		Write-Host "decoder archive download: $($pin.archive.url)"
		$ProgressPreference = 'SilentlyContinue'
		[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
		Invoke-WebRequest -Uri $pin.archive.url -OutFile $ArchivePath -TimeoutSec $DownloadTimeoutSeconds -UseBasicParsing
	}
	Assert-True (Test-Path -LiteralPath $ArchivePath -PathType Leaf) "the archive to install is available: $ArchivePath"
	Assert-True ((Get-Sha256 $ArchivePath) -ceq $pin.archive.sha256.ToLowerInvariant()) "the supplied archive is the pinned archive: $ArchivePath"

	$installOut = Join-Path $workRoot 'pinned'
	$install = Invoke-Installer @{
		PinPath = $PinPath
		ArchivePath = $ArchivePath
		OutputDirectory = $installOut
	}
	Assert-True (-not $install.Threw) "the pinned decoder installs from the recorded source: $($install.Error)"
	$pinnedPath = Join-Path $installOut $pin.ffprobe.name
	Assert-True (Test-Path -LiteralPath $pinnedPath -PathType Leaf) 'the installer placed the decoder at the requested output directory'
	Assert-True ((Get-Sha256 $pinnedPath) -ceq $pin.ffprobe.sha256.ToLowerInvariant()) 'the installed binary is the pinned ffprobe byte for byte'
	Assert-True ((@(Get-FfprobePinViolations -Path $pinnedPath -ExpectedSha256 $pin.ffprobe.sha256 -VersionLinePrefix $pin.ffprobe.version_line_prefix).Count) -eq 0) 'the installed binary satisfies every pin rule'

	# An archive of the same size with one changed byte must be refused by the recorded hash, so a
	# substituted download cannot reach the runner's PATH even when the URL looks familiar.
	$tamperedArchive = Join-Path $workRoot 'tampered.zip'
	$archiveBytes = [System.IO.File]::ReadAllBytes($ArchivePath)
	$middle = [int]($archiveBytes.Length / 2)
	$archiveBytes[$middle] = [byte]($archiveBytes[$middle] -bxor 0x01)
	[System.IO.File]::WriteAllBytes($tamperedArchive, $archiveBytes)
	Assert-True ((Get-Sha256 $tamperedArchive) -cne $pin.archive.sha256.ToLowerInvariant()) 'the tampered fixture keeps the pinned size but not the pinned hash'
	$tamperedInstall = Invoke-Installer @{
		PinPath = $PinPath
		ArchivePath = $tamperedArchive
		OutputDirectory = (Join-Path $workRoot 'tampered-out')
	}
	Assert-True ($tamperedInstall.Threw) 'an archive whose bytes were changed is refused instead of being installed'
	Assert-True ($tamperedInstall.Error.Contains('does not match the pinned sha256')) "the refusal names the archive hash rule, got: $($tamperedInstall.Error)"
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $workRoot 'tampered-out\ffprobe.exe'))) 'the refused archive produced no decoder'
	Write-Output 'PASS: the pinned archive installs, and a changed archive or an incomplete manifest is refused before anything is installed'

	# ============================================================ group 3: a different ffprobe ahead on PATH is a violation
	# This is the condition the old workflow silently accepted: another decoder answers PATH lookup
	# first, so the decode verdict depends on the runner image instead of this repository. The shim
	# reports a different version as well as different bytes, so both pin rules have to fire.
	$shadowDir = Join-Path $workRoot 'shadow'
	[System.IO.Directory]::CreateDirectory($shadowDir) | Out-Null
	$shadowProbe = Join-Path $shadowDir 'ffprobe.cmd'
	[System.IO.File]::WriteAllText($shadowProbe, "@echo off`r`necho ffprobe version 7.1.0-essentials_build-www.gyan.dev`r`nexit /b 0", [System.Text.UTF8Encoding]::new($false))
	Assert-True ((Get-Sha256 $shadowProbe) -cne $pin.ffprobe.sha256.ToLowerInvariant()) 'the shadow fixture is not the pinned binary'

	Set-PathPrefix $shadowDir
	$shadowResolved = Get-PathFfprobe
	Assert-True ($null -ne $shadowResolved) 'a shadow decoder is visible through PATH lookup'
	Assert-True ([System.IO.Path]::GetFullPath($shadowResolved.Source) -eq [System.IO.Path]::GetFullPath($shadowProbe)) 'PATH lookup resolves the shadow decoder first, which is the runner condition the pin exists for'
	$shadowViolations = @(Get-FfprobePinViolations -Path $shadowResolved.Source -ExpectedSha256 $pin.ffprobe.sha256 -VersionLinePrefix $pin.ffprobe.version_line_prefix)
	Assert-True ($shadowViolations.Count -ge 2) ("a shadow decoder fails both the hash and the version rule, got: " + ($shadowViolations -join '; '))
	Assert-True (($shadowViolations -join '; ').Contains('pinned')) 'the shadow refusal names the pinned hash'
	Assert-True (($shadowViolations -join '; ').Contains('does not start with')) 'the shadow refusal names the version prefix'
	Write-Output 'PASS: a different ffprobe ahead on PATH is reported as a pin violation instead of being accepted'

	# ============================================================ group 4: the installed directory wins PATH lookup
	Set-PathPrefix (Split-Path -Parent $pinnedPath)
	$pinnedResolved = Get-PathFfprobe
	Assert-True ($null -ne $pinnedResolved) 'the pinned decoder is visible through PATH lookup'
	Assert-True ((Get-Sha256 $pinnedResolved.Source) -ceq $pin.ffprobe.sha256.ToLowerInvariant()) 'PATH lookup now resolves the pinned binary instead of the shadow'
	Assert-True ((@(Get-FfprobePinViolations -Path $pinnedResolved.Source -ExpectedSha256 $pin.ffprobe.sha256 -VersionLinePrefix $pin.ffprobe.version_line_prefix).Count) -eq 0) 'the PATH-resolved decoder satisfies the pin'
	$versionProbe = Invoke-FfprobeVersionProbe -FilePath $pinnedResolved.Source -TimeoutMilliseconds 15000
	Assert-True ($versionProbe.VersionLine.StartsWith($pin.ffprobe.version_line_prefix, [System.StringComparison]::Ordinal)) "the PATH-resolved decoder reports the pinned version, got '$($versionProbe.VersionLine)'"
	Write-Output "PASS: prepending the installed directory makes PATH lookup resolve the pinned decoder ($($versionProbe.VersionLine))"
} catch {
	$suiteError = $_
} finally {
	$env:PATH = $originalPath
	if (Test-Path -LiteralPath $workRoot) {
		try { Remove-Item -LiteralPath $workRoot -Recurse -Force } catch { Write-Output "cleanup warning: $($_.Exception.Message)" }
	}
	$finalCheckoutStatus = @(& git -C $repoRoot status --porcelain --untracked-files=all)
	if ($LASTEXITCODE -ne 0) { throw 'Could not verify the developer checkout status after testing.' }
	if (($finalCheckoutStatus -join "`n") -cne ($initialCheckoutStatus -join "`n")) {
		if ($null -ne $suiteError) { Write-Output "ASSERT FAILED: $($suiteError.Exception.Message)" }
		Assert-True $false ('the pin suite leaves the developer checkout unchanged; before: ' + ($initialCheckoutStatus -join ' | ') + '; after: ' + ($finalCheckoutStatus -join ' | '))
	}
	if ($null -ne $suiteError) { throw $suiteError }
}
