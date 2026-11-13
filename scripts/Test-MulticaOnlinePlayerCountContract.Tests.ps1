[CmdletBinding()]
param()

# Negative cases for Test-MulticaOnlinePlayerCountContract.ps1.
#
# The gate itself is the only thing standing between this defect and a future edit, so it has to be
# shown failing. Each case below mutates a disposable copy of the plugin source into a shape that
# reintroduces the missing decrement (or weakens the counting rule) and expects the gate to name it.
# Nothing here starts Unreal; the plugin C++ is only read as text.

$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$gate = Join-Path $PSScriptRoot 'Test-MulticaOnlinePlayerCountContract.ps1'
$sourcePlugin = Join-Path $repoRoot 'templates\online\MulticaOnlineStarter'
if (-not (Test-Path -LiteralPath $sourcePlugin -PathType Container)) {
	throw "The plugin source is missing: $sourcePlugin"
}

function Assert-True([bool]$Condition, [string]$Message) {
	if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function New-MutationRoot {
	$root = Join-Path ([System.IO.Path]::GetTempPath()) ('multica-netcount-' + [Guid]::NewGuid().ToString('N'))
	$target = Join-Path $root 'templates\online\MulticaOnlineStarter'
	[System.IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
	Copy-Item -LiteralPath $sourcePlugin -Destination $target -Recurse
	return $root
}

function Invoke-Gate([string]$Root) {
	$output = @(& $gate -RepositoryRoot $Root)
	$code = $LASTEXITCODE
	return [pscustomobject]@{ ExitCode = $code; Output = $output }
}

function Set-PluginFile([string]$Root, [string]$RelativePath, [string]$Content) {
	$path = Join-Path (Join-Path $Root 'templates\online\MulticaOnlineStarter') $RelativePath
	[System.IO.File]::WriteAllText($path, $Content, [System.Text.UTF8Encoding]::new($false))
}

$suiteError = $null
$roots = New-Object System.Collections.Generic.List[string]
try {
	# Control: the untouched source passes. A gate that fails everything would prove nothing.
	$controlRoot = New-MutationRoot
	$roots.Add($controlRoot)
	$control = Invoke-Gate $controlRoot
	Assert-True ($control.ExitCode -eq 0) ("the gate passes the current plugin source (exit $($control.ExitCode)): " + ($control.Output -join '; '))
	Write-Output 'PASS: the gate accepts the current plugin source'

	# NETCOUNT-R1/R2: Logout counts what the world currently contains, which still has the leaving
	# controller. This is the exact shape the template shipped with before DOT-3186.
	$getNumPlayersRoot = New-MutationRoot
	$roots.Add($getNumPlayersRoot)
	$gameModePath = 'Source\MulticaOnlineStarter\Private\MulticaOnlineGameMode.cpp'
	$gameModeText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $getNumPlayersRoot 'templates\online\MulticaOnlineStarter') $gameModePath))
	$mutated = [regex]::Replace(
		$gameModeText,
		'RefreshConnectedPlayerCount\s*\(\s*Exiting\s*\);',
		'GetNumPlayers();')
	Set-PluginFile $getNumPlayersRoot $gameModePath $mutated
	$regression = Invoke-Gate $getNumPlayersRoot
	Assert-True ($regression.ExitCode -eq 1) 'Logout counting the present players makes the gate fail'
	Assert-True (($regression.Output -join "`n") -match 'NETCOUNT-R1') 'the gate names the GetNumPlayers() regression'
	Assert-True (($regression.Output -join "`n") -match 'NETCOUNT-R2') 'the gate names the missing Exiting argument'
	Write-Output 'PASS: Logout counting the present players is rejected by name'

	# NETCOUNT-R2: passing nullptr keeps the call shape but stops excluding anybody.
	$nullRoot = New-MutationRoot
	$roots.Add($nullRoot)
	$nullText = [regex]::Replace(
		$gameModeText,
		'RefreshConnectedPlayerCount\s*\(\s*Exiting\s*\);',
		'RefreshConnectedPlayerCount(nullptr);')
	Set-PluginFile $nullRoot $gameModePath $nullText
	$nullResult = Invoke-Gate $nullRoot
	Assert-True ($nullResult.ExitCode -eq 1) 'Logout that excludes nobody makes the gate fail'
	Assert-True (($nullResult.Output -join "`n") -match 'NETCOUNT-R2') 'the gate names the dropped Exiting argument'
	Write-Output 'PASS: excluding nobody is rejected by name'

	# NETCOUNT-R2: a deferred recount is a different contract than the one the plugin documents.
	$deferredRoot = New-MutationRoot
	$roots.Add($deferredRoot)
	$deferredText = [regex]::Replace(
		$gameModeText,
		'RefreshConnectedPlayerCount\s*\(\s*Exiting\s*\);',
		'GetWorldTimerManager().SetTimerForNextTick([this]() { RefreshConnectedPlayerCount(nullptr); });')
	Set-PluginFile $deferredRoot $gameModePath $deferredText
	$deferred = Invoke-Gate $deferredRoot
	Assert-True ($deferred.ExitCode -eq 1) 'a deferred recount makes the gate fail'
	Assert-True (($deferred.Output -join "`n") -match 'NETCOUNT-R2') 'the gate names the deferred recount'
	Write-Output 'PASS: deferring the recount is rejected by name'

	# NETCOUNT-R4: counting everything and subtracting the leaver afterwards under-counts a leaving
	# spectator, which was never part of the count.
	$subtractRoot = New-MutationRoot
	$roots.Add($subtractRoot)
	$surfacePath = 'Source\MulticaOnlineStarter\Private\MulticaConnectedPlayerCount.h'
	$surfaceText = [System.IO.File]::ReadAllText((Join-Path (Join-Path $subtractRoot 'templates\online\MulticaOnlineStarter') $surfacePath))
	$skipLine = 'if (Controller.bIsExiting || !Controller.bHasPlayerState || Controller.bSpectatorOnly)'
	$countLine = "`t`t`t++Players;"
	Assert-True ($surfaceText.Contains($skipLine)) 'the fixture still contains the skip condition to mutate'
	Assert-True ($surfaceText.Contains($countLine)) 'the fixture still contains the increment to mutate'
	$subtractText = $surfaceText.Replace($skipLine, 'if (!Controller.bHasPlayerState || Controller.bSpectatorOnly)').Replace($countLine, $countLine + "`r`n`t`t`tif (Controller.bIsExiting)`r`n`t`t`t{`r`n`t`t`t`tPlayers -= 1;`r`n`t`t`t}")
	Set-PluginFile $subtractRoot $surfacePath $subtractText
	$subtract = Invoke-Gate $subtractRoot
	Assert-True ($subtract.ExitCode -eq 1) 'a subtract-after-count rule makes the gate fail'
	Assert-True (($subtract.Output -join "`n") -match 'NETCOUNT-R4') 'the gate names the subtract-after-count rule'
	Write-Output 'PASS: subtracting the leaver after counting is rejected by name'

	# NETCOUNT-R5: dropping the automation test leaves the rule unasserted.
	$noTestRoot = New-MutationRoot
	$roots.Add($noTestRoot)
	Remove-Item -LiteralPath (Join-Path (Join-Path $noTestRoot 'templates\online\MulticaOnlineStarter') 'Source\MulticaOnlineStarter\Private\Tests\MulticaConnectedPlayerCountTests.cpp') -Force
	$noTest = Invoke-Gate $noTestRoot
	Assert-True ($noTest.ExitCode -eq 1) 'a missing automation test makes the gate fail'
	Assert-True (($noTest.Output -join "`n") -match 'NETCOUNT-R5') 'the gate names the missing automation test'
	Write-Output 'PASS: a missing automation test is rejected by name'
} catch {
	$suiteError = $_
} finally {
	foreach ($root in $roots) {
		if (Test-Path -LiteralPath $root -PathType Container) {
			Remove-Item -LiteralPath $root -Recurse -Force
		}
	}
}

# The cases above deliberately run the gate in its failing shape, so $LASTEXITCODE is left at 1 on a
# fully successful run. Every caller reads the exit code (CI throws when it is non-zero), so the
# suite has to state its own result explicitly instead of inheriting the last gate invocation's.
if ($null -ne $suiteError) {
	$message = $suiteError.Exception.Message
	if ($message -notlike 'ASSERT FAILED:*') { $message = "ASSERT FAILED: $message" }
	Write-Output $message
	exit 1
}

exit 0
