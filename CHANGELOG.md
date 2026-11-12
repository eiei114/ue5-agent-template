# 変更履歴

## Unreleased — DOT-3157

- 生コピー経路（`materialize_project`を持たない`spectator-explore` / `vertical-loop`）がtemplateの`Config/TemplateDefs.ini`を一度も読まず、templateフォルダを丸ごとコピーしていた。出力`Content/`に`TP_FirstPerson`の既定mapが参照する共有content pack（`Characters` / `LevelPrototyping` / `Input` / `Weapons`）が入らず、逆にignore対象の`Media/`と`Config/TemplateDefs.ini`・`Config/config.ini`が残っていた。generatorはexit 0で`Created ...`を表示し、testは6群PASSしていたため、"assetが足りない"を出力から判別できなかった。
- `scripts/New-UETemplateScaffold.ps1`のコピー実装を1つ（`Copy-TemplateTree`）に統合し、両経路とも`TemplateDefs.ini`を読むようにした。`FoldersToIgnore` / `FilesToIgnore` / `SharedContentPacks`は共通、`FolderRenames` / `ReplacementsInFiles` / `FilenameReplacements`によるrenameは`materialize_project`のrecipeだけで適用する（生コピーの2 recipeはproject名/module名をtemplate名のまま維持する契約を変えていない）。
- `SharedContentPacks`の展開は`Templates/TemplateResources/<DetailLevel>/<Mount>/Content`から`Content/<Mount>`。`EditDetailLevelPreference`のlevelに実体が無いmountは、`High` → `Standard` の順で実在するlevelを使う（実install UE 5.8.4の`TP_FirstPerson`は`Weapons`を`Standard`のみで提供している）。per-mountの`DetailLevels` tuple解釈は含まない（DOT-3135の担当）。
- 生成後検査を追加した。生成物の`Config/DefaultEngine.ini`の`GameDefaultMap` / `EditorStartupMap`が`/Game/...`を指す場合、その`.umap`が出力にあることを確認し、無ければ**停止**して欠落pathを列挙する。`/Engine/...`の宣言は出力treeの対象外として検査しない。
- `template-lock.json`に`shared_content_packs`（展開したmount名）、`shared_content_pack_detail_levels`（mount → 実展開元level）、`template_defs_ignore_rules`（適用した`FoldersToIgnore` / `FilesToIgnore`件数）を追加した。`schema_version`は`2`のまま（追加fieldのみ）。
- `scripts/Test-UETemplateScaffold.ps1`のfixture`TP_FirstPerson`に`SharedContentPacks` 3種（`Characters` / `LevelPrototyping` / `Input`）・`FoldersToIgnore=Media`・`FilesToIgnore="Config/TemplateDefs.ini"`を持たせ、`Templates/TemplateResources/High/**`に実体を置いた。assertion追加: 生コピー出力にpackが入る／`Media/`と`Config/TemplateDefs.ini`・`Config/config.ini`が入らない／lockにpack一覧とignore件数が載る。負例2件: 既定mapが`SharedContentPacks`側にしか無いfixtureではpack展開後に成功し、pack宣言を外すと**停止**する。

本host実測（Windows / `pwsh 7.6.9` / UE 5.8.4 CL 58902052、repo base `adfb5eebab9d1a3d90a60928ee31bfa35cb20b4a`）: 変更後`scripts/Test-UETemplateScaffold.ps1` = **11 group PASS / exit 0**（`pwsh`と`powershell`の両方で確認）。同じsuiteを`aa113700b0ce4d2bbe32dbb7bd2bdec91d5531d0`のgeneratorに当てると **exit 1**（`ASSERT FAILED: generated project descriptor has a non-empty EngineAssociation` — 既存のidentity契約のassertで先に落ちるため、追加assertまで届かない）。そこで追加assertと同じ観点だけを実install生成物に対して直接照合する比較を別途行い、`aa11370`は14項目すべてFAIL（pack 3種が不在、`Media/`・`Config/TemplateDefs.ini`・`Config/config.ini`が残留、lock field不在、既定mapの共有pack参照17種が1つも解決せず、既定map欠落で停止せず）、変更後は14項目すべてPASSした。実install生成物の`spectator-explore`は`Content/`に`Characters` / `LevelPrototyping` / `Input` / `Weapons`を持ち、`Media/`・`Config/TemplateDefs.ini`・`Config/config.ini`を持たない。既定map参照17種は17/17解決する。`vertical-loop`は`TP_BlankBP`がpackを宣言しないので`shared_content_packs`が空配列になり、`Media/`と`Config/TemplateDefs.ini`は入らない。

移行: **既存の生成済みprojectはコピーし直さない**（欠落packの後入れや手動修復をこの変更は行わない）。packが必要なら同じ`-ProjectName`のまま新RunIdで再生成し、`template-lock.json`の`shared_content_packs`と`identity`を読んでからEditorで開く。`Production/`の既存ディレクトリは上書きされない（排他的作成）。

未検証（Unverified）: UE Editorでの起動、既定mapを開いたときのmissing reference表示、PIE、MRQ、Shipping、パッケージ済みbuild。本変更の検証はPowerShell層のfixture回帰と実installのコピー結果までで、UE実機でmapを開いた確認ではない。

## Unreleased — DOT-3395

- 画像列QA helperは、`FramesDirectory`またはreport親pathにjunction/symlink等のreparse pointが含まれる場合に、実効出力境界を確認できないため検査前に拒否する。reportがjunction経由で画像列へ書き込まれるのを防ぐ回帰fixtureを追加した。
- `docs/05-qa.md`に、report先と検査対象はreparse pointを含まない通常のpathを使う契約を明記した。

## Unreleased — DOT-3295

- `templates/online/MulticaOnlineStarter` had **no module implementation** (`IMPLEMENT_MODULE`). UE 5.8.4 loaded the DLL and then failed the plugin (`ロード後にモジュール 'MulticaOnlineStarter' の初期化に成功しなかったためプラグイン 'MulticaOnlineStarter' のロードに失敗しました`), so neither `Multica.Online.Session.DeferredDestroyCleanup` nor `Multica.Online.SessionIdentity` could register or run. Added `Private/MulticaOnlineStarter.cpp` using `FDefaultGameModuleImpl`.
- `MakeDestroyCleanupOperations` passed `const FDelegateHandle&` to `IOnlineSession::ClearOnDestroySessionCompleteDelegate_Handle`, which takes a non-const `FDelegateHandle&`; UE 5.8.4 rejects that with `error C2664`. The operation surface now takes the handle by value (`TFunction<void(FDelegateHandle)>`) and hands the provider a mutable copy; the test double matches it.
- The deferred-cleanup automation test bound its weak-lambda lifetime marker to `NewObject<UObject>()`. `UObject` is `UCLASS(Abstract)`, so that trips `Ensure condition failed: Class which was marked abstract was trying to be loaded in Outer /Engine/Transient` and fails the test. The marker now uses a concrete `UMulticaOnlineTestLifetimeMarker` declared in `Private/Tests/MulticaOnlineTestLifetimeMarker.h`.

Measured on this host (Windows, UE 5.8.4 CL 58902052, MSVC 14.44): `TP_FirstPersonEditor Win64 Development` `Result: Succeeded` (41 actions). `UnrealEditor-Cmd ... -ExecCmds="Automation RunTests Multica.Online"` → `Test Completed. Result={Success} Name={DeferredDestroyCleanup}` and `Result={Success} Name={SessionIdentity}`, `**** TEST COMPLETE. EXIT CODE: 0 ****`. `scripts/Test-UETemplateScaffold.ps1` 8 groups PASS / exit 0. PIE, two-client Null/LAN, and EOS/Steam were still not exercised.

## Unreleased — DOT-3254

- `scripts/Test-UERenderArtifacts.ps1` の最終group（旧: `$finalCheck -notmatch 'frames-mutated'`）は恒真assertだった。`frames-mutated` はrepo全体にこのassert自身しか存在せず、fixtureにその名前のfileを作る処理も無かったため、fixtureを壊しても12/12 PASS・exit 0で通っていた。恒真assertを削除し、**実比較**に置き換えた。
- suiteが作るfixtureディレクトリは、構築直後に全file名・SHA256をbaselineとして登録する。末尾のgateは17ディレクトリすべてを再snapshotして比較し、追加・削除・内容変更をpathで名指しして落とす。`reports/`だけはsuiteが意図的に書くので比較対象から外し、代わりに「割り当てたreport path数 = 実在する非空`.json`数（意図的に拒否した分を除く）」を照合する。fixture root直下も既知entry以外を不正とする。
- **落ちる側のtest**を追加した（group 12）。使い捨てfixtureを「削除・書き換え・追加」の3通りで壊し、gateが3件ともpath付きで報告すること、復旧後は沈黙することをassertする。gate自体が空assertへ戻ればこのgroupが落ちる。
- suite末尾の「checkout unchanged」が ignored な残骸を見ていなかった。`.gitignore:2` の `Production/*` により `git status --porcelain --untracked-files=all` は `Production/` 配下を一切報告しないため、`Production/` に残ったfixtureやreportは検出されなかった。両suiteで `Production/` の実ディレクトリを直接列挙し、`PLACEHOLDER.md` の欠落と、そのsuite自身の命名（`.render-artifacts-test-*` / `.scaffold-test-*` と scaffold test出力名、過去runのものを含む）に一致する今回run以外のentryを残骸として落とすようにした（suite開始前とcleanup後とで2回確認する）。開発者が生成した `Production/<Name>_<runid>/` や他suiteの実行中entryではsuiteを止めない。
- 失敗時のcleanupも直した。assertで落ちてもfixture削除・残骸確認・checkout比較を必ず実行し、元のassert失敗を先に表示してから再throwする。
- `docs/05-qa.md` の「処理の前後でfixture/画像列のhashが変わらないことを確認する」を、実際に確認している主体（helperではなく回帰suite）と範囲（suiteが作った17のfixtureディレクトリ全体 + `reports/` + `Production/`）へ合わせた。

修正前後の実測（本host、`pwsh 7.6.9`、fixtureを3ディレクトリ壊す同一のmutationを注入）：修正前は `EXIT=0` / `PASS: 12行` で通過。修正後は `EXIT=1` で `ASSERT FAILED: fixture inputs changed during the suite: clean240/000000.png : removed; swap240/MUTATED.txt : added; corrupt/000001.png : content changed; STRAY-ROOT.txt: unexpected entry in the fixture root` とpathを名指しして落ちる。clean tree では 13 group PASS・exit 0（11の既存group + 新gate 2 group）、`scripts/Test-UETemplateScaffold.ps1` は 8 group PASS・exit 0。

移行: 既存projectと`Production/`の生成物には触れない。本変更はhelperを呼ぶ側のtest harnessと文書に閉じる。`Measure-UERenderArtifacts.ps1` の判定ロジック（decode/timeoutの優先順位・総予算）は変更していない。GitHub Actions `windows-latest` 上でのmutation検出は本変更のCI実行で確認する（本hostの実測ではない）。

## Unreleased — DOT-3366

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

## Unreleased — DOT-2997

- エンコード前の画像列検査を追加。`scripts/Measure-UERenderArtifacts.ps1`が期待範囲（start/end-exclusive）と実ファイルの番号集合を照合し、欠番・範囲外・曖昧名・0 byte・decode不能・解像度不一致を検出する。読み取り専用で、既存画像の改名・修復・削除をしない。
- MRQ完了通知/exit、画像列、MP4、目視、音を独立した判定に分けた。通知成功やexit 0を画像列のpassへ、画像列のpassをrender/映像/音の合格へ読み替えない。
- decoderは既存環境の`ffprobe`を任意で使う。PATHに無ければ`-DecoderPath`で既存実体を指定し、無い・失敗・timeoutは`unverified`/`fail`のまま総合passにしない。新規導入はしない。timeoutは既定10秒、deadline超過は成功へ丸めない。
- `scripts/Test-UERenderArtifacts.ps1`で自作PNG fixtureの負例を固定。240枚そろっていても1枚欠番+末尾1枚超過の列をfailにすること、先頭/中間/末尾欠番、241枚目、桁数/拡張子の揺れ、0 byte、切り詰め・payload破損、解像度不一致、decoder不在/失敗/timeoutを確認する。
- 根拠：Epic公式Image Settings（frame offset/handle/frame step/終端排他を設定できる＝枚数だけで期待連番を決めない、2026-11-02参照）とFFmpeg公式（`-frames:v`は出力上限であり元画像列の整合性検査ではない）。いずれも当該hostの実測ではない。

移行: 新しいRunIdの`Out/run_<runid>/evidence/`へ検査reportを新規作成し、既存の作品・`Out`・画像列・MP4を上書きしない。旧runの画像列を対象にする場合は、所有権を照合してから新規出力先へreportだけを書く。UE実機のMRQ/ffprobe・render成功・映像/音/loopの実測は未検証（Unverified）。fixture成功はUE5.8.4動作確認ではない。

## Unreleased — third-person-game recipe

- 公式`TP_ThirdPerson`（C++・Combat/Platforming/SideScrolling variant同梱）を起点にする`third-person-game` recipeを追加。
- recipeの`materialize_project: true`で、テンプレート自身の`Config/TemplateDefs.ini`（FoldersToIgnore / FilesToIgnore / FolderRenames / ReplacementsInFiles / SharedContentPacks）をUEウィザードと同じ規則で適用し、`<ProjectName>.uproject`・`Source/<ProjectName>`・`<PROJECTNAME>_API`へ実体化。共有content pack（Characters等）も`Content/`へ入れ、`/Script/TP_*`のCoreRedirectとProjectID/ProjectNameを書く。
- 実体化するrecipeではProjectNameをC++識別子に制限。既存2 recipeの出力は変更なし。

移行: 既存projectは再生成しない。三人称の新作だけ`-Recipe third-person-game`で新RunIdから生成し、Editor build・Playは作品側QAで記録する。

## Unreleased — DOT-3041

- project identity契約を1つに固定した。`materialize_project: true`のrecipe（`third-person-game`）は`<Name>.uproject` / `Modules[].Name = <Name>` / `Source/<Name>`、生コピーの2 recipeは`TP_FirstPerson.uproject` / `TP_BlankBP.uproject`のまま。どちらも`.uproject`の`Modules[].Name`と`Source/<Module>/<Module>.Build.cs`が一致していることを契約とする。`EngineAssociation`は`Build.version`から導いて必ず非空。`AGENTS.md:40`の`.uproject`記述、`docs/01-start.md`の「生コピー禁止」記述、starter README、`README.md`、`docs/07-architecture.md`を同じ契約へ揃えた。
- `scripts/New-UETemplateScaffold.ps1`はコピー前に`.uproject`の`Modules[].Name`と`Source/`のmodule directoryを照合し、既知パターンに一致しない場合は**停止**して未一致pathを列挙する。生コピーを黙って出力しない。コピー後にも同じ照合をコピー物同士で行う（materializeするrecipeはmodule rename後に照合）。`EngineAssociation`を明示設定し、project identityを`template-lock.json`の`identity`（`schema_version: 2`）に記録する。
- `scripts/Test-UETemplateScaffold.ps1`のfixtureは実在形式の`Modules`と`Source/**`を持つ。追加assertionはprojectファイル名、`Modules[].Name`、非空`engine_association`、lockの`identity`、および置換不能時にgeneratorが停止する負例。

### 移行（重要）

- **既存の生成済みprojectはrenameしない。** 旧generatorが出した`TP_FirstPerson.uproject` / `TP_BlankBP.uproject`は名前の点では新契約と同じで、違うのは空の`EngineAssociation`とlockのshapeだけ。renameはどちらも直さない。ファイル名だけ変えると`Modules[].Name`は`Source/**/[Module].Build.cs`を指したままになり、改名後のprojectは自分のlockが記録した`identity.project_file`と一致しなくなる。
- 新契約が必要な作品は**新しいRunIdで再生成**し、`template-lock.json`（`schema_version: 2`の`identity`）と作品差分を旧版と比較してから採用する。既存`Production/<Name>_<runid>/`と`Out/`を上書き・再生成しない。
- 旧lock（`schema_version: 1`）はidentityを持たないので、`identity`の有無で新旧を判別する。旧lockを手で書き換えない。
- `EngineAssociation`が空のまま生成済みのprojectは、Editorで開く前に`.uproject`の`EngineAssociation`を手で埋めるか、新RunIdで生成し直す。どちらを取ったかを案件のQAに記録する。
- UE compile / PIE / Editor / MRQ は引き続きUnverified Scope。本変更はgenerator・test・docsの共通基盤に限る。

## Unreleased — DOT-2959

- 共通setを一つだけ使う鑑賞・探索（プレイ＋撮影）と、映像専用縦ループの2 recipeを追加。
- インストール済みUE公式project templateから新規projectを排他的に作るPowerShell generatorと、UE/plugin version・recipe/use・作品差分・template commitのlock記録を追加。
- Null/LAN用のserver-authoritative replication/session starter plugin、公式source付き方式比較、失敗/timeout手順を追加。

移行: template checkoutをcleanにし、新しいRunIdのscaffoldを生成する。`template-lock.json`と作品差分を比較してから手動で採用し、既存の生成project/Production/Outを再生成・上書きしない。EOS/Steamにはprovider固有実装、認証、service利用条件、実測を揃えるまで切替えない。
