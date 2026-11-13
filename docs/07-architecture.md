# 構造と更新

2026-11-01、owner包括承認により採用。巨大な全ジャンル共通実装ではなく、薄い共通基盤にレシピを組み合わせる。

| 層 | 責務 | 実装状態 |
|---|---|---|
| 共通基盤 | host・lease・環境構築・素材権利・検品・納品 | 既存docsと記録書式 |
| ジャンルrecipe | 鑑賞・探索等の固有設定、受入条件 | `spectator-explore` recipeを追加 |
| 用途部品 | プレイ／撮影。ジャンル別は両対応が基本 | `Play.md` / `Capture.md`に差分を分離 |
| 三人称ゲーム | 公式TP_ThirdPersonをウィザード同等に実体化（名前置換・共有pack・redirect） | `third-person-game` recipe（`materialize_project`） |
| 映像専用 | 縦動画・ループ等、操作不要の入口 | `vertical-loop` capture-only recipeを追加 |
| オンライン | 小人数listen server、session、replication | Null/LAN starter pluginと方式比較を追加。実測範囲はQA参照 |
| project generator | installed Engineの公式templateから新規project生成 | `scripts/New-UETemplateScaffold.ps1`。排他的作成/上書き禁止、`TemplateDefs.ini`適用、project identity照合、既定map照合あり |
| 検品helper | エンコード前の画像列を読み取り専用で照合 | `scripts/Measure-UERenderArtifacts.ps1`。fixture回帰は`scripts/Test-UERenderArtifacts.ps1` |

作品のセットは正本1つをプレイと撮影から参照し、撮影のためにマップ全体を複製しない。用途別の画質・カメラ・照明・UIの差分は明示する。

`spectator-explore`は公式`TP_FirstPerson`を起点にし、プレイと撮影を同じsetへ向ける。`vertical-loop`は公式`TP_BlankBP`を起点にしてゲーム操作を要求しない。この2つはtemplateのprojectファイル名と`Source/<EngineTemplate>`をそのまま残す（生コピー経路）。`third-person-game`だけが`materialize_project: true`で、`Config/TemplateDefs.ini`をウィザードと同じ規則で適用し`<Name>.uproject`へ実体化する。

generatorはEngineの既存templateをコピーし、recipe文書・online plugin・`template-lock.json`を加える。**3 recipeともtemplate自身の`Config/TemplateDefs.ini`を1つの実装（`scripts/New-UETemplateScaffold.ps1`の`Copy-TemplateTree`）で読む**。違いはrenameを適用するかどうかだけで、copy範囲の規則は共通である。

| TemplateDefs.iniのキー | 生コピー経路 | materialize経路 |
|---|---|---|
| `FoldersToIgnore` / `FilesToIgnore` | 適用（`Config/TemplateDefs.ini`自身と`Config/config.ini`、`Media/`が出力に残らない） | 適用 |
| `SharedContentPacks` | 適用（`Templates/TemplateResources/<DetailLevel>/<Mount>/Content` → `Content/<Mount>`） | 適用 |
| `EditDetailLevelPreference` | 展開先のdetail level解決に使う。そのlevelに実体が無いmount（`TP_FirstPerson`の`Weapons`は`Standard`のみ）は、`High` → `Standard` の順で実在するlevelを選ぶ | 同左 |
| `FolderRenames` / `ReplacementsInFiles` / `FilenameReplacements` | 適用しない（project名/module名がtemplate名のまま残るため） | 適用 |
| `SharedContentPacks`の`DetailLevels` tuple | 個別には解釈しない（per-mount detail resolutionはDOT-3135の担当） | 同左 |

generator自身がmap/Sequence/`.uasset`を捏造しない。

### project identity契約（1つだけ）

| 項目 | 契約 | 確認先 |
|---|---|---|
| projectファイル名 | `materialize_project`のrecipeは`<Name>.uproject`、生コピーのrecipeは`<EngineTemplate>.uproject`（`TP_FirstPerson` / `TP_BlankBP`）。どちらも`Source/<Module>/<Module>.Build.cs`と一致していること | 実ファイル、`template-lock.json`の`identity.project_file` |
| module名 | `.uproject`の`Modules[].Name`は`Source/<Module>/<Module>.Build.cs`と一致する。`materialize_project`なら`<Name>`、生コピーならtemplate名のまま | `identity.project_modules`、`Source/` |
| `EngineAssociation` | 空にしない。templateが値を持たない場合は`Engine/Build/Build.version`の`MajorVersion.MinorVersion`から導く | `identity.engine_association` |
| 置換不能時 | コピー前に照合し、既知パターンに一致しない場合は停止して未一致pathを列挙する。生コピーを黙って出力しない | generatorのstderr/例外、`scripts/Test-UETemplateScaffold.ps1`の負例 |

lockは`schema_version: 2`で、上記3項目を`identity`に持つ。単位は作品（`Production/<Name>_<runid>/template-lock.json`）であり、identityを手で書き換えない。

同じlockが、templateの`Config/TemplateDefs.ini`から実際に何を適用したかを追加fieldで記録する（schema_versionは据え置き）。

| field | 内容 |
|---|---|
| `shared_content_packs` | 出力`Content/`へ展開したmount名の配列。宣言が無いtemplate（`TP_BlankBP`）は空配列 |
| `shared_content_pack_detail_levels` | mount名 → 実際に展開元としたdetail level（例: `Weapons: Standard`） |
| `template_defs_ignore_rules` | 適用した`FoldersToIgnore` / `FilesToIgnore`の件数（`folders_to_ignore` / `files_to_ignore`） |

生成後の検査として、生成された`Config/DefaultEngine.ini`の`GameDefaultMap` / `EditorStartupMap`が`/Game/...`を指す場合、その`.umap`が出力に存在することを確認する。無ければgeneratorは停止して欠落pathを列挙し、`template-lock.json`を書かず`Created ...`も出さない。`/Engine/...`（engine content）を指す宣言は出力treeの対象外として検査しない。

## lockと更新手順

lockはtemplate commit SHA、clean/dirty状態、UE version/changelist、Engine/plugin version、recipe/use、作品差分、project identityを固定する。実作はcommit済み・cleanなtemplateから生成する。dirty時の生成は拒否し、テストだけ明示的な`-AllowDirtyTemplate`を使う。

共通更新は新RunIdの空Production directoryへ生成し、既存projectを上書きせず、lock・作品差分・移行手順・対象版の検品結果を比較する。UE/Plugin更新の自動伝播はしない。

**変更理由:** 共通環境の二重管理を避けながら、同じsetのプレイ/撮影と映像専用入口を小さく始める。生成時のdependency driftをlockで可視化し、template更新で制作中作品を壊さない。

方式比較とsource別の費用・制約は[docs/08-online-foundations.md](08-online-foundations.md)。Null/LANを初期動作とし、EOS/Steamは設定と実測を満たす独立adapter候補として扱う。

初期は1repoで共通文書を参照し、再利用が実証された部品のみPlugin化する。深いBlueprint継承、ジャンルごとの全量fork、submoduleの大量追加は避ける。
作品には共通commit SHA・UE/Plugin版・レシピ・ローカル差分を記録する。制作中の作品は固定版を使い、自動更新・上書きをしない。更新時は差分、移行方法、検品結果を残す。

## 継続改善

Multicaの既存ボードと管理機会で「出典調査→候補→小さな検証→採否→変更理由・移行手順」を記録。公式仕様・掲示板の事例・当該host実測を区別する。未検証情報を既定値へ昇格しない。

「同梱する／しない」という主張は散文ではなく `docs/PROVENANCE.inventory.json` を正本とし、`scripts/Test-UETemplateProvenance.ps1` が tracked file と照合する（R1 虚偽の「無い」、R2 宙に浮いた「有る」、R3 未分類の新規層、R4 解決しない相対リンク）。新しい層や area を追加するときは同じ commit で inventory を更新し、`scripts/Test-UETemplateProvenance.Tests.ps1` の負例を回す。実績と未確認点の本文は [docs/PROVENANCE.md](PROVENANCE.md)。
Epic公式Custom TemplatesとPluginsを参考にするが、文書テンプレートはUE登録済みproject templateとは別物。

- https://dev.epicgames.com/documentation/en-us/unreal-engine/converting-a-project-to-an-unreal-engine-template
- https://dev.epicgames.com/documentation/en-us/unreal-engine/plugins-in-unreal-engine

課金、素材権利、認証、他作品の公開gateは変えない。オンラインサービスも無料枠・運用費・接続制約を都度確認し、無料保証をしない。
