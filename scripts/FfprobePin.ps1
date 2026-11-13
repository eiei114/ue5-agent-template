[CmdletBinding()]
param()

# Shared helpers for the CI decoder pin (DOT-3404). This file declares functions only; it is
# dot-sourced by scripts/Install-PinnedFfprobe.ps1 and scripts/Test-FfprobePin.ps1 so the install
# path and the regression check apply the same rules.

function Read-FfprobePin([string]$Path) {
	# Resolve relative to the PowerShell location: .NET file APIs use the process working directory,
	# which does not follow Set-Location, so a caller's relative path would otherwise be misread.
	if (-not [System.IO.Path]::IsPathRooted($Path)) { $Path = Join-Path (Get-Location).Path $Path }
	$Path = [System.IO.Path]::GetFullPath($Path)
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "decoder pin manifest not found: $Path" }
	return ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json)
}

function Get-FfprobePinShapeViolations($Pin) {
	$violations = New-Object System.Collections.Generic.List[string]
	foreach ($name in @('version', 'archive', 'ffprobe')) {
		if ($null -eq $Pin.$name) { $violations.Add("manifest is missing '$name'") }
	}
	if ($null -ne $Pin.archive) {
		if ([string]::IsNullOrWhiteSpace($Pin.archive.url)) { $violations.Add('archive.url is empty') }
		elseif ($Pin.archive.url -notmatch '^https://') { $violations.Add("archive.url is not absolute HTTPS: $($Pin.archive.url)") }
		if ([string]::IsNullOrWhiteSpace($Pin.archive.entry)) { $violations.Add('archive.entry is empty') }
		foreach ($pair in @(@('archive.sha256', $Pin.archive.sha256), @('ffprobe.sha256', $Pin.ffprobe.sha256))) {
			if ([string]::IsNullOrWhiteSpace($pair[1])) { $violations.Add("$($pair[0]) is empty") }
			elseif ($pair[1] -notmatch '^[0-9A-Fa-f]{64}$') { $violations.Add("$($pair[0]) is not a 64-character hex SHA-256: $($pair[1])") }
		}
	}
	if ($null -ne $Pin.ffprobe) {
		if ([string]::IsNullOrWhiteSpace($Pin.ffprobe.name)) { $violations.Add('ffprobe.name is empty') }
		if ([string]::IsNullOrWhiteSpace($Pin.ffprobe.version_line_prefix)) { $violations.Add('ffprobe.version_line_prefix is empty') }
	}
	return $violations.ToArray()
}

function Stop-OwnedFfprobeProcessTree([System.Diagnostics.Process]$Process) {
	# The version probe is a short bounded call. A deadline kill terminates only the process started
	# here, using the tree-kill overload when the runtime has it and taskkill by exact PID otherwise.
	try {
		$treeKill = $Process.GetType().GetMethod('Kill', [Type[]]@([bool]))
		if ($null -ne $treeKill) {
			$null = $treeKill.Invoke($Process, @($true))
			return
		}
	} catch { }
	try {
		$taskKill = @(Get-Command -Name 'taskkill.exe' -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
		if ($null -ne $taskKill) {
			$null = & $taskKill.Source /PID $Process.Id /T /F 2>&1
			return
		}
	} catch { }
	try { $Process.Kill() } catch { }
}

function Invoke-FfprobeVersionProbe([string]$FilePath, [int]$TimeoutMilliseconds) {
	$process = $null
	try {
		$startInfo = New-Object System.Diagnostics.ProcessStartInfo
		$startInfo.FileName = $FilePath
		$startInfo.Arguments = '-version'
		$startInfo.UseShellExecute = $false
		$startInfo.CreateNoWindow = $true
		$startInfo.RedirectStandardOutput = $true
		$startInfo.RedirectStandardError = $true
		$process = [System.Diagnostics.Process]::Start($startInfo)
		$stdoutTask = $process.StandardOutput.ReadToEndAsync()
		$stderrTask = $process.StandardError.ReadToEndAsync()
		if (-not $process.WaitForExit($TimeoutMilliseconds)) {
			Stop-OwnedFfprobeProcessTree $process
			return [pscustomobject]@{ Started = $true; TimedOut = $true; ExitCode = $null; Stdout = ''; Stderr = ''; VersionLine = '' }
		}
		$stdout = $stdoutTask.GetAwaiter().GetResult()
		$stderr = $stderrTask.GetAwaiter().GetResult()
		$firstLine = @(($stdout -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -First 1
		if ([string]::IsNullOrWhiteSpace($firstLine)) { $firstLine = '' } else { $firstLine = $firstLine.Trim() }
		return [pscustomobject]@{
			Started     = $true
			TimedOut    = $false
			ExitCode    = $process.ExitCode
			Stdout      = $stdout
			Stderr      = $stderr
			VersionLine = $firstLine
		}
	} finally {
		if ($null -ne $process) { $process.Dispose() }
	}
}

function Get-FfprobePinViolations {
	# Returns the reasons the candidate does not satisfy the pin. An empty result means the exact
	# pinned binary: same bytes and same reported version. Callers decide whether to throw, so the
	# check can be observed failing as well as passing.
	param(
		[string]$Path,
		[string]$ExpectedSha256,
		[string]$VersionLinePrefix,
		[int]$TimeoutMilliseconds = 15000
	)

	$violations = New-Object System.Collections.Generic.List[string]
	if ([string]::IsNullOrWhiteSpace($Path)) {
		$violations.Add('no decoder path was resolved')
		return $violations.ToArray()
	}
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		$violations.Add("decoder file is missing: $Path")
		return $violations.ToArray()
	}
	$actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
	if ($actualHash -cne $ExpectedSha256.ToLowerInvariant()) {
		$violations.Add("decoder sha256 is '$actualHash', pinned '$($ExpectedSha256.ToLowerInvariant())'")
	}
	$probe = Invoke-FfprobeVersionProbe -FilePath $Path -TimeoutMilliseconds $TimeoutMilliseconds
	if ($probe.TimedOut) {
		$violations.Add("decoder did not answer '-version' within ${TimeoutMilliseconds}ms")
		return $violations.ToArray()
	}
	if ($probe.ExitCode -ne 0) {
		$violations.Add("decoder '-version' exited $($probe.ExitCode): $($probe.Stderr)")
	}
	if ([string]::IsNullOrWhiteSpace($probe.VersionLine)) {
		$violations.Add("decoder printed no version line")
	} elseif (-not $probe.VersionLine.StartsWith($VersionLinePrefix, [System.StringComparison]::Ordinal)) {
		$violations.Add("decoder version line '$($probe.VersionLine)' does not start with '$VersionLinePrefix'")
	}
	return $violations.ToArray()
}
