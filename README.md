# UE5 Agent Production Template

AIが短い映像または小さな鑑賞シーンを安全に作るための**文書・運用テンプレート**。
最初に [AGENTS.md](AGENTS.md)、次に [着手手順](docs/01-start.md) を読む。

## 現在の範囲

- UE5.8系の既存制作から手順を抽出。UE本体、Room Seven、Fab、Splice、Mixamo、NCSの素材実物は含まない。
- 生成器はインストール済みUE公式`TP_FirstPerson` / `TP_BlankBP` / `TP_ThirdPerson` project templateから新規`.uproject`を排他的に作成する。`spectator-explore` / `vertical-loop`は生コピーでtemplateのprojectファイル名と`Modules[].Name`を維持し、`third-person-game`は`TemplateDefs.ini`によるmaterialize経路で`<ProjectName>.uproject`と同名moduleへ置換する。`EngineAssociation`は必ず非空で、生成後のprojectファイル名・module名・`EngineAssociation`は`template-lock.json`の`identity`に記録する（詳細は[構造と更新](docs/07-architecture.md)）。ソースrepoにはEngine由来Contentや`.uasset`を含めない。
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

`templates/` の記録を新規制作の `Out/run_<runid>/` へ複製して記入する。
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

映像専用は`-Recipe vertical-loop`を選ぶ。三人称ゲーム（アクション・探索・街）は`-Recipe third-person-game`で、`<ProjectName>.uproject`／`Source/<ProjectName>`へ名前を置換した状態で生成する（ProjectNameはC++識別子）。`spectator-explore`と`vertical-loop`はtemplateを生コピーするのでprojectファイル名はtemplate名のまま（`TP_FirstPerson.uproject` / `TP_BlankBP.uproject`）で、`<ProjectName>.uproject`にはならない。どちらの場合も生成後の`template-lock.json`で`identity.project_file` / `identity.project_modules` / `identity.engine_association`、作品差分、`.uproject`のplugin設定を確認してからEditorで開く。templateのdescriptorと`Source/`が一致しない場合、generatorは生コピーを出さず停止する。更新で既存作品を再生成/上書きしない。

パス長に注意: 上の例の出力folder名は`EmberWatch_<36文字のrun ID>`なので生成先は`<clone root>` + `\Production\` + 47文字になり、その下の最長fileはproject rootからさらに115文字下にある（pluginの`Private/Tests`配下、`Plugins\MulticaOnlineStarter\Source\MulticaOnlineStarter\Private\Tests\MulticaOnlineDeferredDestroyCleanupTests.cpp`）。clone rootが85文字を超えると260文字を越える。`C:\gh\ue5-agent-template`（24文字）程度にすると余裕が取れる。予算を超える場合は`-MaxPathLength`を明示し、その理由と実測最長pathをQAに残す。

コード境界とNull/LAN手順は`templates/online/MulticaOnlineStarter/README.md`および[方式比較](docs/08-online-foundations.md)を参照。

## エンコード前の画像列検査

MRQ後の`frames/`をencodeする前に、期待範囲と実ファイルを照合する。読み取り専用で、画像の改名・修復・削除をしない。

```powershell
.\scripts\Measure-UERenderArtifacts.ps1 `
  -FramesDirectory '<project>\Out\run_<runid>\frames' `
  -StartNumber 0 `
  -EndNumberExclusive 240 `
  -ExpectedWidth 1080 `
  -ExpectedHeight 1920 `
  -ReportPath '<project>\Out\run_<runid>\evidence\frames-check.json'
```

欠番・範囲外・曖昧名・0 byte・decode不能・解像度不一致を検出し、reportを新規作成する。終了codeはpass=0/fail=1/unverified=2。通知/exit、画像列、MP4、目視、音は別判定として扱う（[検品](docs/05-qa.md)）。回帰は`scripts/Test-UERenderArtifacts.ps1`。UE実機のMRQ・ffprobe・映像/音/loopの実測は未検証（Unverified）。

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

本リポジトリのpublic作成・pushはowner承認済み。他作品の公開・SNS・課金・認証には許可を流用しない。
