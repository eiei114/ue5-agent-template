# 少人数オンライン基盤の方式比較

調査・照合日: 2026-11-01 (JST)。UE公式ページはUE 5.8 documentationを参照。料金・provider契約は利用時に再確認する。公式仕様、費用の推定、当hostの実測は混ぜない。

## 比較と採用方針

| 方式 | 初期費用/アカウント | service利用枠 | host運用費 | NAT・招待・認証・SDK | 判断 |
|---|---|---|---|---|---|
| Unreal replication + listen server + Null/LAN | LAN試作は外部service account不要。追加料金を前提にしない | 第三者session backendを使わない。service quotaを主張しない | player hostのPC・電力・LAN/ISP帯域は必要。host終了でsessionも終了 | Null + IP net driverでLAN探索/joinを開始。インターネット越しのNAT traversal、アカウント、platform inviteは解決しない。firewall/portを別確認 | **最初の実測経路**。同じLANの少人数に限定 |
| Epic Online Services (EOS) | Epic Developer Portalのproduct/client構成、選択するidentity/entitlementの設定が必要。secretはplaceholder以外をrepoへ入れない | 今回参照したUE EOS integration docsは料金/利用上限の契約値を示さない。無料枠や無期限無料を保証しない。採用時にEpicの現行terms/usage上限を確認 | listen hostの稼働PC/ISP費は残る。EOS使用料と運用費を分けて見積もる | EOS pluginはproject/product設定とSDK/online configに依存。P2P/NATや招待を含む成功は別ネットワーク・資格情報で実測が必要 | crossplay/service adapter候補。今回のコードはEOS接続を実装・試験していない |
| Steam sessions/lobbies | Steamworks登録と利用者のSteam account/clientが必要 | 参照したinterface docsからservice利用quota/従量料金は確定しない。別ホスト費は別途 | listen hostのPC/ISP費は残る。dedicated serverを立てる場合はその費用も別 | Steam OSS plugin/SDK/AppIDと各セッション設定が必要。Steam docsはlobbiesとlisten/dedicated serverを説明。NAT/relay成功は実ネットワークで別検証 | Steam配信/Steam identityが必要な作品向けadapter候補。今回は実装・接続なし |

### 費用を混同しない

- **Null/LAN**では外部session providerの課金を使わないが、プレイヤー側PC、電力、ISP契約/帯域、継続稼働は無料と限らない。
- **EOS**の利用料/上限は今回のUE統合ガイドだけから定量化できない。Epicの最新Developer Portal契約と対象serviceの上限を採用前に確認し、未確認のまま「無料」と書かない。
- **Steam Direct Fee**はSteamで製品を配布する際の別費用。公式記載は1 appあたり **US$100**、通常は返金不可だがSteam Store/in-appのAdjusted Gross Revenueが**US$1,000**以上になった後の支払でrecoup可能。LAN試作/EOS利用料とは別であり、Steam sessionを試すだけで製品をSteam配布する承認にもならない。
- dedicated server、relay、voice/chat、hosting、bandwidth、支払/税務、anti-cheatはこの表の「listen server」費に含まない。各サービスと対象地域の現行条件を確認する。

## 小さな実装

`templates/online/MulticaOnlineStarter`はUE Online Subsystem interfaceを使うC++ plugin scaffold。generatorがgame-and-capture recipeにだけコピーし、`DefaultPlatformService=Null`を設定する。

- `AMulticaOnlineGameMode`はserver authorityでjoin/leave人数を更新。pluginはglobal GameModeを強制しない。mapに採用する場合はproject固有PawnとPlayerStartを別途設定し、標準GameModeのserver-owned restartを使う。clientからspawn ownerを決めさせない。
- `AMulticaOnlineGameState`はsample scoreと接続数をreplicate。`AMulticaOnlinePlayerController`上のowned Server RPCが入力を範囲検証し、serverだけがscoreを変更する。
- `UMulticaOnlineSessionSubsystem`はLAN session create/find/join/leaveをasyncに呼び、拒否・空検索・join失敗・connect string不足・bounded timeoutを通知する。host mapに`?listen`を付けてtravelする。
- timeout時にprovider operationがまだ完了していない可能性がある。遅れて成功したcreate/joinはcleanupを試み、新しいoperationを受けずcleanupを待つ。timeoutは接続成功/安全に解放できた証拠ではない。
- pluginはmap、PlayerStart、入力asset、UI、Sequence、`.uasset`を作らない。起動mapと操作を作品側で設定する。`Plugins/MulticaOnlineStarter/README.md`に手順を記載。
- implementationはNull/LAN用。EOS/Steam configを差し替えただけでは検証済みadapterにならない。Auth、crossplay、internet NAT、invitesを支えるprovider固有実装と実測は別途必要。

## 公式一次資料

- Epic, [Networking and Multiplayer in Unreal Engine](https://dev.epicgames.com/documentation/en-us/unreal-engine/networking-and-multiplayer-in-unreal-engine) — server/client、replication、sessionの概説。
- Epic, [Online Subsystem in Unreal Engine](https://dev.epicgames.com/documentation/en-us/unreal-engine/online-subsystem-in-unreal-engine) — online interfaceとsessionsの責務。
- Epic, [Online Subsystem Sessions Interface](https://dev.epicgames.com/documentation/en-us/unreal-engine/online-subsystem-sessions-interface-in-unreal-engine) — create/find/join/destroyの非同期session interface。
- Epic, [Online Subsystem EOS Plugin](https://dev.epicgames.com/documentation/en-us/unreal-engine/online-subsystem-eos-plugin-in-unreal-engine) — UE plugin、product/identity、crossplay設定。
- Epic, [Online Subsystem Steam Interface](https://dev.epicgames.com/documentation/en-us/unreal-engine/online-subsystem-steam-interface-in-unreal-engine) — Steam sessions/lobbies、listen/dedicated serverとSteam SDK設定。
- Valve, [Steam Direct Fee](https://partner.steamgames.com/doc/gettingstarted/appfee) — per-app distribution feeとrecoup condition。

UE docs describe capability and configuration, not this project's connection success, account entitlement, cost ceiling, internet NAT, or product license. Official EOS/Steam quota/price values were not proven here. Null/LAN successとinternet successは別のテストとして記録する。

## 検証履歴

| 実施日 (JST) | 対象 | 結果 | 制約 |
|---|---|---|---|
| 2026-11-01 | Windows host preflight / installed UE / plugins | UE 5.8.4とNull/EOS/Steam OSS plugin filesを確認。認証済みEOS/Steam accountやinternet sessionを試していない | インストール存在はcompile/PIE/NAT成功を示さない。今回の正確なbuild/PIE結果は最終Issue commentとQA記録を参照 |
| 2026-11-01 | UE Editor target compile（`TP_FirstPersonEditor Win64 Development`） | PASS。UE 5.8.4 / CL 58902052、MSVC 14.44 + Windows SDK 10.0.22621、37 actions、58.62秒。TP_FirstPersonとMulticaOnlineStarterのC++をcompile/link | 260文字path制限に対してcheckoutを一時Q: driveに割り当てて実行。これはEditor buildでありPIE/ゲーム動作の合格ではない |
| 2026-11-01 | 2プロセスNull/LAN standalone接続probe | Unverified。23.9秒のprobeでUE game processを2つ起動したが、world/NetDriver listeningに到達せず、connect assertionなし。ログにあったTrace control portの`listening`はgame listenerではない。shared project shader/DDC初期化が続いた。所有processと一時Q: mappingを回収 | PIEの2-client、session create/find/join/leave、score/player-count replication、disconnect/reconnect、MRQ/ffprobe/visualは未検証。UI automationなしでPIEを実測したとは扱わない |
| 2026-11-01 | `scripts/Test-UETemplateScaffold.ps1` | PASS。game+capture/official template/plugin/deterministic lock、capture-only recipe、path traversal拒否、既存出力保護の4 assertion groups | 合成Engine fixtureでのgenerator test。実UE assets/Editor map生成の検査ではない |
| 2026-11-02 | CodeRabbit指摘の追加修復（scaffold test の detached HEAD 対応 / dirty fixture の generator 差し替え / completion handler の GameSessionName filter） | PASS。`scripts/Test-UETemplateScaffold.ps1` は通常 checkout と `git checkout --detach` の両方で 5 assertion groups が PASS。UE Editor target compile は短縮 path `C:\uev\Dot2959verify` で exit 0、37 actions、94.22秒 | 2026-11-02 実行分の記録。2-client PIE・session create/find/join/leave・replication・MRQ/ffprobe/visual は引き続き未検証であり、compile成功をゲーム動作の合格とは扱わない |
| 2026-11-02 | project identity契約（`.uproject`名 / `Modules[].Name` / `EngineAssociation` / lock `identity`）と、置換不能時に停止する負例 | PASS。`scripts/Test-UETemplateScaffold.ps1` は7 assertion groups PASS（Windows PowerShell 5.1）。`a9e31bc` のgeneratorに同じassertionを当てると `generated project descriptor has a non-empty EngineAssociation` で失敗。2 recipeの実生成物で`.uproject`名・`Modules[].Name`・`engine_association=5.8`・lock `identity` を確認 | 合成Engine fixture（`Build.version` 5.8.4/CL 58902052、`Templates/TP_FirstPerson`・`TP_BlankBP`、4つのengine plugin）での記録。実UE install・compile・Editor・MRQは未検証（Unverified Scope） |

本表の2026-11-01 Editor build行が記録した**260文字path制限**は、checkoutを一時`Q:` driveへ割り当てることで回避した実障害である。同じ障害を新しい生成物で再発させないため、`scripts/New-UETemplateScaffold.ps1` は生成前に最長pathを予算（既定260文字）と比較し、超過時は**何も作らずに停止**する。手順と根拠は [着手手順](01-start.md#パス長の予算) を参照。UE buildの`Intermediate/`・`*.obj`はgeneratorの出力ではなく、この検査はそれらを測らない。上表の既存記録は当時の実行条件であり、書き換えない。
