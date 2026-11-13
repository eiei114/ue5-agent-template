# Multica Online Starter (Null/LAN only)

Small redistributable C++ starting point for a new UE project. It uses the
installed engine's Online Subsystem Null provider and listen-server replication.
It includes no map, input asset, account, credential, SDK download, or licensed
asset. It is not an EOS/Steam-ready or internet-NAT-tested product.

## Enable in a new recipe project

1. Generate `spectator-explore` from a clean clone using
   `scripts/New-UETemplateScaffold.ps1`. It copies the installed
   `TP_FirstPerson` template and enables `MulticaOnlineStarter`,
   `OnlineSubsystem`, `OnlineSubsystemNull`, `OnlineSubsystemUtils`, and
   `MovieRenderPipeline` in the copied `.uproject`.
2. Open the generated `TP_FirstPerson.uproject` with the exact Engine version
   in `template-lock.json`; allow the normal project-module build. Do not install
   or download an engine/plugin to make the test pass.
3. Use the generated project map or create a new map. Place `PlayerStart`
   actors and select `AMulticaOnlineGameMode` (or a Blueprint child) for that
   map. Set the intended project Pawn on that mode; the plugin deliberately
   does not replace the `TP_FirstPerson` template's project-specific GameMode
   or Pawn. Add an owned-controller input/Blueprint call to
   `RequestSampleScoreIncrement`, or enter `MulticaRequestScoreIncrement 1`
   in the local player's console. The client RPC is sent by its owned
   `PlayerController`; only server code changes `AMulticaOnlineGameState`.
4. From a menu/Blueprint, call `HostListenServer` with the package path of the
   map selected or created in step 3 (for example, `/Game/Maps/L_Lobby`) on
   `UMulticaOnlineSessionSubsystem` on one player. On another, call
   `FindAndJoinFirstLanSession()`. Bind `OnOperationCompleted` and preserve
   failures/timeouts in the project's QA record.
5. Leave with `LeaveSession()`. Test a host, a second client, replicated
   score/player count, client leave, reconnect, failed search and timeout on a
   permitted local network. An Editor compile is not a PIE/network acceptance.

The project identity is the one defined in `AGENTS.md`: the project file keeps
the engine template name (`TP_FirstPerson.uproject`, not `<ProjectName>.uproject`),
`Modules[].Name` stays `TP_FirstPerson`, and `EngineAssociation` is never left
empty. `template-lock.json` records all three under `identity`; do not rename the
project file by hand. Renaming only the file leaves `Modules[].Name` pointing at
`Source/TP_FirstPerson/TP_FirstPerson.Build.cs`, so the renamed project no longer
matches the `identity.project_file` its own lock recorded.

`AMulticaOnlineGameMode` uses UE's server-owned default spawn/restart flow;
server-side `PostLogin`/`Logout` update the replicated player count. `PostLogin`
counts the players already registered in the world. `Logout` counts the players
that remain with the departing controller excluded: UE calls `Logout` from
`AController::Destroyed` before it removes the controller from the world's
controller list and before `CleanupPlayerState`, so a count taken at that moment
still contains the player who is leaving and the replicated value would never
fall. Both paths apply one predicate: a controller counts only while it owns a
`PlayerState` and is not spectator-only. A leaving spectator is skipped rather
than subtracted, so it cannot reduce the real player count. Bind the
GameState delegates to observe replicated changes. Configure the mode and its
project-specific Pawn, then add a map with actual `PlayerStart` actors before
claiming a spawn test. The generated project config selects Null as the session
provider; the plugin does not impose a global GameMode on the project.

The session API is asynchronous. The helper caps its watchdog at 60 seconds.
For a create/join that completes after the watchdog, the helper reports timeout,
attempts cleanup after a late success, and rejects another operation until that
callback arrives. Provider calls that never complete require closing/restarting
the test project through its own verified cleanup path; do not infer success or
delete another run's lease.

LAN sessions advertise the project-scoped identifier written by the scaffold;
search results with a different identifier are not joined. The scaffold appends
`[OnlineSubsystem] DefaultPlatformService=Null` and
`[MulticaOnlineStarter] SessionProjectIdentifier=<value>` to the generated
project's `Config/DefaultEngine.ini` using the requested `-ProjectName` (not the
engine template name or run ID), and records the same value in
`template-lock.json` as `online_session_identifier`. All clients for one project
must be generated with the same `-ProjectName`; distinct project names produce
distinct session identifiers. A missing or malformed identifier causes host and
search/join operations to fail explicitly rather than using a shared fallback.
Do not hand-edit the setting to bypass the scaffold contract.

That project file is also **the file to edit when you change the provider**:
`{PROJECT}/Config/Default{TYPE}.ini` (here `DefaultEngine.ini`) is a project layer the
engine merges into the `Engine` branch (`Misc/ConfigHierarchy.h:68`). Renaming it to
`Engine.ini` does not reach the same layer.

Config file names are part of the contract, not just their contents. A plugin config
file reaches a branch only when its name resolves to one: `Config/Engine.ini` for an
existing branch (`{PLUGIN}/Config/{TYPE}.ini`, `Misc/ConfigHierarchy.h:79`) or
`Config/Default<PluginName>.ini` for the plugin's own branch (`:61`). The loader derives
the branch name by stripping the plugin name and the platform from the file name
(`Engine/Source/Runtime/Core/Private/Misc/ConfigCacheIni.cpp:7275`); a name that matches
no known branch (`Engine`, `Game`, `Input`, … — `Misc/ConfigCacheIni.h:101-111`) is found
on disk, logged only at `Verbose`, and then discarded (`ConfigCacheIni.cpp:7294-7301`).
A file named `Config/DefaultEngine.ini` is exactly that case: `DefaultEngine` is not a
branch. The plugin therefore ships no `Config/` directory, and
`scripts/Test-UETemplateScaffold.ps1` checks the resolved carrier names (of the generated
project config and of the plugin directory) rather than grepping file bodies.

Null is also what you get when nothing is configured: `LoadDefaultSubsystem` falls back to
`NULL_SUBSYSTEM` when no provider is set or the configured one fails to load
(`Engine/Plugins/Online/OnlineSubsystem/Source/Private/OnlineSubsystemModule.cpp:205-221`).
An unread provider line therefore still yields Null, so "Null is in effect" is not evidence
that the setting was read. Check the carrier name and the value before claiming a switch.

Migration: projects generated before this contract carry
`Plugins/MulticaOnlineStarter/Config/DefaultEngine.ini`, which the engine never resolves to a
branch. Nothing rewrites them automatically — regenerate with a new RunId, or write
`[OnlineSubsystem] DefaultPlatformService=Null` into the generated project's
`Config/DefaultEngine.ini` and record that in the project's QA notes. Renaming the old file to
`Config/Engine.ini` would turn it into a plugin modification layer, but that path is not verified
here, so it is not the recommended migration.

The plugin has no EOS/Steam switch. Do not point it at EOS or Steam and
call this helper a working adapter: their login, product/AppID, invitation,
presence, NAT, and non-LAN session settings need provider-specific work and
tests. Never commit live EOS keys, Steam credentials, cookies, or client secrets.
