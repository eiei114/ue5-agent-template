# 構造と更新

2026-11-01、owner包括承認により採用。巨大な全ジャンル共通実装ではなく、薄い共通基盤にレシピを組み合わせる。

| 層 | 責務 | 実装状態 |
|---|---|---|
| 共通基盤 | host・lease・環境構築・素材権利・検品・納品 | 既存docsと記録書式 |
| ジャンルrecipe | 鑑賞・探索等の固有設定、受入条件 | `spectator-explore` recipeを追加 |
| 用途部品 | プレイ／撮影。ジャンル別は両対応が基本 | `Play.md` / `Capture.md`に差分を分離 |
| 三人称ゲーム | 公式TP_ThirdPersonの実体化（実装済みTemplateDefsキーによる名前置換・共有pack・redirect） | `third-person-game` recipe（`materialize_project`） |
| 映像専用 | 縦動画・ループ等、操作不要の入口 | `vertical-loop` capture-only recipeを追加 |
| オンライン | 小人数listen server、session、replication | Null/LAN starter pluginと方式比較を追加。実測範囲はQA参照 |
| project generator | installed Engineの公式templateから新規project生成 | `scripts/New-UETemplateScaffold.ps1`。排他的作成/上書き禁止、project identity照合あり |
| 検品helper | エンコード前の画像列を読み取り専用で照合 | `scripts/Measure-UERenderArtifacts.ps1`。fixture回帰は`scripts/Test-UERenderArtifacts.ps1` |

作品のセットは正本1つをプレイと撮影から参照し、撮影のためにマップ全体を複製しない。用途別の画質・カメラ・照明・UIの差分は明示する。

`spectator-explore`は公式`TP_FirstPerson`を起点にし、プレイと撮影を同じsetへ向ける。`vertical-loop`は公式`TP_BlankBP`を起点にしてゲーム操作を要求しない。この2つはtemplateを生コピーし、`<EngineTemplate>.uproject`と`Source/<EngineTemplate>`が互いに一致したまま残る。`third-person-game`だけが`materialize_project: true`で、`Config/TemplateDefs.ini`の実装済みキーを適用し`<Name>.uproject`へ実体化する。generatorはEngineの既存templateをコピーし、recipe文書・online plugin・`template-lock.json`を加える。generator自身がmap/Sequence/`.uasset`を捏造しない。

### TemplateDefs.ini の実装範囲（共通基盤）

実装しているキーは次の7つだけである。ここに列挙しないキーは**適用せず、警告して継続**し、`template-lock.json`の`template_defs.ignored_keys`に記録する。

| キー | 適用内容 | 判定単位 |
|---|---|---|
| `FoldersToIgnore` / `FilesToIgnore` | コピー対象から外す | 相対path（`%TEMPLATENAME%`を展開） |
| `FolderRenames` | 出力先のディレクトリを改名 | `(From,To)` tuple。`%PROJECTNAME%`を展開 |
| `FilenameReplacements` | **ファイル名**を置換 | キー固有の`Extensions`と`From`/`To`/`bCaseSensitive` |
| `ReplacementsInFiles` | **ファイル本文**を置換 | キー固有の`Extensions`と`From`/`To`/`bCaseSensitive`（宣言順） |
| `SharedContentPacks` | `Templates/TemplateResources/<Level>/<Mount>/Content` → `Content/<Mount>` | mountごとの`DetailLevels`（実体が無ければfall backを警告） |
| `EditDetailLevelPreference` | pack探索の既定level | 単一値 |

- `FilenameReplacements`と`ReplacementsInFiles`は別宣言であり、片方の`Extensions`をもう片方の判定に使わない。`From`が一致しない場合、そのtupleは何も置換しない。
- 未実装キー（`LocalizedDisplayNames` / `LocalizedDescriptions` / `Categories` / `ClassTypes` / `AssetTypes` / `bThumbnailAsIcon` / `SortKey` / `Variants` 等）はウィザードの表示・選択metadataであり、本generatorは使わない。実engine templateはこれらを必ず含むため、停止ではなく警告とlock記録を選んでいる。
- module名（`.uproject`の`Modules[].Name`）にも`ReplacementsInFiles`を適用する。宣言規則がmodule名に届かなければ生成後のidentity検査で非0停止し、未一致pathを列挙する。
- `.uproject`はJSONであり`ReplacementsInFiles`の`Extensions`（`cpp`/`h`/`ini`/`cs`等）に含まれない。module名の書換はidentity契約を保つための別処理であり、本文置換の対象ではない。

### project identity契約（1つだけ）

| 項目 | 契約 | 確認先 |
|---|---|---|
| projectファイル名 | `materialize_project`のrecipeは`<Name>.uproject`、生コピーのrecipeは`<EngineTemplate>.uproject`（`TP_FirstPerson` / `TP_BlankBP`）。どちらも`Source/<Module>/<Module>.Build.cs`と一致していること | 実ファイル、`template-lock.json`の`identity.project_file` |
| module名 | `.uproject`の`Modules[].Name`は`Source/<Module>/<Module>.Build.cs`と一致する。`materialize_project`なら`<Name>`、生コピーならtemplate名のまま | `identity.project_modules`、`Source/` |
| `EngineAssociation` | 空にしない。templateが値を持たない場合は`Engine/Build/Build.version`の`MajorVersion.MinorVersion`から導く | `identity.engine_association` |
| 置換不能時 | コピー前に照合し、既知パターンに一致しない場合は停止して未一致pathを列挙する。生コピーを黙って出力しない | generatorのstderr/例外、`scripts/Test-UETemplateScaffold.ps1`の負例 |

lockは`schema_version: 2`で、上記3項目を`identity`に持つ。単位は作品（`Production/<Name>_<runid>/template-lock.json`）であり、identityを手で書き換えない。

## lockと更新手順

lockはtemplate commit SHA、clean/dirty状態、UE version/changelist、Engine/plugin version、recipe/use、作品差分、project identityを固定する。実作はcommit済み・cleanなtemplateから生成する。dirty時の生成は拒否し、テストだけ明示的な`-AllowDirtyTemplate`を使う。

共通更新は新RunIdの空Production directoryへ生成し、既存projectを上書きせず、lock・作品差分・移行手順・対象版の検品結果を比較する。UE/Plugin更新の自動伝播はしない。

**変更理由:** 共通環境の二重管理を避けながら、同じsetのプレイ/撮影と映像専用入口を小さく始める。生成時のdependency driftをlockで可視化し、template更新で制作中作品を壊さない。

方式比較とsource別の費用・制約は[docs/08-online-foundations.md](08-online-foundations.md)。Null/LANを初期動作とし、EOS/Steamは設定と実測を満たす独立adapter候補として扱う。

初期は1repoで共通文書を参照し、再利用が実証された部品のみPlugin化する。深いBlueprint継承、ジャンルごとの全量fork、submoduleの大量追加は避ける。
作品には共通commit SHA・UE/Plugin版・レシピ・ローカル差分を記録する。制作中の作品は固定版を使い、自動更新・上書きをしない。更新時は差分、移行方法、検品結果を残す。

## 継続改善

Multicaの既存ボードと管理機会で「出典調査→候補→小さな検証→採否→変更理由・移行手順」を記録。公式仕様・掲示板の事例・当該host実測を区別する。未検証情報を既定値へ昇格しない。
Epic公式Custom TemplatesとPluginsを参考にするが、文書テンプレートはUE登録済みproject templateとは別物。

- https://dev.epicgames.com/documentation/en-us/unreal-engine/converting-a-project-to-an-unreal-engine-template
- https://dev.epicgames.com/documentation/en-us/unreal-engine/plugins-in-unreal-engine

課金、素材権利、認証、他作品の公開gateは変えない。オンラインサービスも無料枠・運用費・接続制約を都度確認し、無料保証をしない。
