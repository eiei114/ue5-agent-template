# UE5 Agent Production Template

AIが短い映像または小さな鑑賞シーンを安全に作るための**文書・運用テンプレート**。
最初に [AGENTS.md](AGENTS.md)、次に [着手手順](docs/01-start.md) を読む。

## 現在の範囲

- UE5.8系の既存制作から手順を抽出。UE本体、Room Seven、Fab、Splice、Mixamo、NCSの素材実物は含まない。
- 生成器はインストール済みUE公式`TP_FirstPerson` / `TP_BlankBP` project templateから新規`.uproject`を排他的に作成する。ソースrepoにはEngine由来Contentや`.uasset`を含めない。
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

`templates/` の記録を新規制作の `Out/run_<runid>/` へ複製して記入する。
`Production/` は生成先の空プレースホルダ。通常Gitには制作物を入れない。

## 新規scaffold

cleanなtemplate checkoutと既存UE installを指定し、同じName/RunIdの出力がないことを確認してから実行する。

```powershell
.\scripts\New-UETemplateScaffold.ps1 `
  -Recipe spectator-explore `
  -ProjectName EmberWatch `
  -RunId 01a19290-18dc-7bcc-ba2d-f647ec88dcf3 `
  -EngineRoot 'C:\Program Files\Epic Games\UE_5.8' `
  -ProjectDiff 'Shared map: /Game/EmberWatch/Maps/L_Environment'
```

映像専用は`-Recipe vertical-loop`を選ぶ。三人称ゲーム（アクション・探索・街）は`-Recipe third-person-game`で、`<ProjectName>.uproject`／`Source/<ProjectName>`へ名前を置換した状態で生成する（ProjectNameはC++識別子）。生成後の`template-lock.json`、作品差分、`.uproject`のengine template/plugin設定を確認してからEditorで開く。更新で既存作品を再生成/上書きしない。
コード境界とNull/LAN手順は`templates/online/MulticaOnlineStarter/README.md`および[方式比較](docs/08-online-foundations.md)を参照。

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
