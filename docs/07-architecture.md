# 構造と更新

2026-11-01、owner包括承認により採用。巨大な全ジャンル共通実装ではなく、薄い共通基盤にレシピを組み合わせる。

| 層 | 責務 | 実装状態 |
|---|---|---|
| 共通基盤 | host・lease・環境構築・素材権利・検品・納品 | 既存docsと記録書式 |
| ジャンルrecipe | 鑑賞・探索等の固有設定、受入条件 | `templates/recipes/<recipe>/` を置くだけで追加できる（手順は下節）。既存 `spectator-explore` / `third-person-game` / `vertical-loop` |
| 用途部品 | プレイ／撮影。ジャンル別は両対応が基本 | `Play.md` / `Capture.md`に差分を分離 |
| 三人称ゲーム | 公式TP_ThirdPersonをウィザード同等に実体化（名前置換・共有pack・redirect） | `third-person-game` recipe（`materialize_project`） |
| 映像専用 | 縦動画・ループ等、操作不要の入口 | `vertical-loop` capture-only recipe（`Play.md` を持たない） |
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

generatorはrecipe名を一切見ない。`-Recipe` は `templates/recipes/<Recipe>/recipe.json` を指す名前であり、合成内容は recipe.json のデータと recipe ディレクトリに実際に置かれたファイルだけで決まる。

## recipeを追加する手順

`-Recipe` に新しい値を足すために generator を編集する必要はない。以下を置けばそのまま生成できる（回帰は `scripts/Test-UETemplateScaffold.ps1` の recipe層 group）。

1. `templates/recipes/<Recipe>/` を作る。ディレクトリ名がそのまま `-Recipe` の値になる（`^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$`、大文字小文字は区別）。
2. `recipe.json` を置く。必須fieldは次の5つ。

| field | 型 | 契約 |
|---|---|---|
| `schema_version` | 整数 | generatorが実装している値は `1` のみ。他の値を書くと生成前に停止する |
| `recipe` | 文字列 | **ディレクトリ名と完全一致**すること（大文字小文字も含む）。一致しない場合は停止する |
| `purpose` | 文字列 | 用途の記録。`game-and-capture` / `capture-only` を使う。**合成判断には使わない**（lockとコピーされた`recipe.json`だけが変わる。下記） |
| `engine_template` | 文字列 | `EngineRoot/Templates/<名前>/<名前>.uproject` が存在する公式template名（例 `TP_FirstPerson` / `TP_BlankBP` / `TP_ThirdPerson`） |
| `required_plugins` | 文字列の配列 | 有効化するplugin名。`MovieRenderPipeline` / `MulticaOnlineStarter` / `OnlineSubsystem` / `OnlineSubsystemNull` / `OnlineSubsystemUtils` のいずれか。重複・空要素・未知の名前は停止 |

任意fieldは `materialize_project`（真偽値、既定`false`）。`true` にするとtemplateの`Config/TemplateDefs.ini`を適用して`<Name>.uproject`・`Source/<Name>`へ実体化し、`ProjectName` をC++識別子に制限する。
3. `Capture.md` を置く。全recipe必須。無い場合は停止する。
4. `Play.md` は**任意**。置いたrecipeは `Recipe/Play.md` を出力し、置かないrecipeは出力しない。これがプレイ差分の有無を決める唯一の入力であり、recipe名ではない。

`recipe.json` / `Capture.md` / `Play.md` は生成物の `Recipe/` へ逐語コピーされる。`SET.md` は `templates/recipes/common/SET.md` の1つだけが全recipeに共通で入る。このため `templates/recipes/common/` のような `recipe.json` を持たないディレクトリは recipe ではなく、`-Recipe` に指定しても選択肢として案内されない（未知recipeとして停止する）。

### `purpose` の契約（合成を変えない、lockとコピーだけが変わる）

`purpose` は**合成判断に使わない**。合成（どのtemplateをコピーするか、plugin一式を入れるか、`docs/08`を同梱するか、`Recipe/Play.md`を出すか）は `engine_template` / `required_plugins` / recipeディレクトリに実在するファイルだけで決まる。同じデータと同じファイル構成を持つ2つのrecipeは、`purpose` が違っても**同じファイル集合・同じplugin構成・同じPlay差分**を出す。

ただし `recipe.json` は生成物の `Recipe/recipe.json` へ**逐語コピー**されるので、`purpose` だけを書き換えると生成物の次の2ファイルは実際に変わる。

| ファイル | `purpose` 変更時の挙動 |
|---|---|
| `Recipe/recipe.json` | 変わる（recipeデータの逐語コピーなので、その`purpose`行がそのまま出る） |
| `template-lock.json` | 変わる（`purpose` を記録する） |
| 上記以外（template由来のtree、`Plugins/`、`Recipe/`の他ファイル、`.uproject`） | 変わらない（byte一致） |

回帰testはこの契約をそのままassertする。ファイル集合（composition）と上記2ファイル以外のbyte一致を比較し、`Recipe/recipe.json` と `template-lock.json` は**変わることが期待値**として別にassertする。したがって「同一tree」という主張はこの2ファイルを含まない意味であり、lockの`purpose`とコピーされた`recipe.json`は用途の記録として読む。用途の意味づけはrecipe本文（`Capture.md` / `Play.md`）と作品側QAで表す。field追加で合成を変えたい場合は `schema_version` を上げ、generatorの対応と回帰を同時に足す。

### `required_plugins` と `Plugins/` の関係（単一の真実）

| 宣言 | 生成物 |
|---|---|
| `MulticaOnlineStarter` を含む | `Plugins/MulticaOnlineStarter/` にplugin一式をコピーし、`.uproject`の`Plugins[]`で有効化し、`docs/08-online-foundations.md` を同梱し、`Config/DefaultEngine.ini` に `DefaultPlatformService=Null` と `SessionProjectIdentifier` を書き、lockにplugin版と`online_session_identifier`を記録する |
| 含まない | 上記のどれも生成しない（`Plugins/` ディレクトリ自体を作らない） |
| その他のplugin | `.uproject`の`Plugins[]`で有効化し、lockの`plugins.<名前>`にdescriptorの`VersionName`（無ければ`Version`）を記録する。descriptorが見つからない、または版が空なら停止 |

つまり「宣言」と「実体」は同じデータから生成される。片方だけ更新した状態は作れない。

### lock に載る項目

`template-lock.json`（`schema_version: 2`）は、recipe層では `recipe` / `purpose` / `plugins` / `online_session_identifier` を記録する。`recipe` は**実際に合成したディレクトリ名**（`recipe.json` の `recipe` と一致していることを生成前に検査済み）であり、CLIで選んだ値とlockの値が食い違うことはない。

### 追加時の確認

- 新recipeは新しい `RunId` で生成し、既存projectを上書きしない。
- `Recipe/` の中身、`.uproject`の`Plugins[]`、`template-lock.json` の `recipe` / `purpose` / `plugins` を実物と突き合わせる。
- 既存2recipeの生成結果を変えないこと。`scripts/Test-UETemplateScaffold.ps1` のrecipe層 groupが、データだけを足した生成・`Play.md` の有無・`required_plugins` の増減・停止条件・既存recipeの回帰を固定している。

### project identity契約（1つだけ）

| 項目 | 契約 | 確認先 |
|---|---|---|
| projectファイル名 | `materialize_project`のrecipeは`<Name>.uproject`、生コピーのrecipeは`<EngineTemplate>.uproject`（`TP_FirstPerson` / `TP_BlankBP`）。どちらも`Source/<Module>/<Module>.Build.cs`と一致していること | 実ファイル、`template-lock.json`の`identity.project_file` |
| module名 | `.uproject`の`Modules[].Name`は`Source/<Module>/<Module>.Build.cs`と一致する。`materialize_project`なら`<Name>`、生コピーならtemplate名のまま | `identity.project_modules`、`Source/` |
| `EngineAssociation` | 空にしない。templateが値を持たない場合は`Engine/Build/Build.version`の`MajorVersion.MinorVersion`から導く | `identity.engine_association` |
| 置換不能時 | コピー前に照合し、既知パターンに一致しない場合は停止して未一致pathを列挙する。生コピーを黙って出力しない | generatorのstderr/例外、`scripts/Test-UETemplateScaffold.ps1`の負例 |

lockは`schema_version: 3`で、上記3項目を`identity`に持つ。単位は作品（`Production/<Name>_<runid>/template-lock.json`）であり、identityを手で書き換えない。

### lockが固定するengine build identity（`schema_version: 3`）

| field | 由来 | 契約 |
|---|---|---|
| `engine_version` | `Build.version`の`MajorVersion`.`MinorVersion`.`PatchVersion` | 3 field全てが数値であること。欠落・非数値なら生成を停止する（`'5.8.'`のような断片を成功出力しない） |
| `engine_changelist` | `Changelist`と`CompatibleChangelist`から導出 | UEの`FBuildVersion::GetEffectiveCompatibleChangelist()`と同じ規則（両方が非0なら`CompatibleChangelist`、それ以外は`Changelist`）。導出に使ったfieldが無ければ`null` |
| `engine_changelist_source` | 導出に使ったfield名 | `CompatibleChangelist` / `Changelist` / `null` |
| `engine_changelist_raw` | `Build.version`の`Changelist` | エンジンが書いた値をそのまま。キーが無ければ`null`（`0`と書かない） |
| `engine_compatible_changelist` | `Build.version`の`CompatibleChangelist` | キーが無ければ`null` |
| `engine_is_licensee_version` | `Build.version`の`IsLicenseeVersion` | キーが無ければ`null` |
| `engine_is_promoted_build` | `Build.version`の`IsPromotedBuild` | キーが無ければ`null` |
| `engine_branch_name` | `Build.version`の`BranchName` | キーが無ければ`null`（空文字と「未設定」を区別する） |

Epic自身の`Build.version`は`Changelist: 0` + `CompatibleChangelist: <identifier>`の形を採る（`Engine/Source/Runtime/Core/Private/Modules/BuildVersion.cpp:21-24`、2026-11-03に実体を確認）。素の`Changelist`だけを読むと別のEngine installが同じlockになるため、導出と生値の両方を記録する。

**`null` = 不明。0／空文字は「エンジンがそう書いた」値だけに使う。** plugin版も同じ規則で、`.uplugin`が`VersionName`/`Version`を持たない場合は`plugins.<name> = null`とする。

### lockの比較規則（byte比較ではなく semantic比較）

lockを比べるときはJSONをparseしてfield単位で比較する。byte比較は同一shell・同一入力の生成物にだけ使う。

- 根拠（本host実測、2026-11-03）: 同一入力・同一template commitでWindows PowerShell 5.1とpwsh 7.6.9が生成したlockは semantic equal / byte different（`ConvertTo-Json`の既定整形が4-space + `":  "`と2-space + `": "`で異なる）。sha256も異なる。
- したがってhostを跨いだlockの同一性判定にsha256や`diff`を使うと偽の不一致が出る。canonical serializerは未実装で、この差は意図的に残している。
- 実装済みの範囲: `scripts/Test-UETemplateScaffold.ps1`は同一shell・同一入力のlock byte一致（`-ceq`）をassertionで固定する。cross-shellのbyte一致は主張しない（本hostの実測で差があるため）。

同じlockが、templateの`Config/TemplateDefs.ini`から実際に何を適用したかを追加fieldで記録する（schema_versionは据え置き）。

| field | 内容 |
|---|---|
| `shared_content_packs` | 出力`Content/`へ展開したmount名の配列。宣言が無いtemplate（`TP_BlankBP`）は空配列 |
| `shared_content_pack_detail_levels` | mount名 → 実際に展開元としたdetail level（例: `Weapons: Standard`） |
| `template_defs_ignore_rules` | 適用した`FoldersToIgnore` / `FilesToIgnore`の件数（`folders_to_ignore` / `files_to_ignore`） |

生成後の検査として、生成された`Config/DefaultEngine.ini`の`GameDefaultMap` / `EditorStartupMap`が`/Game/...`を指す場合、その`.umap`が出力に存在することを確認する。無ければgeneratorは停止して欠落pathを列挙し、`template-lock.json`を書かず`Created ...`も出さない。`/Engine/...`（engine content）を指す宣言は出力treeの対象外として検査しない。

## preflight・leaseの配置（正本）

生成前に書くもの（preflight記録とlease）の置き場所は1つだけにし、生成先`Production/<Name>_<runid>/`と重ねない。

`preflight-lease-placement: Production/.runs/run_<runid>/`

- このpathは生成先project dirの外にある台帳dir。`Production/*`はgitignore対象なのでclean-tree gateを踏まない。
- `Production/<Name>_<runid>/`を作るのはgeneratorだけで、lease工程はこのdirを作らない。中身が空でも`LEASE.json`だけでも`Out/`だけでも、generatorは「順序誤り」と判別できるメッセージで停止する（削除・上書きはしない）。
- 上の1行を機械可読な正本とし、`scripts/Test-UETemplateScaffold.ps1`が`AGENTS.md`・`README.md`・`docs/01-start.md`が同じpathを指していることを照合する。文書を変えるときはこの行を先に変え、他文書を追随させる。

## lockと更新手順

lockはtemplate commit SHA、clean/dirty状態、UE version/changelist、Engine/plugin version、recipe/use、作品差分、project identityを固定する。`recipe`/`purpose`はrecipe.jsonから、`plugins`は`required_plugins`から生成される。実作はcommit済み・cleanなtemplateから生成する。dirty時の生成は拒否し、テストだけ明示的な`-AllowDirtyTemplate`を使う。

lockはtemplate commit SHA、clean/dirty状態、engine template、UE version、engine build identity（`engine_changelist` / `engine_changelist_raw` / `engine_compatible_changelist` / `engine_is_licensee_version` / `engine_is_promoted_build` / `engine_branch_name`）、Engine/plugin version、recipe/use、作品差分、project identityを固定する。実作はcommit済み・cleanなtemplateから生成する。dirty時の生成は拒否し、テストだけ明示的な`-AllowDirtyTemplate`を使う。

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
