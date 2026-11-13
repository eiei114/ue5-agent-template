[CmdletBinding()]
param(
	[string]$RepositoryRoot
)

# Static gate for DOT-3186 / UE-NETCOUNT-001.
#
# AController::Destroyed calls AGameModeBase::Logout while the departing controller is still in the
# world's player-controller list and still owns a PlayerState (the engine's CleanupPlayerState and
# UWorld::RemoveController happen after Logout returns). Any count taken at that moment therefore
# still includes the player who is leaving, which is why the replicated connected-player count never
# fell on a client leave.
#
# This gate reads the plugin's C++ as text. It cannot prove that the code compiles or that a
# two-client session behaves correctly; it only refuses to let the shape that loses the decrement
# come back unobserved. The behaviour itself is fixed by the narrow counting surface and its
# automation test, which cannot run without a UE install.

$ErrorActionPreference = 'Stop'

$repoRootFull = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
	[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
} else {
	[System.IO.Path]::GetFullPath($RepositoryRoot)
}
$pluginRoot = Join-Path $repoRootFull 'templates\online\MulticaOnlineStarter'
$moduleRoot = Join-Path $pluginRoot 'Source\MulticaOnlineStarter'
$gameModeHeader = Join-Path $moduleRoot 'Public\MulticaOnlineGameMode.h'
$gameModeSource = Join-Path $moduleRoot 'Private\MulticaOnlineGameMode.cpp'
$countSurface = Join-Path $moduleRoot 'Private\MulticaConnectedPlayerCount.h'
$automationTest = Join-Path $moduleRoot 'Private\Tests\MulticaConnectedPlayerCountTests.cpp'

$findings = New-Object System.Collections.Generic.List[string]

function Add-Finding([string]$Rule, [string]$Message) {
	$script:findings.Add("${Rule}: $Message")
}

function Remove-Comments([string]$Text) {
	# The analysis only looks at code. A comment that explains why GetNumPlayers() must not be used
	# at Logout time is not a call, so strip line and block comments before matching.
	$withoutBlockComments = [regex]::Replace($Text, '/\*.*?\*/', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
	return [regex]::Replace($withoutBlockComments, '//[^\r\n]*', '')
}

function Get-Body([string]$Text, [string]$Signature) {
	# Returns the text between the first '{' after $Signature and its matching '}'.
	$start = $Text.IndexOf($Signature)
	if ($start -lt 0) { return $null }
	$open = $Text.IndexOf('{', $start)
	if ($open -lt 0) { return $null }
	$depth = 0
	for ($i = $open; $i -lt $Text.Length; $i++) {
		$character = $Text[$i]
		if ($character -eq '{') { $depth++ }
		elseif ($character -eq '}') {
			$depth--
			if ($depth -eq 0) { return $Text.Substring($open + 1, $i - $open - 1) }
		}
	}
	return $null
}

foreach ($path in @($gameModeHeader, $gameModeSource, $countSurface, $automationTest)) {
	if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
		Add-Finding 'NETCOUNT-S1' "expected plugin file is missing: $path"
	}
}

$headerText = if (Test-Path -LiteralPath $gameModeHeader) { Remove-Comments ([System.IO.File]::ReadAllText($gameModeHeader)) } else { '' }
$sourceText = if (Test-Path -LiteralPath $gameModeSource) { Remove-Comments ([System.IO.File]::ReadAllText($gameModeSource)) } else { '' }
$surfaceText = if (Test-Path -LiteralPath $countSurface) { Remove-Comments ([System.IO.File]::ReadAllText($countSurface)) } else { '' }
$testText = if (Test-Path -LiteralPath $automationTest) { Remove-Comments ([System.IO.File]::ReadAllText($automationTest)) } else { '' }

$logoutBody = Get-Body $sourceText 'void AMulticaOnlineGameMode::Logout'
$countBody = Get-Body $sourceText 'int32 AMulticaOnlineGameMode::CountConnectedPlayers'

# NETCOUNT-R1: the plugin must not ask the engine for "who is present right now" on either path.
# At Logout time that answer still contains the leaving player, so a count routed through it can
# never publish the post-leave value, whichever function happens to call it.
if ($sourceText -match 'GetNumPlayers\s*\(') {
	Add-Finding 'NETCOUNT-R1' 'the plugin still counts the present players with GetNumPlayers(), which includes the controller that is leaving'
}
if ($sourceText -match 'GetNumSpectators\s*\(') {
	Add-Finding 'NETCOUNT-R1' 'the plugin derives the count from GetNumSpectators(), which is taken at the same moment the leaving player is still present'
}

# NETCOUNT-R2: the leave path must publish the count in the same call, driven by the Exiting
# argument. Waiting for engine removal (a timer, a tick, or the GameState PlayerArray being rebuilt
# later) is a different contract and is not what this plugin ships.
if ($null -eq $logoutBody) {
	Add-Finding 'NETCOUNT-R2' 'Logout is not defined in Private/MulticaOnlineGameMode.cpp'
} else {
	if ($logoutBody -notmatch 'RefreshConnectedPlayerCount\s*\(\s*Exiting\s*\)') {
		Add-Finding 'NETCOUNT-R2' 'Logout does not pass its Exiting controller to RefreshConnectedPlayerCount(Exiting)'
	}
	if ($logoutBody -match 'SetTimer|SetTimerForNextTick|GetWorldTimerManager|RegisterTick|PlayerArray') {
		Add-Finding 'NETCOUNT-R2' 'Logout defers the recount to a later tick instead of publishing the post-leave value in this call'
	}
}

# NETCOUNT-R3: the count is taken by skipping the leaving controller before it is counted, not by
# counting everything and subtracting one afterwards. Subtracting would go negative when a
# spectator-only controller leaves, because that controller was never added to the count.
if ($null -eq $countBody) {
	Add-Finding 'NETCOUNT-R3' 'CountConnectedPlayers is not defined in Private/MulticaOnlineGameMode.cpp'
} else {
	if ($countBody -notmatch 'MulticaConnectedPlayerCount\s*::\s*CountPlayers\s*\(') {
		Add-Finding 'NETCOUNT-R3' 'CountConnectedPlayers does not delegate the rule to MulticaConnectedPlayerCount::CountPlayers'
	}
	if ($countBody -notmatch 'ExcludedController') {
		Add-Finding 'NETCOUNT-R3' 'CountConnectedPlayers ignores its excluded controller, so the leaving controller is still counted'
	}
}

# NETCOUNT-R4: the narrow surface has to keep the engine predicate (PlayerState present, not
# spectator-only) and skip the leaving controller instead of counting it.
if ([string]::IsNullOrWhiteSpace($surfaceText)) {
	Add-Finding 'NETCOUNT-R4' 'Private/MulticaConnectedPlayerCount.h is missing'
} else {
	if ($surfaceText -notmatch 'bIsExiting' -or $surfaceText -notmatch 'bSpectatorOnly' -or $surfaceText -notmatch 'bHasPlayerState') {
		Add-Finding 'NETCOUNT-R4' 'the counting surface no longer states the exiting / spectator-only / PlayerState inputs'
	}
	$countPlayersBody = Get-Body $surfaceText 'inline int32 CountPlayers'
	if ($null -eq $countPlayersBody) {
		Add-Finding 'NETCOUNT-R4' 'MulticaConnectedPlayerCount::CountPlayers is not defined'
	} else {
		if ($countPlayersBody -notmatch 'bIsExiting') {
			Add-Finding 'NETCOUNT-R4' 'CountPlayers does not skip the exiting controller'
		}
		if ($countPlayersBody -notmatch 'bSpectatorOnly' -or $countPlayersBody -notmatch 'bHasPlayerState') {
			Add-Finding 'NETCOUNT-R4' 'CountPlayers no longer applies the engine predicate (PlayerState present, not spectator-only)'
		}
		if ($countPlayersBody -match '-=|--\s*Players|Players\s*--|Players\s*-\s*1') {
			Add-Finding 'NETCOUNT-R4' 'CountPlayers adjusts the total after counting instead of skipping the leaving controller, which under-counts when a spectator leaves'
		}
	}
}

# NETCOUNT-R5: the rule must stay covered by an automation test, including the leave case that
# regressed. The test cannot run without UE; the gate only refuses to ship the rule untested.
if ([string]::IsNullOrWhiteSpace($testText)) {
	Add-Finding 'NETCOUNT-R5' 'Private/Tests/MulticaConnectedPlayerCountTests.cpp is missing'
} else {
	if ($testText -notmatch 'WITH_DEV_AUTOMATION_TESTS') {
		Add-Finding 'NETCOUNT-R5' 'the player-count test is not behind WITH_DEV_AUTOMATION_TESTS'
	}
	if ($testText -notmatch 'Multica\.Online\.PlayerCount') {
		Add-Finding 'NETCOUNT-R5' 'the player-count test does not register under Multica.Online.PlayerCount'
	}
	foreach ($required in @('MakeExitingPlayer', 'MakeExitingSpectator', 'CountPlayers')) {
		if ($testText -notmatch [regex]::Escape($required)) {
			Add-Finding 'NETCOUNT-R5' "the player-count test does not exercise $required, so the leave case is unasserted"
		}
	}
}

# NETCOUNT-R6: the header must still declare the exclusion-taking private helpers; a plugin that
# silently drops them would compile a count that cannot exclude the leaving controller.
if ($headerText -notmatch 'RefreshConnectedPlayerCount\s*\(\s*const AController\*') {
	Add-Finding 'NETCOUNT-R6' 'the GameMode header no longer declares RefreshConnectedPlayerCount with an excluded controller'
}
if ($headerText -notmatch 'CountConnectedPlayers') {
	Add-Finding 'NETCOUNT-R6' 'the GameMode header no longer declares CountConnectedPlayers'
}

if ($findings.Count -gt 0) {
	foreach ($finding in $findings) { Write-Output "FAIL: $finding" }
	exit 1
}

Write-Output 'PASS: the leave path publishes the count with the leaving controller excluded, keeps the engine player predicate, and that rule is covered by an automation test'
exit 0
