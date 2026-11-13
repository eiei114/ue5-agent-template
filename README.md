# UE5 Agent Production Template

AIが短い映像または小さな鑑賞シーンを安全に作るための**文書・運用テンプレート**。
最初に [AGENTS.md](AGENTS.md)、次に [着手手順](docs/01-start.md) を読む。過去の変更と移行手順は [変更履歴](CHANGELOG.md)。

## 現在の範囲

- UE5.8系の既存制作から手順を抽出。UE本体、Room Seven、Fab、Splice、Mixamo、NCSの素材実物は含まない。
- 生成器はインストール済みUE公式`TP_FirstPerson` / `TP_BlankBP` / `TP_ThirdPerson` project templateから新規`.uproject`を排他的に作成し、`Production/.stage-<runid>-<nonce>/`で完成させてから単一renameで`Production/<Name>_<runid>/`へ**atomicに公開**する。途中失敗は部分出力を残さず、`template-lock.json`が無いディレクトリは未完成として扱う。3 recipeともtemplate自身の`Config/TemplateDefs.ini`を読み、`FoldersToIgnore` / `FilesToIgnore`を適用して`SharedContentPacks`を`Content/<Mount>`へ展開する。`spectator-explore` / `vertical-loop`はtemplateのprojectファイル名と`Modules[].Name`を維持し（生コピー経路）、`third-person-game`はfolder/name/file replacementまで適用して`<ProjectName>.uproject`と同名moduleへ置換する（materialize経路）。`EngineAssociation`は必ず非空で、生成後のidentityと共有content pack一覧は`template-lock.json`に記録する（詳細は[構造と更新](docs/07-architecture.md)）。ソースrepoにはEngine由来Contentや`.uasset`を含めない。

- 生成器はインストール済みUE公式`TP_FirstPerson` / `TP_BlankBP` / `TP_ThirdPerson` project templateから新規`.uproject`を排他的に作成する。3 recipeともtemplate自身の`Config/TemplateDefs.ini`を読み、`FoldersToIgnore` / `FilesToIgnore`を適用し、`SharedContentPacks`を`Templates/TemplateResources/<DetailLevel>/<Mount>/Content`から`Content/<Mount>`へ展開する（mountごとの`DetailLevels`宣言を優先し、実体が無ければ`EditDetailLevelPreference` → `High` → `Standard` の順にfall backし、fall backしたことを警告する）。`spectator-explore` / `vertical-loop`はtemplateのprojectファイル名と`Modules[].Name`を維持し（生コピー経路）、`third-person-game`は`FolderRenames` / `FilenameReplacements` / `ReplacementsInFiles`まで適用して`<ProjectName>.uproject`と同名moduleへ置換する（materialize経路）。ファイル名のrenameは`FilenameReplacements`、本文の置換は`ReplacementsInFiles`で、それぞれ独立した`Extensions`と`From` / `To` / `bCaseSensitive`で判定する。`LocalizedDisplayNames`等のwizard metadataは適用できず、警告して継続後、`template-lock.json`の`template_defs`に適用/未適用キーを記録する。`EngineAssociation`は必ず非空で、生成後のprojectファイル名・module名・`EngineAssociation`・展開した共有content pack一覧も同lockに記録する（詳細は[構造と更新](docs/07-architecture.md)）。ソースrepoにはEngine由来Contentや`.uasset`を含めない。
- `scripts/New-UETemplateScaffold.ps1`は共通set契約・recipe・`template-lock.json`を加える。実際のmap/Sequence/作品Contentは出力しない。
- Null/LAN用の小さなC++ plugin scaffoldを同梱する。UE版ごとのbuild/PIE/MRQ結果はQAに記録し、未検証範囲を実装済み/検証済みと混同しない。
- 追加インストール・課金・公開・Git pushは自動化しない。

## 入口

| 項目 | 読むもの |
|---|---|
| 新規制作・lease・ホスト | docs/01-start.md |
| Pi起動とeffort | docs/02-runtime.md |
| Fab/Splice | docs/03-assets.md |
| Windows Shipping / Mac工程 | docs/04-package.md |
| MP4 / 視覚・音声・Play検品 | docs/05-qa.md |
| 納品・Git公開 | docs/06-delivery.md |
| 実績と未確認点 | docs/PROVENANCE.md |
| 構造・recipe・lock更新 | docs/07-architecture.md |
| 少人数online方式・費用・制約 | docs/08-online-foundations.md |
| 動画モーキャプ（MediaPipe → VRMA → UE） | docs/09-video-mocap.md |
| 変更履歴・移行手順（過去の変更と移行の記録） | CHANGELOG.md |

`templates/` は雛形であり編集しない。`templates/QA.md` を複製して `Production/.runs/run_<runid>/preflight.md` と `LEASE.json` を作り、生成後は `Production/<Name>_<runid>/Out/run_<runid>/` へ移して記入する。生成先 `Production/<Name>_<runid>/` の中には生成前に書かない（配置の正本は [AGENTS.md](AGENTS.md) と [docs/01-start.md](docs/01-start.md)）。
`Production/` は生成先の空プレースホルダ。通常Gitには制作物を入れない。`Production/.runs/run_<runid>/` は生成前の preflight と lease の台帳で、こちらも `.gitignore` の対象。

`templates/` の記録を新規制作の `Out/run_<runid>/` へ複製して記入する。納品セットの正本と各項目の配置先は[納品](docs/06-delivery.md)の表。`Out/run_<runid>/README.md`（操作表）は`templates/README.md`から作る。
`Production/` は生成先の空プレースホルダ。通常Gitには制作物を入れない。

## 新規scaffold

cleanなtemplate checkoutと既存UE installを指定し、同じName/RunIdの出力がないことを確認してから実行する。
template repoのclone先は**短い絶対path**にする（例`C:\gh\ue5-agent-template`、24文字）。generatorは`Production/<Name>_<RunId>/`を含む生成予定treeの最長pathを実行前に計算し、既定`-MaxPathLength 260`を超えると**何も作らずに停止**する。成功時は`Path budget: longest planned path ...`の1行を出力し、超過時は「実測値・超過分・clone先を浅くする具体案」を返す（[着手手順](docs/01-start.md#パス長の予算)）。

```powershell
.\scripts\New-UETemplateScaffold.ps1 `
  -Recipe spectator-explore `
  -ProjectName EmberWatch `
  -RunId ([guid]::NewGuid().ToString()) `
  -EngineRoot 'C:\Program Files\Epic Games\UE_5.8' `
  -ProjectDiff 'Shared map: /Game/EmberWatch/Maps/L_Environment'
```

映像専用は`-Recipe vertical-loop`を選ぶ。三人称ゲーム（アクション・探索・街）は`-Recipe third-person-game`で、`<ProjectName>.uproject`／`Source/<ProjectName>`へ名前を置換した状態で生成する（ProjectNameはC++識別子）。`spectator-explore`と`vertical-loop`はtemplateを生コピーするのでprojectファイル名はtemplate名のまま（`TP_FirstPerson.uproject` / `TP_BlankBP.uproject`）で、`<ProjectName>.uproject`にはならない。`-Recipe`に指定できる値は`templates/recipes/`配下で`recipe.json`を持つディレクトリ名で、generatorに一覧を直書きしていないので、ジャンルrecipeの追加はデータ（`recipe.json`・`Capture.md`・任意の`Play.md`）を置くだけでよい（手順は[構造と更新](docs/07-architecture.md)の「recipeを追加する手順」）。

どのrecipeでも、出力`Content/`にはtemplate自身が宣言した共有content packが入る（`spectator-explore`なら`TP_FirstPerson`の`Characters` / `LevelPrototyping` / `Input` / `Weapons`）。既定mapが参照するassetを出力に持たない構成は成立しないので、`.uproject`ではなく`Config/DefaultEngine.ini`の`GameDefaultMap` / `EditorStartupMap`が`/Game/...`を指す場合は、その`.umap`が出力に存在することを生成時に確認する。無ければgeneratorは**停止**し、欠落pathを列挙する。生成後の`template-lock.json`で`identity.project_file` / `identity.project_modules` / `identity.engine_association`、`shared_content_packs`、`template_defs_ignore_rules`、作品差分、`.uproject`のplugin設定を確認してからEditorで開く。templateのdescriptorと`Source/`が一致しない場合、generatorは生コピーを出さず停止する。更新で既存作品を再生成/上書きしない。

映像専用は`-Recipe vertical-loop`を選ぶ。三人称ゲーム（アクション・探索・街）は`-Recipe third-person-game`で、`<ProjectName>.uproject`／`Source/<ProjectName>`へ名前を置換した状態で生成する（ProjectNameはC++識別子）。`spectator-explore`と`vertical-loop`はtemplateを生コピーするのでprojectファイル名はtemplate名のまま（`TP_FirstPerson.uproject` / `TP_BlankBP.uproject`）で、`<ProjectName>.uproject`にはならない。どちらの場合も生成後の`template-lock.json`で`identity.project_file` / `identity.project_modules` / `identity.engine_association`、作品差分、`.uproject`のplugin設定を確認してからEditorで開く。templateのdescriptorと`Source/`が一致しない場合、generatorは生コピーを出さず停止する。更新で既存作品を再生成/上書きしない。

`template-lock.json`の`template_repository` / `template_source_kind` / `template_commit` / `template_commit_published`は、生成に使ったcheckoutの実測provenanceである。`template_commit_published`が`true`でない限り、そのlockは「lockが名指しするrepoから同じtemplateを取得できる」ことを保証しない。既定の生成はその状態で停止し、通すには`-AllowUnpublishedTemplate`（lockに実測の`false`/`null`を残す）または`-SkipTemplatePublishCheck`（probeせず`null`）を明示する。契約の詳細は[構造と更新](docs/07-architecture.md)。

パス長に注意: 上の例の出力folder名は`EmberWatch_<36文字のrun ID>`なので生成先は`<clone root>` + `\Production\` + 47文字になり、その下の最長fileはproject rootからさらに115文字下にある（pluginの`Private/Tests`配下、`Plugins\MulticaOnlineStarter\Source\MulticaOnlineStarter\Private\Tests\MulticaOnlineDeferredDestroyCleanupTests.cpp`）。clone rootが85文字を超えると260文字を越える。`C:\gh\ue5-agent-template`（24文字）程度にすると余裕が取れる。予算を超える場合は`-MaxPathLength`を明示し、その理由と実測最長pathをQAに残す。


映像専用は`-Recipe vertical-loop`を選ぶ。三人称ゲーム（アクション・探索・街）は`-Recipe third-person-game`で、`<ProjectName>.uproject`／`Source/<ProjectName>`へ名前を置換した状態で生成する（ProjectNameはC++識別子）。`spectator-explore`と`vertical-loop`はtemplateを生コピーするのでprojectファイル名はtemplate名のまま（`TP_FirstPerson.uproject` / `TP_BlankBP.uproject`）で、`<ProjectName>.uproject`にはならない。どちらの場合も生成後の`template-lock.json`で`identity.project_file` / `identity.project_modules` / `identity.engine_association`、作品差分、plugin identityを確認してからEditorで開く。plugin identityは次の3点で照合する。

1. 生成`.uproject`の`Plugins`配列（`Name`と`Enabled`）
2. `template-lock.json`の`plugins` — 同じ`Name`が同じ件数だけあり、`enabled_in_project`が`.uproject`の`Enabled`と一致する
3. `plugins.<Name>.version` — そのinstallの`.uplugin`の`VersionName`と一致する（`unknown`は「読めなかった」であり、版が一致したという意味ではない）

templateがenableするpluginが当該Engine installに存在しない場合、generatorは`.uproject`もlockも書かずに停止し、未解決plugin名と探索pathを列挙する。templateのdescriptorと`Source/`が一致しない場合も同様に生コピーを出さず停止する。更新で既存作品を再生成/上書きしない。
コード境界とNull/LAN手順は`templates/online/MulticaOnlineStarter/README.md`および[方式比較](docs/08-online-foundations.md)を参照。

## エンコード前の画像列検査と尺検査

MRQ後の`frames/`をencodeする前に、期待範囲と実ファイルを照合する。読み取り専用で、画像の改名・修復・削除をしない。**presetの数値（解像度・fps・秒数・frame数・範囲）は`templates/CAPTURE-PRESETS.json`だけが持つ。** 手順は、まずpreset定義からコマンドを生成して表示し、その行をそのまま使う。

```powershell
.\scripts\Get-UECaptureEncodePlan.ps1 -Preset vertical
```

出力の`FRAMES-CHECK`行を`Measure-UERenderArtifacts.ps1`に、`FFMPEG`/`FFPROBE`行をencodeと計測に、`INSPECT`行を尺の検査に使う。数値を文書から転記しない。

`Measure-UERenderArtifacts.ps1`は欠番・範囲外・曖昧名・0 byte・decode不能・解像度不一致を検出し、reportを新規作成する。終了codeはpass=0/fail=1/unverified=2。**`-frames:v`は出力frame数の上限であり尺の検証ではない**ので、encode後に`Measure-UECaptureEncode.ps1`がpreset定義の期待frame数・秒数・解像度・fpsを実測と照合する（`evidence/encode-check.json`）。不一致はfail、測れない（ffprobe不在・timeout・video stream数が1でない）はunverifiedで、どちらもpassにしない。通知/exit、画像列、MP4、目視、音は別判定として扱う（[検品](docs/05-qa.md)）。回帰は`scripts/Test-UERenderArtifacts.ps1`と`scripts/Test-UECaptureEncode.ps1`。UE実機のMRQ・ffprobe・映像/音/loopの実測は未検証（Unverified）。

## run所有プロセスの回収

workerのrunは自分のプロセス木（writer + 子孫）を同期回収しなければならない（`AGENTS.md`）。名前指定killは禁止で、leaseの`writer_pid`単独では子孫に到達できないため、run開始時のスナップショットを帰属根拠にする。

```powershell
# 1. run開始時（lease取得直後）: writerとプロセス表を1回観測し、leaseに process_snapshot を記録
.\scripts\Start-UETemplateRunProcessSnapshot.ps1 `
  -RunId <runid> `
  -SnapshotPath '<project>\Out\run_<runid>\evidence\process-snapshot.json' `
  -LeasePath '<project>\LEASE.json'

# 2. 停止前に必ず対象一覧を出す（dry-run。何も停止しない）
.\scripts\Stop-UETemplateRunProcesses.ps1 `
  -SnapshotPath '<project>\Out\run_<runid>\evidence\process-snapshot.json' `
  -ReportPath '<project>\Out\run_<runid>\evidence\process-stop-plan.json'

# 3. 一覧のidentityだけを停止し、残存と帰属不明を検証する
.\scripts\Stop-UETemplateRunProcesses.ps1 `
  -SnapshotPath '<project>\Out\run_<runid>\evidence\process-snapshot.json' `
  -ReportPath '<project>\Out\run_<runid>\evidence\process-stop-plan.json' `
  -Execute `
  -VerificationPath '<project>\Out\run_<runid>\evidence\process-stop-verification.json'

# 4. leaseを free / held / unknown の3値で判定（writer_pidが死んだだけでは free にしない）
.\scripts\Get-UETemplateLeaseVerdict.ps1 -LeasePath '<project>\LEASE.json' -ReportPath '<project>\Out\run_<runid>\evidence\lease-check.json'
```

- 帰属不明（snapshotに無いprocess、PID再利用、hash/run/writer不一致）は停止せず `unknown`。`unknown`を`free`に読み替えない。
- 終了codeは `free=0` / `held=1` / `unknown=2`。check自体が実行できなかった場合も`unknown`（2）を返すので、`held`（1）を「check失敗」の意味に使わない。
- 共有Chrome・他runのprocess・writerの親は停止対象外として記録する。
- UEを起動しない層なので、UEのbuild/Editor/renderはこの手順の対象外。回帰は`scripts/Test-UETemplateProcessOwnership.ps1`（UE不使用の自作fixture）。詳細は[着手手順](docs/01-start.md)のlease節。

## GitHubから開始

```text
git clone https://github.com/eiei114/ue5-agent-template.git
cd ue5-agent-template
git rev-parse HEAD
```

共通基盤＋ジャンル差分＋用途部品を1リポジトリで管理する。[構造と更新](docs/07-architecture.md)を参照。generatorとNull/LAN starterは小さく実装したが、UE compile/PIE/renderの個別検証結果はQA記録に従い、未実行範囲を実装済み/検証済みと混同しない。

## bundleから開始（オフライン引渡し）

```text
git clone ue5-agent-template.bundle ue5-agent-template
cd ue5-agent-template
git status --short
```

bundle cloneの`origin`はbundleのpathであり、公開repoではない。そのため次のことが起きる。

- 生成時に`template_repository`へbundleのpath、`template_source_kind = 'bundle'`が入る（公開repoの定数は入らない）
- `template_commit_published`は`true`にならない。bundleは第三者からfetchできるrepoではないため、probeは`null`（未検査）を返し、**既定の生成は停止する**
- 通すには`-AllowUnpublishedTemplate`を明示する。lockには`template_commit_published = null`が残り、「公開済み」を意味しない

そのlockを第三者へ配布する前に、記録された`template_commit`をpush済みのrepo（または配布先のrepo）へ移し、そのrepoをcloneしたcheckoutで**新しいRunId**により再生成して、`template_commit_published = true`のlockを得る。bundleのlockのまま配布すると、受け取った側はlockが名指しするbundle pathを持たない限り同じtemplateを復元できない。

本リポジトリのpublic作成・pushはowner承認済み。他作品の公開・SNS・課金・認証には許可を流用しない。
