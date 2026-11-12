# 変更履歴

書式: 各 `## ` 見出しは `## Unreleased — <DOT番号 or 名前> — <識別子>` の形にする。**識別子は必須**で、`YYYY-MM-DD`（main に入った merge commit の日付。`git log -1 --date=short --format=%cd <merge>` か `gh pr list --state merged` の `mergedAt`）または 40 桁 commit SHA のどちらかを書く。日付だけでは「どの変更か」を commit に結べないので、SHA を併記してよい（併記した SHA は `git cat-file -e <sha>^{commit}` で解決できること）。release も tag も作らないので全節が `Unreleased` のまま。各節の本文には、次を 1 項目ずつ残す:

1. 何が変わったか（推測で書かず、差分から読む）
2. 移行が必要か（必要なら何をするか。不要なら「移行不要」と書く）
3. Unverified Scope（実行していない検証を成功と読ませない）

読み取り経路は `README.md` の「入口」表と `AGENTS.md` の「先に読む」。`scripts/Test-UETemplateDocs.ps1` が、route の到達性（C1）と見出し識別子（C2）を検査する。識別子は日付だけを必須にし、SHA は書かれたときだけ解決を検査する。`.github/workflows/verify.yml` の checkout が `fetch-depth: 1` で、古い merge commit の SHA は解決できないため（日付は shallow clone でも常に読める）。

## Unreleased — DOT-3454 — 2026-11-12

- `CHANGELOG.md` は tracked file から一度も参照されておらず（`git grep -c 'CHANGELOG' -- ':!CHANGELOG.md'` = 0 件）、`README.md` の「入口」表にも `AGENTS.md:5` の「先に読む」にも無かった。`docs/07-architecture.md` が要求する「変更理由・移行手順・検品結果を残す」記録の唯一の置き場が読まれない状態だったので、両方から名指すようにした。
- 見出し 5 個（当時）がすべて `Unreleased — <DOT番号 or 名前>` で、40 桁 SHA も ISO 日付も無かったため、「どの版の話か」を機械的に決められなかった。全節へ識別子を付与し、書式をこのファイル冒頭の「書式」段落に固定した。
- 未記録だった merge 済み delivery 5 件（`DOT-3029` / `UE-CI-002` / `DOT-3313` / `DOT-3317` / `DOT-3340`）の節を追加した。既存 5 節の本文は削っていない。
- `scripts/Test-UETemplateDocs.ps1`（新規）で C1（`CHANGELOG.md` が `README.md` の入口表と `AGENTS.md` の「先に読む」から名指されていること）と C2（各 `## ` 見出しが 40 桁 SHA か ISO 日付を持つこと、本文が空でないこと、指定 delivery の節が消えていないこと）を検査する。負例 6 通り（削除 / route 行除去 / 識別子除去 / 解決しない SHA / `AGENTS.md` route 除去 / 節の消失）が path を名指しして落ち、復旧で沈黙することを同じ suite で確認する。`.github/workflows/verify.yml` に `docs-route` job を追加した。

移行: repo 側の文書と test だけ。既存 project・`Production/`・`Out/` の生成物は触らない。識別子の日付は各 merge の日付で、値は書き換えも再生成もしない。

Unverified Scope: 「エージェントが実際に `CHANGELOG.md` を読んで移行判断を誤らなくなるか」は観測していない。本件の主張は「route から到達できない・見出しに識別子が無い・削除しても検査が落ちない」という機械的事実に限る。UE 5.8.4 の起動 / compile / Editor / PIE / MRQ / render は実行していない。本件以降に main へ入った delivery（`DOT-3397` / `DOT-3398` / `DOT-3399` / `DOT-3400` 以降の PR）は本件の範囲外で、節が無いまま。`Test-UETemplateDocs.ps1` の `requiredSections` に個別列挙しているため、新規 delivery を列挙に加えないと「節の消失」は検出できない。

## Unreleased — 動画モーキャプ — 2026-11-12

- `docs/09-video-mocap.md` を追加した。単眼のダンス動画から MediaPipe で体・手・顔の点を取り、VRM の骨の回転 → VRMA → UE（VRM4U）→ MV にする工程、単眼で取れない量の補い方、確認方法、1 本での実測、残る限界、権利の gate をまとめた。
- 図は工程図・棒人間・腰の高さのグラフだけで、元動画・キャラの画像は入れていない。スクリプトは非公開の制作 repo にあり、本 repo には同梱しない。

## Unreleased — DOT-3395 — 2026-11-09

- 画像列QA helperは、`FramesDirectory`またはreport親pathにjunction/symlink等のreparse pointが含まれる場合に、実効出力境界を確認できないため検査前に拒否する。reportがjunction経由で画像列へ書き込まれるのを防ぐ回帰fixtureを追加した。
- `docs/05-qa.md`に、report先と検査対象はreparse pointを含まない通常のpathを使う契約を明記した。

## Unreleased — DOT-3295 — 2026-11-09

- `templates/online/MulticaOnlineStarter` had **no module implementation** (`IMPLEMENT_MODULE`). UE 5.8.4 loaded the DLL and then failed the plugin (`ロード後にモジュール 'MulticaOnlineStarter' の初期化に成功しなかったためプラグイン 'MulticaOnlineStarter' のロードに失敗しました`), so neither `Multica.Online.Session.DeferredDestroyCleanup` nor `Multica.Online.SessionIdentity` could register or run. Added `Private/MulticaOnlineStarter.cpp` using `FDefaultGameModuleImpl`.
- `MakeDestroyCleanupOperations` passed `const FDelegateHandle&` to `IOnlineSession::ClearOnDestroySessionCompleteDelegate_Handle`, which takes a non-const `FDelegateHandle&`; UE 5.8.4 rejects that with `error C2664`. The operation surface now takes the handle by value (`TFunction<void(FDelegateHandle)>`) and hands the provider a mutable copy; the test double matches it.
- The deferred-cleanup automation test bound its weak-lambda lifetime marker to `NewObject<UObject>()`. `UObject` is `UCLASS(Abstract)`, so that trips `Ensure condition failed: Class which was marked abstract was trying to be loaded in Outer /Engine/Transient` and fails the test. The marker now uses a concrete `UMulticaOnlineTestLifetimeMarker` declared in `Private/Tests/MulticaOnlineTestLifetimeMarker.h`.

Measured on this host (Windows, UE 5.8.4 CL 58902052, MSVC 14.44): `TP_FirstPersonEditor Win64 Development` `Result: Succeeded` (41 actions). `UnrealEditor-Cmd ... -ExecCmds="Automation RunTests Multica.Online"` → `Test Completed. Result={Success} Name={DeferredDestroyCleanup}` and `Result={Success} Name={SessionIdentity}`, `**** TEST COMPLETE. EXIT CODE: 0 ****`. `scripts/Test-UETemplateScaffold.ps1` 8 groups PASS / exit 0. PIE, two-client Null/LAN, and EOS/Steam were still not exercised.

## Unreleased — DOT-3254 — 2026-11-08

- `scripts/Test-UERenderArtifacts.ps1` の最終group（旧: `$finalCheck -notmatch 'frames-mutated'`）は恒真assertだった。`frames-mutated` はrepo全体にこのassert自身しか存在せず、fixtureにその名前のfileを作る処理も無かったため、fixtureを壊しても12/12 PASS・exit 0で通っていた。恒真assertを削除し、**実比較**に置き換えた。
- suiteが作るfixtureディレクトリは、構築直後に全file名・SHA256をbaselineとして登録する。末尾のgateは17ディレクトリすべてを再snapshotして比較し、追加・削除・内容変更をpathで名指しして落とす。`reports/`だけはsuiteが意図的に書くので比較対象から外し、代わりに「割り当てたreport path数 = 実在する非空`.json`数（意図的に拒否した分を除く）」を照合する。fixture root直下も既知entry以外を不正とする。
- **落ちる側のtest**を追加した（group 12）。使い捨てfixtureを「削除・書き換え・追加」の3通りで壊し、gateが3件ともpath付きで報告すること、復旧後は沈黙することをassertする。gate自体が空assertへ戻ればこのgroupが落ちる。
- suite末尾の「checkout unchanged」が ignored な残骸を見ていなかった。`.gitignore:2` の `Production/*` により `git status --porcelain --untracked-files=all` は `Production/` 配下を一切報告しないため、`Production/` に残ったfixtureやreportは検出されなかった。両suiteで `Production/` の実ディレクトリを直接列挙し、`PLACEHOLDER.md` の欠落と、そのsuite自身の命名（`.render-artifacts-test-*` / `.scaffold-test-*` と scaffold test出力名、過去runのものを含む）に一致する今回run以外のentryを残骸として落とすようにした（suite開始前とcleanup後とで2回確認する）。開発者が生成した `Production/<Name>_<runid>/` や他suiteの実行中entryではsuiteを止めない。
- 失敗時のcleanupも直した。assertで落ちてもfixture削除・残骸確認・checkout比較を必ず実行し、元のassert失敗を先に表示してから再throwする。
- `docs/05-qa.md` の「処理の前後でfixture/画像列のhashが変わらないことを確認する」を、実際に確認している主体（helperではなく回帰suite）と範囲（suiteが作った17のfixtureディレクトリ全体 + `reports/` + `Production/`）へ合わせた。

修正前後の実測（本host、`pwsh 7.6.9`、fixtureを3ディレクトリ壊す同一のmutationを注入）：修正前は `EXIT=0` / `PASS: 12行` で通過。修正後は `EXIT=1` で `ASSERT FAILED: fixture inputs changed during the suite: clean240/000000.png : removed; swap240/MUTATED.txt : added; corrupt/000001.png : content changed; STRAY-ROOT.txt: unexpected entry in the fixture root` とpathを名指しして落ちる。clean tree では 13 group PASS・exit 0（11の既存group + 新gate 2 group）、`scripts/Test-UETemplateScaffold.ps1` は 8 group PASS・exit 0。

移行: 既存projectと`Production/`の生成物には触れない。本変更はhelperを呼ぶ側のtest harnessと文書に閉じる。`Measure-UERenderArtifacts.ps1` の判定ロジック（decode/timeoutの優先順位・総予算）は変更していない。GitHub Actions `windows-latest` 上でのmutation検出は本変更のCI実行で確認する（本hostの実測ではない）。

## Unreleased — DOT-3366 — 2026-11-09

- `spectator-explore` scaffold now writes a stable `MulticaOnlineStarter.SessionProjectIdentifier` derived from `-ProjectName` and records it in `template-lock.json`. Null/LAN search joins only a session advertising that same identifier; missing or malformed settings fail explicitly instead of sharing the engine template name.
- The switch moved from the plugin's `Config/DefaultEngine.ini` to the **generated project's** `Config/DefaultEngine.ini`, together with `[OnlineSubsystem] DefaultPlatformService=Null`. Measured on UE 5.8.4 with `-dumpiniloads`: the engine does look for `<Project>/Plugins/MulticaOnlineStarter/Config/DefaultEngine.ini`, but engine and project branches already exist for that base name and take precedence, so the plugin copy was loaded into an ignored layer — `GConfig->GetString(TEXT("MulticaOnlineStarter"), TEXT("SessionProjectIdentifier"), ..., GEngineIni)` returned nothing and `Multica.Online.SessionIdentity` failed on "the generated plugin config is visible through the active engine config". Keeping the same values in the plugin directory is a silent no-op, so the plugin ships no `Config/` directory for them.
- Follow-up after merging `origin/main` into `verify/dot3366`: the merge resolution put the
  lock-vs-project-config assertion (`different project names produce different lock identifiers`)
  on the same physical line as the preceding assert, separated only by a tab. PowerShell parsed
  that line as a single `Assert-True` call with 6 arguments, and its `[bool]` parameter coerced
  the stray string, so the lock comparison never ran while the suite still reported 8 groups
  PASS / exit 0. The two calls are separate statements again, and a probe confirms the split
  assertion now fails when the lock identifier diverges. No assertion was added or removed.
- Added scaffold assertions for same-project stability across run IDs and distinct identifiers across project names, for the project-config placement, and for the absence of a plugin `Config/DefaultEngine.ini`; plus a UE automation test for matching/mismatching and missing/invalid session identifiers. The engine fixture in `Test-UETemplateScaffold.ps1` now ships `Config/DefaultEngine.ini` like the installed templates do. `MulticaOnlineStarter` advances from 1.0.0 to 1.0.1.

Measured on this host (Windows, UE 5.8.4 CL 58902052, MSVC 14.44): `TP_FirstPersonEditor Win64 Development` `Result: Succeeded` (41 actions). `UnrealEditor-Cmd ... -ExecCmds="Automation RunTests Multica.Online"` → `Test Completed. Result={Success} Name={DeferredDestroyCleanup}` and `Result={Success} Name={SessionIdentity}`, `**** TEST COMPLETE. EXIT CODE: 0 ****`. `scripts/Test-UETemplateScaffold.ps1` 8 groups PASS / exit 0.

Migration: regenerate projects that need project-scoped Null/LAN sessions with the same `-ProjectName` on every client and verify that the generated lock and project config agree. Existing generated projects lack the key and now report an explicit failure until regenerated/configured. This does not establish two-client runtime behavior: PIE, two-client Null/LAN, EOS/Steam, and permitted runtime checks are not exercised here.

## Unreleased — DOT-2997 — 2026-11-05

- エンコード前の画像列検査を追加。`scripts/Measure-UERenderArtifacts.ps1`が期待範囲（start/end-exclusive）と実ファイルの番号集合を照合し、欠番・範囲外・曖昧名・0 byte・decode不能・解像度不一致を検出する。読み取り専用で、既存画像の改名・修復・削除をしない。
- MRQ完了通知/exit、画像列、MP4、目視、音を独立した判定に分けた。通知成功やexit 0を画像列のpassへ、画像列のpassをrender/映像/音の合格へ読み替えない。
- decoderは既存環境の`ffprobe`を任意で使う。PATHに無ければ`-DecoderPath`で既存実体を指定し、無い・失敗・timeoutは`unverified`/`fail`のまま総合passにしない。新規導入はしない。timeoutは既定10秒、deadline超過は成功へ丸めない。
- `scripts/Test-UERenderArtifacts.ps1`で自作PNG fixtureの負例を固定。240枚そろっていても1枚欠番+末尾1枚超過の列をfailにすること、先頭/中間/末尾欠番、241枚目、桁数/拡張子の揺れ、0 byte、切り詰め・payload破損、解像度不一致、decoder不在/失敗/timeoutを確認する。
- 根拠：Epic公式Image Settings（frame offset/handle/frame step/終端排他を設定できる＝枚数だけで期待連番を決めない、2026-11-02参照）とFFmpeg公式（`-frames:v`は出力上限であり元画像列の整合性検査ではない）。いずれも当該hostの実測ではない。

移行: 新しいRunIdの`Out/run_<runid>/evidence/`へ検査reportを新規作成し、既存の作品・`Out`・画像列・MP4を上書きしない。旧runの画像列を対象にする場合は、所有権を照合してから新規出力先へreportだけを書く。UE実機のMRQ/ffprobe・render成功・映像/音/loopの実測は未検証（Unverified）。fixture成功はUE5.8.4動作確認ではない。

## Unreleased — third-person-game recipe — 2026-11-04

- 公式`TP_ThirdPerson`（C++・Combat/Platforming/SideScrolling variant同梱）を起点にする`third-person-game` recipeを追加。
- recipeの`materialize_project: true`で、テンプレート自身の`Config/TemplateDefs.ini`（FoldersToIgnore / FilesToIgnore / FolderRenames / ReplacementsInFiles / SharedContentPacks）をUEウィザードと同じ規則で適用し、`<ProjectName>.uproject`・`Source/<ProjectName>`・`<PROJECTNAME>_API`へ実体化。共有content pack（Characters等）も`Content/`へ入れ、`/Script/TP_*`のCoreRedirectとProjectID/ProjectNameを書く。
- 実体化するrecipeではProjectNameをC++識別子に制限。既存2 recipeの出力は変更なし。

移行: 既存projectは再生成しない。三人称の新作だけ`-Recipe third-person-game`で新RunIdから生成し、Editor build・Playは作品側QAで記録する。

## Unreleased — DOT-3041 — 2026-11-05

- project identity契約を1つに固定した。`materialize_project: true`のrecipe（`third-person-game`）は`<Name>.uproject` / `Modules[].Name = <Name>` / `Source/<Name>`、生コピーの2 recipeは`TP_FirstPerson.uproject` / `TP_BlankBP.uproject`のまま。どちらも`.uproject`の`Modules[].Name`と`Source/<Module>/<Module>.Build.cs`が一致していることを契約とする。`EngineAssociation`は`Build.version`から導いて必ず非空。`AGENTS.md:40`の`.uproject`記述、`docs/01-start.md`の「生コピー禁止」記述、starter README、`README.md`、`docs/07-architecture.md`を同じ契約へ揃えた。
- `scripts/New-UETemplateScaffold.ps1`はコピー前に`.uproject`の`Modules[].Name`と`Source/`のmodule directoryを照合し、既知パターンに一致しない場合は**停止**して未一致pathを列挙する。生コピーを黙って出力しない。コピー後にも同じ照合をコピー物同士で行う（materializeするrecipeはmodule rename後に照合）。`EngineAssociation`を明示設定し、project identityを`template-lock.json`の`identity`（`schema_version: 2`）に記録する。
- `scripts/Test-UETemplateScaffold.ps1`のfixtureは実在形式の`Modules`と`Source/**`を持つ。追加assertionはprojectファイル名、`Modules[].Name`、非空`engine_association`、lockの`identity`、および置換不能時にgeneratorが停止する負例。

### 移行（重要）

- **既存の生成済みprojectはrenameしない。** 旧generatorが出した`TP_FirstPerson.uproject` / `TP_BlankBP.uproject`は名前の点では新契約と同じで、違うのは空の`EngineAssociation`とlockのshapeだけ。renameはどちらも直さない。ファイル名だけ変えると`Modules[].Name`は`Source/**/[Module].Build.cs`を指したままになり、改名後のprojectは自分のlockが記録した`identity.project_file`と一致しなくなる。
- 新契約が必要な作品は**新しいRunIdで再生成**し、`template-lock.json`（`schema_version: 2`の`identity`）と作品差分を旧版と比較してから採用する。既存`Production/<Name>_<runid>/`と`Out/`を上書き・再生成しない。
- 旧lock（`schema_version: 1`）はidentityを持たないので、`identity`の有無で新旧を判別する。旧lockを手で書き換えない。
- `EngineAssociation`が空のまま生成済みのprojectは、Editorで開く前に`.uproject`の`EngineAssociation`を手で埋めるか、新RunIdで生成し直す。どちらを取ったかを案件のQAに記録する。
- UE compile / PIE / Editor / MRQ は引き続きUnverified Scope。本変更はgenerator・test・docsの共通基盤に限る。

## Unreleased — DOT-2959 — 2026-11-02

- 共通setを一つだけ使う鑑賞・探索（プレイ＋撮影）と、映像専用縦ループの2 recipeを追加。
- インストール済みUE公式project templateから新規projectを排他的に作るPowerShell generatorと、UE/plugin version・recipe/use・作品差分・template commitのlock記録を追加。
- Null/LAN用のserver-authoritative replication/session starter plugin、公式source付き方式比較、失敗/timeout手順を追加。

移行: template checkoutをcleanにし、新しいRunIdのscaffoldを生成する。`template-lock.json`と作品差分を比較してから手動で採用し、既存の生成project/Production/Outを再生成・上書きしない。EOS/Steamにはprovider固有実装、認証、service利用条件、実測を揃えるまで切替えない。

## Unreleased — DOT-3029 — 2026-11-05

- 生成物の project identity がリポジトリ自身の契約と一致していなかった不具合（PR#2、merge `a7bda3fd8396115d6e91570dba36b81c7bcbabbc`）。`AGENTS.md` は `<Name>.uproject` と書いていたのに generator は template 名の `<EngineTemplate>.uproject` を出し、`EngineAssociation` は空のままで、test fixture が `Modules: []` だったために全件 PASS していた。修正内容は `DOT-3041` の節（同一 PR）にまとめた。本節はその delivery が変更履歴に現れていなかったことの記録。
- 本件で増えた検査は、`Source/` を欠く identity で generator が停止すること、`EngineAssociation` が非空であること、lock の `identity` が実ファイルと一致することの 3 点。どれも以前は assert が無かった。

移行: 本文の `DOT-3041` 節と同じ。既存の生成済み project は rename せず、新契約が必要な作品は新 RunId で再生成する。

Unverified Scope: UE 5.8.4 の compile / PIE / Editor / MRQ は実行していない。fixture は合成 Engine で、実 UE install での生成ではない。

## Unreleased — UE-CI-002 — 2026-11-05

- リポジトリに CI が 1 本も無かった（`.github/workflows` は 404）ため、どの PR も success check を持たず merge gate に到達できなかった。`.github/workflows/verify.yml`（PR#4、merge `857b3264413f8992fda6149e1a2d3e3391c6762e`）を追加し、`windows-latest` で既存の 2 suite を回すようにした。
- `render-artifacts` job は decode=pass の assert に実 decoder が必要なので `choco install ffmpeg` で `ffprobe` を用意し、`scaffold` job は generator が自分の checkout を clone するため `fetch-depth: 1` のまま通ることを確認して入れた。
- 当時の記録では workflow は Actions 上で未実行だった。現在は main への push と各 PR で success を観測できる（本節の追記時点）。

移行: repo の中身は変わらず、PR の merge gate に check が付くだけ。既存の生成 project / `Production/` / `Out/` への影響なし。

Unverified Scope: 本 workflow が担保するのは PowerShell 2 suite の green だけ。UE compile / PIE / Editor / MRQ / render / ffprobe の意味での映像正しさは別判定のまま。

## Unreleased — DOT-3313 — 2026-11-08

- `spectator-explore` の生成物が `Recipe/Play.md` から `docs/08-online-foundations.md` を案内していたのに、生成 project にその文書を同梱していなかった（案内先が生成物内で解決しない）。generator が同梱するようにし、`Play.md` の参照先が解決すること、同梱コピーが repo の原本と一致することを `scripts/Test-UETemplateScaffold.ps1` で assert した（PR#7、merge `752864baf8383405729427595274d7e705538a9e`）。
- この suite が文書の存在を見るのは、この generator がコピーする 1 本だけ。他の `docs/*.md` と `templates/*.md` の存在は検査されていない。

移行: 生成済みの `spectator-explore` project には同梱文書が無い。同じ Name/RunId を上書きせず、新 RunId で生成し直すか、`docs/08-online-foundations.md` を生成物の `docs/` へ手で複製する（どちらを取ったかを案件の QA に記録する）。

Unverified Scope: UE 5.8.4 の起動 / compile / PIE / MRQ / render、二台 LAN の実接続は実行していない。文書同梱と参照解決だけの検査。

## Unreleased — DOT-3317 — 2026-11-08

- `docs/01-start.md` が「First Person C++ を全 recipe の前提」のように読ませていた。recipe ごとの起動経路（`spectator-explore`=`TP_FirstPerson`、`vertical-loop`=`TP_BlankBP`、`third-person-game`=`TP_ThirdPerson`）を表にし、用途・scaffold の identity（`materialize_project` の有無）・必須 plugin を並べ、Project Browser の手動作成を「script が使えない場合の fallback」へ下げた（PR#8、merge `5bd2e5815462a030e418c9a0f8674fef00c01389`）。
- 手動 fallback の生成物は recipe 文書・plugin payload・`template-lock.json` を欠くので、scaffold 生成物と同等と見なさないことを明記した。

移行: 読み方の変更だけで、生成物は変わらない。手動で作った既存 project を scaffold 生成物と同一視していた場合は、recipe / template / UE 版 / 確認した identity を `QA.md` に記録し直す。

Unverified Scope: 文書と recipe JSON / generator `ValidateSet` の静的照合だけ。UE 5.8.4 での生成・Editor build・PIE・LAN は実行していない。

## Unreleased — DOT-3340 — 2026-11-08

- `AGENTS.md` のセッション切断時復旧が、Computer Use 機能だけで画面操作を試みられる書き方になっていた。復旧を「Computer Use 機能」と「対象 host / project への既存の許可済み画面経路」の両方を確認できた場合に限定し、どちらかが欠ける場合は操作を試したと書かず、確認結果・不足・未実施操作と理由・保存版・次の許可済み手順を記録して停止するとした（PR#9、merge `34f2cbb61c8e43901325376ea7c69cb9555f9e32`）。

移行: 運用文書の変更のみ。新規認証・権限設定・代替接続・他 writer の終了は引き続き禁止で、既存 gate は変わらない。

Unverified Scope: 画面経路と Computer Use の両方が使える状況での復旧実操作は実行していない。本件以降の `DOT-3399` が同じ節を再度締め直している。
