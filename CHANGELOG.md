# 変更履歴

## Unreleased — DOT-3090

- 公開前の公開面監査を実装した。`scripts/Test-UETemplatePublishSurface.ps1` は **index を正本**（`git ls-files -z`）とし、`generation-output`（`Production/` `Out/` `Art/` `Saved/` `Binaries/` `Intermediate/` `DerivedDataCache/`、`Production/PLACEHOLDER.md` だけ許可）/ `distribution-binary`（`.bundle` `.7z` `.exe` `.dll` `.pdb` `.uasset` `.mp4` 等）/ `credential`（`auth.json` `.env*` `id_rsa` `*.pem` 等）のpath形状規則を**監査器自身がcase-insensitiveに持つ**。終了コードは0=通過 / 1=検出あり / 2=監査不能。`throw` を使わず `FAIL:` / `WARN:` / `SUMMARY:` を1行1件で出す。
- なぜ `git status` 目視・`git check-ignore` 突き合わせ・`.gitignore` だけで足りないかを、fixtureで固定した。commit済みの `.bundle` / `.exe` / `.7z` は status 0行・check-ignore は3件とも not-ignored・`^(Production|Out)/` grep 該当なしで**3通りともPASS**する。強制追加した `auth.json` をworktreeから消すと status は `D auth.json` に見え check-ignore も not-ignored を返すが、indexに残り fresh clone に載る。
- `git ls-files -ci --exclude-standard`（追跡済み かつ exclude pattern 一致）を補助信号として `tracked-ignored` 区分で併記する。**判定には使わない。** 同じindexで `OUT/x.txt` `SAVED/a` `ART/a` `PRODUCTION/Proj/TP.uproject` を追跡した場合、本host（`core.ignorecase=true`）は4件、`core.ignorecase=false`（Linux runner相当）は0件を返すため、`.gitignore` の一致判定に委ねると runner ごとに結論が変わる。
- pathに改行を含む追跡物は `git ls-files`（改行区切り）では分割されて壊れる。監査器は `-z` で読む。fixture `Prod\nuction/secret.bundle` で、plain `git ls-files` が1レコードとして返さないことと、監査が `FAIL: distribution-binary: Prod\nuction/secret.bundle` として1行で報告することをassertする。
- 受入2（fresh clone のリンク/placeholder漏れ）を実行可能な検査にした。tracked `.md` のリンクを index と**ordinal比較**で解決し、未追跡・別caseのみ・リポジトリ外へ出る・tracked entryの無いディレクトリを `link` として落とす。`Production/PLACEHOLDER.md` がindexに無ければ `placeholder` で落とす。
- `git add -A` で公開面に入る未追跡物は fail ではなく `WARN:`（`untracked` / `untracked-*`）で報告する。
- `scripts/Test-UETemplatePublishSurface.Tests.ps1` を追加。workdir配下（`Production/.publish-surface-test-<id>/`）に使い捨てgit repoを作り、12 group をassertする。clean repo の PASS、commit済みbinary/exe/archive、強制追加credential、生成projectと`Out/`、改行path、`core.ignorecase` 両方向、リンク4種、未追跡WARN、placeholder欠落、**規則を1つ消した監査器では該当fixtureがPASSに戻る**こと（恒真assertでないことの固定）、開発checkoutの `git status` 不変。suite終了時に自分のfixtureだけを削除し、過去runの残骸は `Production/` 実列挙で検出する。
- `docs/06-delivery.md` の公開前点検と受入2を、自然文の目視から**実行コマンド＋pass/fail条件**へ置換した。`SUMMARY: tracked=<n> fail=0` と exit 0 がpass、`FAIL: <区分>: <path>` が出る exit 1 がfail、exit 2（worktreeでない・indexが空・pathに `"`）は**pass扱いにしない**。exit 2 の追加は「監査を実行できなかった」を「問題なし」と読ませないため。
- `.gitignore` に `*.bundle` `*.7z` `*.rar` `*.tar.gz` `*.tgz` `*.exe` `*.dll` `*.pdb` `*.lib` `*.so` `*.dylib` `*.psd` `*.mov`、および未網羅だった資格情報形状（`secrets.json` / `secrets.yaml` / `token.json` / `service-account.json` / `id_rsa` / `id_ed25519` / `id_ecdsa` / `id_dsa` / `.netrc` / `_netrc` / `.npmrc` / `.pypirc` / `client_secret*` / `api-token.txt` / `GH_TOKEN` / `keystore` / `.htpasswd` / `*.p12` / `*.pfx` / `*.jks` / `*.p8` / `*.ppk`）を追加した。**監査の判定は `.gitignore` に依存させない**（上記の case 依存のため）。冒頭に「このfileは未追跡物しか止めない、公開可否の正本は監査器」と明記した。

検証（本host、Windows 11 10.0.26300、`pwsh 7.6.9` と Windows PowerShell 5.1.26100.9711、git 2.55.0.windows.5）：`Test-UETemplatePublishSurface.Tests.ps1` = 12 group PASS / exit 0（両shell）。`Test-UETemplatePublishSurface.ps1 -RepoRoot <this checkout>` = exit 0 / `SUMMARY: tracked=50 fail=0 warn=2`（warnは本turnで未追跡の2 file）。`Test-UETemplateScaffold.ps1` = 8 group PASS / exit 0（両shell、回帰なし）。`Test-UERenderArtifacts.ps1` = 13 group PASS / exit 0（回帰なし）。実行前後の `git status --porcelain --untracked-files=all` は本変更の4 pathのみで、suite由来の差分は0。

移行: 既存の生成物・`Production/`・`Out/` には触れない。公開判定の根拠を「目視」から「`Test-UETemplatePublishSurface.ps1` の exit code」へ移す。`.gitignore` の拡張は未追跡物の抑制だけで、追跡済みの禁止物は `git rm --cached` しない限り公開面に残る（監査はそれを `FAIL` で報告する）。UE compile / PIE / Editor / MRQ / render は本件で一切実行していない（この変更は UE 非依存、Unverified Scope）。

## Unreleased — DOT-3042

- `docs/01-start.md` は lease プロトコルを「実装要件。スクリプト未同梱」と宣言したままで、排他的 mkdir と `LEASE.json` の CreateNew 相当を各エージェントの手作業に委ねていた。`New-Item -Force` や `Set-Content` で代替した生成物は別 run の active lease を黙って上書きして「成功」として通る。
- `scripts/Lease-UETemplateProject.ps1` を追加した。`Acquire` / `Release` / `Test` の3動作で、出力先 dir の排他的作成は generator と同じ P/Invoke `CreateDirectoryW` + Win32 183 判定、`LEASE.json` の書き込みは `[IO.File]::Open($path, CreateNew, Write, None)` のみ。`Set-Content` / `WriteAllText` / `Out-File` / 一時ファイル rename は使わない（rename は他所の active lease を置換できる）。既存 dir への取得は「生成と取得の区別」として継続し、`Test` は読み取りだけで書き込み・mtime 更新をしない。
- lease のフィールドは `docs/01-start.md` の列挙（run ID / issue ID / host / project realpath / 取得日時 / nonce / writer phase / PID）に固定し、余分な field を持つ記録は読み取り時に拒否する。`Release` は run/nonce 不一致・記録欠落・receipt 既存のいずれでも停止し、`LEASE.json` を消さない。`Test` は 0=active / 1=free / 2=unknown を返し、`free`（記録は残存・手動照合要）と `unknown`（記録なし/読めない/他 host）を混同しない。
- `scripts/Test-UETemplateLease.ps1` を追加した。既存 dir への取得成功・再取得拒否と byte 一致保持・他所 run lease の保持・script 本文の静的検査（非排他書き込み経路が無いこと）・8 プロセス同時取得で勝者1/敗者7と記録が勝者一致・nonce/run 不一致 Release の停止・Release 成功後の `LEASE_RELEASED` と `LEASE.json` 削除・`Test` 前後の content/size/mtime 不変・記録欠落/破損/他 host の `unknown`・文書と AGENTS/QA/CHANGELOG の参照一致を assertion 化した。既存 `Test-UETemplateScaffold.ps1` は変更していない。
- `.github/workflows/verify.yml` に `Test-UETemplateLease.ps1` を実行する `lease` job を追加した（既存 2 job は変更なし）。

**落ちる側（変更前 `8f58615` の repo 本文＋新しい suite）**: `scripts/Test-UETemplateLease.ps1` は変更前 HEAD に存在しないため新 assertion 群は必ず失敗する。実測では新 suite 2 本の script だけを変更前 HEAD の worktree へ置くと 10 PASS の後 `ASSERT FAILED: docs/01-start.md names the shipped lease script` で exit 1になる。

**検証（本 host, Windows, `powershell 5.1.26100.9711` と `pwsh 8` の両方）**: `scripts/Test-UETemplateLease.ps1` → 11 PASS 行 / exit 0。`scripts/Test-UETemplateScaffold.ps1` → 8 group PASS / exit 0（既存 group は不変）。両 suite とも fixture を `Production/` 内の `.lease-test-<id>` に作り、cleanup 後に残骸 0・`git status --porcelain --untracked-files=all` 差分 0 を再確認している。

**Unverified Scope**: UE 実機（compile / PIE / MRQ / Shipping）は実行していない。本変更は UE を起動しない PowerShell 層のみで、実 UE 5.8 系 install を `-ProjectDirectory` にした実 project 生成は未実行。

## Unreleased — 動画モーキャプ

- `docs/09-video-mocap.md` を追加した。単眼のダンス動画から MediaPipe で体・手・顔の点を取り、VRM の骨の回転 → VRMA → UE（VRM4U）→ MV にする工程、単眼で取れない量の補い方、確認方法、1 本での実測、残る限界、権利の gate をまとめた。
- 図は工程図・棒人間・腰の高さのグラフだけで、元動画・キャラの画像は入れていない。スクリプトは非公開の制作 repo にあり、本 repo には同梱しない。

## Unreleased — DOT-3187

- `templates/online/MulticaOnlineStarter` の provider 設定は、engine が読まない名前の carrier に置かれていた。旧 `Config/DefaultEngine.ini` は UE 5.8.4 の plugin config loader が `{PLUGIN}/Config/{TYPE}.ini`（既存 branch を変更する layer）にも `{PLUGIN}/Config/Default<PluginName>.ini`（plugin 自身の branch）にも解決できず、`ConfigCacheIni.cpp:7275` で `DefaultEngine` という branch 名を作った後 `:7294-7301` で Verbose ログだけ残して捨てる。`[OnlineSubsystem] DefaultPlatformService=Null` は宣言だけが残り、`GEngineIni` には届いていなかった。
- 旧 `scripts/Test-UETemplateScaffold.ps1` は生成物の `Plugins/MulticaOnlineStarter/Config/DefaultEngine.ini` の**本文**に `DefaultPlatformService=Null` が含まれることだけを見ており、carrier 名が解決されるかを検査していなかった。そのため carrier 名を `Engine.ini` に変えても `DefaultEngine.ini` のままでも同じく PASS し、6 群 PASS / exit 0 のまま出荷されていた。
- plugin の carrier を廃止し、provider/session 設定の唯一の置き場所を**生成 project の `Config/DefaultEngine.ini`**（`{PROJECT}/Config/Default{TYPE}.ini`、`Misc/ConfigHierarchy.h:68`）に固定した。plugin は `Config/` を同梱しない。
- test の plugin 検査を**本文文字列一致から carrier 名の解決規則**へ置き換えた。既知 branch（`Engine`/`Game`/`Input`/…、`Misc/ConfigCacheIni.h:101-111`）と plugin branch（`Default<PluginName>`）に解決する名前だけを受理し、plugin 配下の ini が 1 本でも未解決名なら停止する。project 側 carrier も `Default{TYPE}.ini` / `{PLATFORM}{TYPE}.ini` の形を検査する。負例（plugin 側 `Config/DefaultEngine.ini`、project 側 `Config/Engine.ini`）を fixture として固定し、解決できる名前（`Config/Engine.ini`・`Config/Default<PluginName>.ini`・`Config/Windows/WindowsEngine.ini`）は受理することを同じ group で assert する。
- `templates/online/MulticaOnlineStarter/README.md` は、編集すべきファイル（生成 project の `Config/DefaultEngine.ini`）と carrier 名の契約、`LoadDefaultSubsystem` が未設定・ロード失敗時に `NULL_SUBSYSTEM` へ fallback すること（`OnlineSubsystemModule.cpp:205-221`）を明示する。`docs/08-online-foundations.md` の実装節と検証履歴も同じ内容へ揃えた。
- `MulticaOnlineStarter` の C++ 挙動、generator のコピー経路・materialize 経路、`templates/recipes/**` は変更していない。

Measured on this host (Windows 10.0.26300, Windows PowerShell 5.1.26100.9711, pwsh 7.6.9): `scripts/Test-UETemplateScaffold.ps1` 9 groups PASS / exit 0。DOT-3187 の carrier 検査を `aa113700b0ce4d2bbe32dbb7bd2bdec91d5531d0` の実 tree（`Plugins/MulticaOnlineStarter/Config/DefaultEngine.ini` のみ）へ当てると `the engine cannot resolve 'DefaultEngine.ini' to a config branch` で落ち、変更後は 0 件。`-dumpiniloads` / `LogConfig` Verbose による実ログ取得、Editor 上での `DefaultPlatformService` 実効値、PIE・2-client LAN・EOS/Steam は未検証（Unverified Scope）。

移行（重要）: **既存の生成済み project は自動変換しない。** 旧 scaffold が出した `Plugins/MulticaOnlineStarter/Config/DefaultEngine.ini` は engine に読まれない（`Test-UETemplateScaffold.ps1` のcarrier 検査を `aa11370` の実 tree へ当てると 1 件で落ちる）。必要な作品は**新しい RunId で再生成**するか、project 自身の `Config/DefaultEngine.ini` に `[OnlineSubsystem] DefaultPlatformService=Null` を書いて採用理由と日付を作品の QA に残す。旧ファイルを `Config/Engine.ini` へ改名して済ませる運用は、plugin modification layer として `Engine` branch に届くかどうかを未完のまま使うため、本 PR では勧めない（実測は `-dumpiniloads` の別 receipt とする）。

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
