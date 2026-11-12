# 変更履歴

## Unreleased — DOT-3229

- `scripts/New-UETemplateScaffold.ps1` の `Read-TemplateDefs` が `TemplateDefs.ini` の区切り文字の空白に依存していたのを直した。`FolderRenames` の `From=` / `To=` の間と `Extensions=(` / `MountName="` の直後に、任意個の空白・タブを許容する。
  - 実測: 本hostの実 install `UE_5.8`（`Engine/Build/Build.version` = 5.8.4 / CL 58902052）の `Templates/*` 34本のうち `Config/TemplateDefs.ini` を持つ32本を読み、うち**15本**が `FolderRenames=(From="…", To="…")`（カンマ直後に空白）形式で書いている。`Source/` を持つ spaced 形式の template は `TP_Blank` と `TP_SIM_Blank` の2本で、`TP_Blank` を `materialize_project: true` の recipe で実体化すると、宣言された改名規則が**無言で捨てられ**、`.uproject` が宣言する module 名と `Source/` の実ディレクトリ名が食い違った tree を exit 0 で出力していた（`aa11370`）。
  - 変更は**受理する形式を増やすだけで、既存の受理形式を狭めていない**。キー名・括弧内の照合は従来どおり PowerShell 既定の大文字小文字を区別しない比較を維持し（以前に読めた表記が今は読めない、という縮小を起こさない）、セクション見出しの外にある行も従来どおり適用する（以前に受理した file を落とさない）。
  - パターン末尾の `$` を付けた版を一度入れたが、旧 reader は `$` を持っていなかったため、`FolderRenames=(…) ; note` のように**規則の後ろに trailing text が付いた行**は旧 reader が適用していたのに新 reader が捨てるという狭小化になっていた。末尾の `$` を外して旧と同じ「規則の終わりまでで一致、後続 text は無視」に戻してある（DOT-3552 の照合で検出、test で固定）。`EditDetailLevelPreference` の値も旧どおり「閉じ引用符までの任意文字列」に戻し、`"High Quality"` のような quoted multi-word が既定値に落ちる狭小化を防いでいる（値は path の一部になるので前後の空白だけ Trim する）。
- 解釈できなかった既知キー行を無言で捨てるのを止めた。読者が適用すると称するキー（`FoldersToIgnore` / `FilesToIgnore` / `FolderRenames` / `ReplacementsInFiles` / `SharedContentPacks` / `EditDetailLevelPreference`）で、かつ \[/Script/GameProjectGeneration.TemplateProjectDefs\] セクション内にある行が規則を作らなかった場合、**警告して run を継続**する（停止ではなく警告を選んだ理由: 実 engine template には本 reader が未実装のキーや書式が残っており、停止にすると install 済み template を丸ごと拒否してしまう。「行が黙って捨てられる」ことを成功にしないのが本質で、誤った tree を出す歯止めは次項の不変条件検査が担う）。警告には file path と行番号・行内容を含める。
  - `FilenameReplacements` は警告対象に**含めない**。同キーの実装要否は materialization 忠実性の別 issue（DOT-3135）が持つ層で、ここでは適用も報告もしない（二重実装しない）。
- test を両形式で回すようにした。`scripts/Test-UETemplateScaffold.ps1` は `", To="` 形式と `",To="` 形式の `FolderRenames` を1つの fixture に同居させ、両方で `Source/<ProjectName>/<ProjectName>.Build.cs` へ改名されること、`Source/` 以外の改名、spaced な `FoldersToIgnore` / `ReplacementsInFiles` / `SharedContentPacks` / `EditDetailLevelPreference` が効くこと、解釈不能な `SharedContentPacks` 行が警告になることを assert する。さらに、区切り記号を落とした `FolderRenames` 行を持つ fixture で (a) 警告が出る、(b) run が project identity 検査で**停止**する、(c) 停止 message が未一致 path を名指しすることを assert する。
  - **現行 HEAD（`8f58615`）の generator に同じ assertion を当てると落ちる**ことも記録した（下記「修正前後の実測」）。
- 生成後の不変条件検査は既存の `Get-ScaffoldIdentityReport`（DOT-3041 で着地済み、`.uproject` の `Modules[].Name` と `Source/<Name>/<Name>.Build.cs` の双方向照合）を再利用し、重複実装していない。DOT-3135 の完了条件 2/3 と重なる層も同じ検査を再利用する。

### `TemplateDefs.ini` の受理形式（本変更後の契約）

| 項目 | 受理する形 |
|---|---|
| セクション | `[Section]` 行で切り替え。規則の適用は従来どおり全セクション。警告の報告だけを `[/Script/GameProjectGeneration.TemplateProjectDefs]` に限定 |
| 区切り | `=` の前後、`(` の直後、`,` の前後、`)` の直前に任意個の空白・タブ |
| `FolderRenames` | `(From="…", To="…")` / `(From="…",To="…")` / `( From = "…" , To = "…" )`。規則の後ろに trailing text が付いた行も旧どおり適用する |
| `ReplacementsInFiles` | `(Extensions=("cpp","h"))` / `( Extensions = ( "cpp" , "h" ) )` |
| `SharedContentPacks` | `(MountName="X",DetailLevels=(…))` / `( MountName = "X" , … )` |
| `EditDetailLevelPreference` | `"High"` / `High` / `= "High"`（前後の空白つき）。quoted な複数語の値も旧どおり受理 |
| 解釈不能な既知行 | 警告（`TemplateDefs.ini rule was not understood …`）を出して run を継続。生成物が実際に壊れていれば project identity 検査が非 0 で停止する |

本契約は Epic の `TemplateDefs.ini` 文法仕様に**基づかない**。公式 docs は `LocalizedDisplayNames` / `LocalizedDescriptions` / `Categories` しか記述しておらず、区切り空白の許容可否は公開されていない。根拠は「本hostの実 install の template が実際にその形式で書いており、本 repo の解析器がそれを捨てていた」ことだけである。

### 修正前後の実測（本host、Windows 10.0.26300、`pwsh 7.6.9` と Windows PowerShell 5.1.26100.9711）

- 改造前 `aa11370` の generator + 実 install `TP_Blank`（`", To="` 形式、`Source/` あり）を `materialize_project: true` の recipe で実行: `exit 0` / `Created Probe_a …`、`.uproject` `Modules[0].Name = Probe`、`Source/TP_Blank/Probe.Build.cs`。module 名の合わない tree を成功として出す。
- 変更後、同じ実 install `TP_Blank` で同じ実行: `exit 0` / `Source/Probe/Probe.Build.cs`（`Source/TP_Blank/` は残らない）。
- 現行 HEAD `8f58615`（DOT-3041 の identity 検査あり）で spaced fixture を実行: project identity 検査が未一致 path を列挙して**停止**（`Source/TP_SpacedRenames/…` と `Modules[].Name "Probe"` の双方を報告）。`aa11370` は同じ fixture で `exit 0` の壊れた tree を出した。
- `scripts/Test-UETemplateScaffold.ps1`: 変更後 `pwsh 7.6.9` と Windows PowerShell 5.1 の双方で 10 group PASS / exit 0（既存 7 group + 新規 2 group + 既存の最終 group）。`aa11370` に同じ suite を当てると新規 group で落ちる。

### 移行

既存 project / `Production/` の生成物には触れない。過去に `", To="` 形式の template から生成した project（例: `TP_Blank` 由来で `Source/TP_<Template>/` が残るもの）は、`.uproject` の module 名と `Source/` が食い違っているので**新しい RunId で生成し直す**か、`Source/<Template>/` を `Source/<Module>/` へ手で合わせるかを案件ごとに選び、QA に記録する。本変更は generator と test と本書に閉じ、`.uproject` の identity 契約（DOT-3041）と lock の shape は変えていない。

Unverified: UE の install 操作 / 起動 / compile / Editor / PIE / cook / MRQ / render / Shipping は実行していない。`Source/Probe/Probe.Build.cs` + `.uproject Modules[0].Name = "Probe"` の tree を UE / UBT が読んだときの挙動、UE ウィザードが `", To="` 形式を受理するか、タブ区切り・行末コメント・引用符なし等他の書式変種、UE 5.8.4 以外の版の同梱 template の書き方は未確認。

## Unreleased — 動画モーキャプ

- `docs/09-video-mocap.md` を追加した。単眼のダンス動画から MediaPipe で体・手・顔の点を取り、VRM の骨の回転 → VRMA → UE（VRM4U）→ MV にする工程、単眼で取れない量の補い方、確認方法、1 本での実測、残る限界、権利の gate をまとめた。
- 図は工程図・棒人間・腰の高さのグラフだけで、元動画・キャラの画像は入れていない。スクリプトは非公開の制作 repo にあり、本 repo には同梱しない。

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
