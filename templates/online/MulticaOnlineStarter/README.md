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
project file by hand, because `Source/TP_FirstPerson/TP_FirstPerson.Build.cs` and
the module descriptor would no longer agree.

`AMulticaOnlineGameMode` uses UE's server-owned default spawn/restart flow;
server-side `PostLogin`/`Logout` update the replicated player count. Bind the
GameState delegates to observe replicated changes. Configure the mode and its
project-specific Pawn, then add a map with actual `PlayerStart` actors before
claiming a spawn test. The plugin config selects Null as the session provider;
it does not impose a global GameMode on the project.

The session API is asynchronous. The helper caps its watchdog at 60 seconds.
For a create/join that completes after the watchdog, the helper reports timeout,
attempts cleanup after a late success, and rejects another operation until that
callback arrives. Provider calls that never complete require closing/restarting
the test project through its own verified cleanup path; do not infer success or
delete another run's lease.

LAN sessions advertise an identifier derived from the active UE project name;
search results with a different identifier are not joined.

The plugin's default config is Null/LAN. Do not switch it to EOS or Steam and
call this helper a working adapter: their login, product/AppID, invitation,
presence, NAT, and non-LAN session settings need provider-specific work and
tests. Never commit live EOS keys, Steam credentials, cookies, or client secrets.
