[CmdletBinding()]
param()

# Regression suite for the delivery integrity manifest (DOT-3065). It needs no engine, no
# ffmpeg and no network. Fixtures are built under the system temp directory with self-made
# bytes; the developer checkout is compared before and after and must not change.
#
# ASCII-only source: Windows PowerShell 5.1 and pwsh 7 parse it the same way.
$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$generator = Join-Path $PSScriptRoot 'New-DeliveryManifest.ps1'
$verifier = Join-Path $PSScriptRoot 'Test-DeliveryManifest.ps1'
. (Join-Path $PSScriptRoot 'DeliveryManifest.ps1')

$initialStatus = @(& git -C $repoRoot status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0) { throw 'Could not record the developer checkout status before testing.' }
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('delivery-manifest-test-' + [Guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
$sha256sum = Get-Command sha256sum -ErrorAction SilentlyContinue
$groups = 0

function Assert-True([bool]$Condition, [string]$Message) {
	if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Write-Bytes([string]$Path, [byte[]]$Bytes) {
	[System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path)) | Out-Null
	[System.IO.File]::WriteAllBytes($Path, $Bytes)
}

function New-Run([string]$Name) {
	# Out/run_<runid>/ shape from AGENTS.md: DELIVERY.json at the run root, media under final/.
	$run = Join-Path $testRoot $Name
	$video = New-Object byte[] 5000
	for ($i = 0; $i -lt $video.Length; $i++) { $video[$i] = [byte]($i % 251) }
	Write-Bytes (Join-Path $run 'final/clean.mp4') $video
	Write-Bytes (Join-Path $run 'final/thumbnail.png') ([byte[]](1..200))
	Write-Bytes (Join-Path $run 'README.md') $utf8.GetBytes("readme`n")
	Write-Bytes (Join-Path $run 'CREDITS.md') $utf8.GetBytes("credits`n")
	Write-Bytes (Join-Path $run 'QA.md') $utf8.GetBytes("qa`n")
	Write-Delivery $run @(
		@{ filename = 'final/clean.mp4'; kind = 'video_mp4' },
		@{ filename = 'final/thumbnail.png'; kind = 'thumbnail' },
		@{ filename = 'README.md'; kind = 'readme' },
		@{ filename = 'CREDITS.md'; kind = 'credits' },
		@{ filename = 'QA.md'; kind = 'qa' },
		@{ filename = 'DELIVERY.json'; kind = 'delivery_manifest' },
		@{ filename = 'SHA256SUMS.txt'; kind = 'sha256sums' }
	)
	return $run
}

# Writes DELIVERY.json with the real byte length of each file that exists (a missing file keeps
# the bytes value 1 so a missing-file case still has a declared length).
function Write-Delivery([string]$Run, [object[]]$Artifacts, [hashtable]$BytesOverride = @{}) {
	$list = @()
	foreach ($artifact in $Artifacts) {
		$full = Join-Path $Run $artifact.filename
		$length = 1
		if (Test-Path -LiteralPath $full -PathType Leaf) { $length = (Get-Item -LiteralPath $full).Length }
		if ($BytesOverride.ContainsKey($artifact.filename)) { $length = $BytesOverride[$artifact.filename] }
		$entry = [ordered]@{ filename = $artifact.filename; bytes = $length; sha256 = $null; kind = $artifact.kind }
		if ($artifact.ContainsKey('sha256')) { $entry['sha256'] = $artifact.sha256 }
		$list += $entry
	}
	$json = [ordered]@{ schema_version = 1; artifacts = $list } | ConvertTo-Json -Depth 6
	[System.IO.File]::WriteAllText((Join-Path $Run 'DELIVERY.json'), $json, $utf8)
}

function Invoke-Generator([string]$Run) {
	$threw = $null
	try { & $generator -DeliveryJson (Join-Path $Run 'DELIVERY.json') | Out-Null } catch { $threw = $_.Exception.Message }
	return $threw
}

function Invoke-Verifier([string]$Manifest, [string]$Delivery = '', [switch]$FormatOnly) {
	$captured = New-Object System.Collections.Generic.List[string]
	$arguments = @{ ManifestPath = $Manifest }
	if ($Delivery -ne '') { $arguments['DeliveryJson'] = $Delivery }
	if ($FormatOnly) { $arguments['FormatOnly'] = $true }
	& $verifier @arguments 2>&1 | ForEach-Object { $captured.Add([string]$_) }
	return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($captured -join "`n") }
}

function Invoke-Sha256sumCheck([string]$WorkingDirectory, [string]$Manifest) {
	Push-Location -LiteralPath $WorkingDirectory
	# Windows PowerShell 5.1 turns native stderr into a terminating error under 'Stop'.
	$ErrorActionPreference = 'Continue'
	try {
		$out =& $sha256sum.Source -c $Manifest 2>&1
		return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
	} finally {
		Pop-Location
	}
}

function Get-Lines([string]$Path) {
	return @($utf8.GetString([System.IO.File]::ReadAllBytes($Path)).Split([char]10) | Where-Object { $_ -ne '' })
}

try {
	# ---- Group 1: the generator writes the contract bytes and the verifier accepts them.
	$run = New-Run 'g1'
	$threw = Invoke-Generator $run
	Assert-True ($null -eq $threw) "the generator succeeds on a complete run: $threw"
	$manifest = Join-Path $run 'SHA256SUMS.txt'
	$bytes = [System.IO.File]::ReadAllBytes($manifest)
	Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'no UTF-8 BOM'
	Assert-True (-not ($bytes -contains [byte]13)) 'no CR byte'
	Assert-True (-not ($bytes -contains [byte]0)) 'no NUL byte'
	Assert-True ($bytes[$bytes.Length - 1] -eq 10) 'ends with LF'
	$lines = Get-Lines $manifest
	Assert-True ($lines.Count -eq 5) "five artifacts are listed, the two self-referential kinds are not (got $($lines.Count))"
	foreach ($line in $lines) { Assert-True ($line -cmatch '^[0-9a-f]{64}  [^\\*].*$') "line has the contract shape: $line" }
	Assert-True (-not ($lines -match 'SHA256SUMS|DELIVERY\.json')) 'neither the manifest nor DELIVERY.json lists itself'
	Assert-True ($lines -contains ((Get-DeliverySha256Hex (Join-Path $run 'final/clean.mp4')) + '  final/clean.mp4')) 'nested path uses forward slashes'
	$ok = Invoke-Verifier $manifest (Join-Path $run 'DELIVERY.json')
	Assert-True ($ok.ExitCode -eq 0) "the verifier accepts the generated manifest: $($ok.Output)"
	if ($null -ne $sha256sum) {
		$check = Invoke-Sha256sumCheck $run 'SHA256SUMS.txt'
		Assert-True ($check.ExitCode -eq 0) "sha256sum -c exits 0 in the manifest directory: $($check.Output)"
	} else {
		Write-Output 'NOTE: sha256sum is not on PATH; the GNU cross-check was skipped.'
	}
	$groups++

	# ---- Group 2: the hash implementation agrees with independent tools and needs no Get-FileHash.
	$target = Join-Path $run 'final/clean.mp4'
	$ours = Get-DeliverySha256Hex $target
	$native = Get-Command -Module Microsoft.PowerShell.Utility -Name Get-FileHash -ErrorAction SilentlyContinue
	if ($null -ne $native) {
		Assert-True ($ours -ceq (& $native -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()) 'agrees with Get-FileHash'
	} else {
		Write-Output 'NOTE: Get-FileHash does not resolve in this host; the cross-check was skipped (this is the DOT-3065 host case).'
	}
	if ($null -ne (Get-Command certutil -ErrorAction SilentlyContinue)) {
		$certutilOut = @(& certutil -hashfile $target SHA256)
		$certutilHash = ($certutilOut[1] -replace '\s', '').ToLowerInvariant()
		Assert-True ($ours -ceq $certutilHash) 'agrees with certutil -hashfile'
	}
	if ($null -ne $sha256sum) {
		# A relative name: GNU escapes a path that contains a backslash and prefixes the line with one.
		Push-Location -LiteralPath (Split-Path -Parent $target)
		try { $gnuLine = (& $sha256sum.Source 'clean.mp4') } finally { Pop-Location }
		Assert-True ($ours -ceq ($gnuLine.Split(' ')[0])) 'agrees with sha256sum'
	}
	# A function shadows a cmdlet of the same name, so a throwing stand-in proves the generator
	# and verifier never call Get-FileHash. Removing the function restores the host.
	$run2 = New-Run 'g2'
	function global:Get-FileHash { throw 'Get-FileHash must not be used by the delivery manifest tools' }
	try {
		$threw = Invoke-Generator $run2
		Assert-True ($null -eq $threw) "the generator works with Get-FileHash unavailable: $threw"
		$shadowed = Invoke-Verifier (Join-Path $run2 'SHA256SUMS.txt') (Join-Path $run2 'DELIVERY.json')
		Assert-True ($shadowed.ExitCode -eq 0) "the verifier works with Get-FileHash unavailable: $($shadowed.Output)"
	} finally {
		Remove-Item function:\global:Get-FileHash -ErrorAction SilentlyContinue
	}
	$groups++

	# ---- Group 3: current default recipes produce manifests the verifier rejects.
	$formatRun = New-Run 'g3'
	$hex = Get-DeliverySha256Hex (Join-Path $formatRun 'QA.md')
	$goodLine = "$hex  QA.md"
	$formatCases = [ordered]@{}
	$formatCases['UTF-16LE with BOM (Windows PowerShell 5.1 Out-File default)'] = [byte[]]([byte[]](0xFF, 0xFE) + [System.Text.Encoding]::Unicode.GetBytes("$goodLine`r`n"))
	$formatCases['UTF-8 BOM + CRLF (Set-Content -Encoding UTF8 on 5.1)'] = [byte[]]([byte[]](0xEF, 0xBB, 0xBF) + $utf8.GetBytes("$goodLine`r`n"))
	$formatCases['UTF-8 no BOM + CRLF (pwsh 7 Out-File default)'] = $utf8.GetBytes("$goodLine`r`n")
	$formatCases['UTF-8 BOM + LF'] = [byte[]]([byte[]](0xEF, 0xBB, 0xBF) + $utf8.GetBytes("$goodLine`n"))
	$formatCases['no final LF'] = $utf8.GetBytes($goodLine)
	$formatCases['empty file'] = [byte[]]@()
	$formatCases['uppercase hex'] = $utf8.GetBytes("$($hex.ToUpperInvariant())  QA.md`n")
	$formatCases['single space separator'] = $utf8.GetBytes("$hex QA.md`n")
	$formatCases['binary flag asterisk'] = $utf8.GetBytes("$hex *QA.md`n")
	$formatCases['dot-slash prefix'] = $utf8.GetBytes("$hex  ./QA.md`n")
	$formatCases['backslash path'] = $utf8.GetBytes("$hex  final\clean.mp4`n")
	$formatCases['63 hex digits'] = $utf8.GetBytes("$($hex.Substring(1))  QA.md`n")
	$formatCases['parent segment'] = $utf8.GetBytes("$hex  ../QA.md`n")
	$formatCases['blank line'] = $utf8.GetBytes("$goodLine`n`n")
	$formatCases['duplicate path'] = $utf8.GetBytes("$goodLine`n$goodLine`n")
	foreach ($caseName in $formatCases.Keys) {
		$caseFile = Join-Path $formatRun 'case-SHA256SUMS.txt'
		Write-Bytes $caseFile ([byte[]]$formatCases[$caseName])
		$result = Invoke-Verifier $caseFile -FormatOnly
		Assert-True ($result.ExitCode -eq 1) "format case [$caseName] is rejected (exit $($result.ExitCode)): $($result.Output)"
		if ($null -ne $sha256sum -and $caseName -like 'UTF-16LE*') {
			$gnu = Invoke-Sha256sumCheck $formatRun 'case-SHA256SUMS.txt'
			Assert-True ($gnu.ExitCode -ne 0) 'GNU sha256sum also rejects the UTF-16LE manifest, so the rejection is not pedantry'
		}
	}
	# The host's real cmdlet defaults, not hand-built bytes. Whatever this host writes, it must be rejected.
	$outFile = Join-Path $formatRun 'outfile-SHA256SUMS.txt'
	$goodLine | Out-File -FilePath $outFile
	Assert-True ((Invoke-Verifier $outFile -FormatOnly).ExitCode -eq 1) 'this host''s Out-File default output is rejected'
	$setContent = Join-Path $formatRun 'setcontent-SHA256SUMS.txt'
	Set-Content -LiteralPath $setContent -Value $goodLine -Encoding UTF8
	Assert-True ((Invoke-Verifier $setContent -FormatOnly).ExitCode -eq 1) 'this host''s Set-Content -Encoding UTF8 output is rejected'
	# The one accepted spelling.
	$goodFile = Join-Path $formatRun 'good-SHA256SUMS.txt'
	Write-Bytes $goodFile ($utf8.GetBytes("$goodLine`n"))
	Assert-True ((Invoke-Verifier $goodFile -FormatOnly).ExitCode -eq 0) 'UTF-8 no BOM + LF + two spaces is accepted'
	$groups++

	# ---- Group 4: false pass through a stale copy in extracted-check/.
	$staleRun = New-Run 'g4'
	Assert-True ($null -eq (Invoke-Generator $staleRun)) 'the stale-copy fixture generates'
	$extracted = Join-Path $staleRun 'extracted-check'
	# A stale extracted copy of the whole delivery, as docs/05-qa.md produces.
	foreach ($relative in @('final/clean.mp4', 'final/thumbnail.png', 'README.md', 'CREDITS.md', 'QA.md')) {
		Write-Bytes (Join-Path $extracted $relative) ([System.IO.File]::ReadAllBytes((Join-Path $staleRun $relative)))
	}
	$tamperedBytes = [System.IO.File]::ReadAllBytes((Join-Path $staleRun 'final/clean.mp4'))
	$tamperedBytes[10] = [byte](($tamperedBytes[10] + 1) % 256)
	Write-Bytes (Join-Path $staleRun 'final/clean.mp4') $tamperedBytes
	$staleManifest = Join-Path $staleRun 'SHA256SUMS.txt'
	if ($null -ne $sha256sum) {
		$hazard = Invoke-Sha256sumCheck $extracted '../SHA256SUMS.txt'
		Assert-True ($hazard.ExitCode -eq 0) 'documents the hazard: sha256sum -c run from extracted-check/ passes although the real file was tampered'
		$right = Invoke-Sha256sumCheck $staleRun 'SHA256SUMS.txt'
		Assert-True ($right.ExitCode -ne 0) 'sha256sum -c in the manifest directory fails after tampering'
	}
	Push-Location -LiteralPath $extracted
	try {
		$fromStale = Invoke-Verifier $staleManifest (Join-Path $staleRun 'DELIVERY.json')
	} finally {
		Pop-Location
	}
	Assert-True ($fromStale.ExitCode -eq 1) "the verifier fails the tampered file even when started from the stale-copy directory: $($fromStale.Output)"
	Assert-True ($fromStale.Output -match 'final/clean\.mp4') 'the verifier names the tampered file'
	$groups++

	# ---- Group 5: completeness. Each case must stop; nothing may pass or be written.
	# 5a partial manifest (1 of 5)
	$partialRun = New-Run 'g5a'
	Assert-True ($null -eq (Invoke-Generator $partialRun)) 'fixture generates'
	$partialFile = Join-Path $partialRun 'SHA256SUMS.txt'
	$firstLine = (Get-Lines $partialFile)[0]
	Write-Bytes $partialFile ($utf8.GetBytes("$firstLine`n"))
	if ($null -ne $sha256sum) {
		Assert-True ((Invoke-Sha256sumCheck $partialRun 'SHA256SUMS.txt').ExitCode -eq 0) 'documents the hazard: sha256sum -c accepts a partial manifest'
	}
	$partial = Invoke-Verifier $partialFile (Join-Path $partialRun 'DELIVERY.json')
	Assert-True ($partial.ExitCode -eq 1 -and $partial.Output -match 'missing from the manifest') "a partial manifest is rejected: $($partial.Output)"
	# 5b empty manifest
	Write-Bytes $partialFile ([byte[]]@())
	Assert-True ((Invoke-Verifier $partialFile (Join-Path $partialRun 'DELIVERY.json')).ExitCode -eq 1) 'an empty manifest is rejected'
	# 5c entry that is not a declared artifact
	$extraRun = New-Run 'g5c'
	Assert-True ($null -eq (Invoke-Generator $extraRun)) 'fixture generates'
	Write-Bytes (Join-Path $extraRun 'extra.txt') ($utf8.GetBytes("extra`n"))
	$extraManifest = Join-Path $extraRun 'SHA256SUMS.txt'
	$extraText = $utf8.GetString([System.IO.File]::ReadAllBytes($extraManifest)) + (Get-DeliverySha256Hex (Join-Path $extraRun 'extra.txt')) + "  extra.txt`n"
	Write-Bytes $extraManifest ($utf8.GetBytes($extraText))
	$extra = Invoke-Verifier $extraManifest (Join-Path $extraRun 'DELIVERY.json')
	Assert-True ($extra.ExitCode -eq 1 -and $extra.Output -match 'not a declared artifact') "an undeclared entry is rejected: $($extra.Output)"
	# 5d bytes mismatch stops the generator and writes nothing
	$bytesRun = New-Run 'g5d'
	Write-Delivery $bytesRun @(@{ filename = 'QA.md'; kind = 'qa' }) @{ 'QA.md' = 999 }
	$threw = Invoke-Generator $bytesRun
	Assert-True ($null -ne $threw -and $threw -match 'declares 999') "a bytes mismatch stops the generator: $threw"
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $bytesRun 'SHA256SUMS.txt'))) 'no manifest is written after a bytes mismatch'
	# the verifier catches the same mismatch on an existing manifest
	$bytesOkRun = New-Run 'g5d2'
	Assert-True ($null -eq (Invoke-Generator $bytesOkRun)) 'fixture generates'
	$qaBytes = (Get-Item -LiteralPath (Join-Path $bytesOkRun 'QA.md')).Length
	Write-Delivery $bytesOkRun @(
		@{ filename = 'final/clean.mp4'; kind = 'video_mp4' }, @{ filename = 'final/thumbnail.png'; kind = 'thumbnail' },
		@{ filename = 'README.md'; kind = 'readme' }, @{ filename = 'CREDITS.md'; kind = 'credits' }, @{ filename = 'QA.md'; kind = 'qa' }
	) @{ 'QA.md' = ($qaBytes + 5) }
	$bytesVerify = Invoke-Verifier (Join-Path $bytesOkRun 'SHA256SUMS.txt') (Join-Path $bytesOkRun 'DELIVERY.json')
	Assert-True ($bytesVerify.ExitCode -eq 1 -and $bytesVerify.Output -match 'bytes:') "the verifier reports a bytes mismatch: $($bytesVerify.Output)"
	# 5e missing artifact stops the generator and writes nothing
	$missingRun = New-Run 'g5e'
	Remove-Item -LiteralPath (Join-Path $missingRun 'final/thumbnail.png')
	$threw = Invoke-Generator $missingRun
	Assert-True ($null -ne $threw -and $threw -match 'does not exist') "a missing artifact stops the generator: $threw"
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $missingRun 'SHA256SUMS.txt'))) 'no manifest is written when an artifact is missing'
	# 5f declared sha256 that disagrees with the file
	$shaRun = New-Run 'g5f'
	Write-Delivery $shaRun @(@{ filename = 'QA.md'; kind = 'qa'; sha256 = ('0' * 64) })
	$threw = Invoke-Generator $shaRun
	Assert-True ($null -ne $threw -and $threw -match 'declares sha256') "a wrong declared sha256 stops the generator: $threw"
	# 5g nothing to list, unusable paths
	$noneRun = New-Run 'g5g'
	Write-Delivery $noneRun @(@{ filename = 'DELIVERY.json'; kind = 'delivery_manifest' })
	$threw = Invoke-Generator $noneRun
	Assert-True ($null -ne $threw -and $threw -match 'no artifact') "an empty set stops the generator: $threw"
	foreach ($badName in @('../outside.txt', 'C:/Windows/win.ini', '/etc/hosts', './QA.md', '*QA.md')) {
		$badRun = New-Run 'g5h'
		Write-Delivery $badRun @(@{ filename = $badName; kind = 'qa' })
		$threw = Invoke-Generator $badRun
		Assert-True ($null -ne $threw -and $threw -match 'not usable') "path '$badName' stops the generator: $threw"
		Assert-True (-not (Test-Path -LiteralPath (Join-Path $badRun 'SHA256SUMS.txt'))) "no manifest is written for '$badName'"
		Remove-Item -LiteralPath $badRun -Recurse -Force
	}
	$groups++

	# ---- Group 6: a backslash declaration is normalized; verification catches later tampering.
	$slashRun = New-Run 'g6'
	Write-Delivery $slashRun @(@{ filename = 'final\clean.mp4'; kind = 'video_mp4' })
	Assert-True ($null -eq (Invoke-Generator $slashRun)) 'a backslash filename generates'
	$slashLines = @(Get-Lines (Join-Path $slashRun 'SHA256SUMS.txt'))
	Assert-True ($slashLines.Count -eq 1 -and $slashLines[0] -cmatch '^[0-9a-f]{64}  final/clean\.mp4$') "the backslash is written as a forward slash: $($slashLines -join '|')"
	Remove-Item -LiteralPath (Join-Path $slashRun 'final/clean.mp4')
	$gone = Invoke-Verifier (Join-Path $slashRun 'SHA256SUMS.txt')
	Assert-True ($gone.ExitCode -eq 1 -and $gone.Output -match 'does not exist') 'the verifier fails when a listed file is gone'
	Assert-True ((Invoke-Verifier (Join-Path $slashRun 'nope.txt')).ExitCode -eq 2) 'a missing manifest is an input defect (exit 2)'
	$groups++

	# ---- Group 7: the developer checkout is unchanged.
	$finalStatus = @(& git -C $repoRoot status --porcelain --untracked-files=all)
	Assert-True ($LASTEXITCODE -eq 0) 'could not read the checkout status after testing'
	Assert-True ((($initialStatus -join "`n")) -ceq (($finalStatus -join "`n"))) 'the checkout status is identical before and after the suite'
	$groups++
} finally {
	Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output "Test-DeliveryManifest.Tests.ps1: $groups groups passed"
exit 0
