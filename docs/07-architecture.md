# 構造と更新

2026-11-01、owner包括承認により採用。巨大な全ジャンル共通実装ではなく、薄い共通基盤にレシピを組み合わせる。

| 層 | 責務 | 実装状態 |
|---|---|---|
| 共通基盤 | host・lease・環境構築・素材権利・検品・納品 | 既存docsと記録書式 |
| ジャンルrecipe | 鑑賞・探索等の固有設定、受入条件 | `templates/recipes/<recipe>/` を置くだけで追加できる（手順は下節）。既存 `spectator-explore` / `third-person-game` / `vertical-loop` |
| 用途部品 | プレイ／撮影。ジャンル別は両対応が基本 | `Play.md` / `Capture.md`に差分を分離 |
| 三人称ゲーム | 公式TP_ThirdPersonをウィザード同等に実体化（名前置換・共有pack・package redirect + 改名済みclass redirect） | `third-person-game` recipe（`materialize_project`） |

| 三人称ゲーム | 公式TP_ThirdPersonを、`TemplateDefs.ini`の置換規則で`<Name>`へ実体化（名前置換・共有pack・redirect）。規則の適用範囲と封じ込めは下記「TemplateDefs.ini契約」 | `third-person-game` recipe（`materialize_project`） |

| 三人称ゲーム | 公式TP_ThirdPersonの実体化（実装済みTemplateDefsキーによる名前置換・共有pack・redirect） | `third-person-game` recipe（`materialize_project`） |
| 映像専用 | 縦動画・ループ等、操作不要の入口 | `vertical-loop` capture-only recipeを追加 |
| オンライン | 小人数listen server、session、replication | Null/LAN starter pluginと方式比較を追加。実測範囲はQA参照 |
| project generator | installed Engineの公式templateから新規project生成 | `scripts/New-UETemplateScaffold.ps1`。排他的作成/上書き禁止、`TemplateDefs.ini`適用、project identity照合、既定map照合あり |
| 検品helper | エンコード前の画像列を読み取り専用で照合 | `scripts/Measure-UERenderArtifacts.ps1`。fixture回帰は`scripts/Test-UERenderArtifacts.ps1` |

作品のセットは正本1つをプレイと撮影から参照し、撮影のためにマップ全体を複製しない。用途別の画質・カメラ・照明・UIの差分は明示する。

`spectator-explore`は公式`TP_FirstPerson`を起点にし、プレイと撮影を同じsetへ向ける。`vertical-loop`は公式`TP_BlankBP`を起点にしてゲーム操作を要求しない。この2つはtemplateのprojectファイル名と`Source/<EngineTemplate>`をそのまま残す（生コピー経路）。`third-person-game`だけが`materialize_project: true`で、`Config/TemplateDefs.ini`の規則を適用し`<Name>.uproject`へ実体化する。

`spectator-explore`は公式`TP_FirstPerson`を起点にし、プレイと撮影を同じsetへ向ける。`vertical-loop`は公式`TP_BlankBP`を起点にしてゲーム操作を要求しない。この2つはtemplateのprojectファイル名と`Source/<EngineTemplate>`をそのまま残す（生コピー経路）。`third-person-game`だけが`materialize_project: true`で、`Config/TemplateDefs.ini`の実装済みキーを適用し`<Name>.uproject`へ実体化する（materialize経路）。

generatorはEngineの既存templateをコピーし、recipe文書・online plugin・`template-lock.json`を加える。**3 recipeともtemplate自身の`Config/TemplateDefs.ini`を1つの実装（`scripts/New-UETemplateScaffold.ps1`の`Copy-TemplateTree`）で読む**。違いはrenameを適用するかどうかだけで、copy範囲の規則は共通である。generator自身がmap/Sequence/`.uasset`を捏造しない。

### TemplateDefs.ini契約（実装しているキーと検査している範囲）

`third-person-game`は「UE New Projectウィザードと同じ規則」ではなく、**このgeneratorが実装した範囲**を適用する。Epic公式docsには`TemplateDefs.ini`の`FolderRenames` / `SharedContentPacks` / `ReplacementsInFiles` / `FilenameReplacements` / `EditDetailLevelPreference`のschemaが無い（2026-11-03取得、0ヒット）。したがって規則の正しさは公式仕様ではなくrepoの実測で担保する。

| キー / 範囲 | 生コピー経路 | materialize経路（`third-person-game`） |

### TemplateDefs.ini の実装範囲（共通基盤）

| キー | 生コピー経路 | materialize経路 |
|---|---|---|
| `FoldersToIgnore` / `FilesToIgnore` | 相対pathで除外（`Config/TemplateDefs.ini`自身・`Config/config.ini`・`Media/`が出力に残らない） | 同左 |
| `FolderRenames` | 適用しない（project名/module名がtemplate名のまま残るため） | `From`一致時に`To`（`%PROJECTNAME%`置換）へ改名。改名後の各ファイル書き込み先を`$Destination`配下に封じ込め、外れたら**書き込み前に**停止 |
| `ReplacementsInFiles` | 適用しない | `Extensions`のテキストfileで`%TEMPLATENAME%`→`<Name>`置換。置換後のfile名・pathも同じ封じ込めを通す |
| `SharedContentPacks` | `Templates/TemplateResources/<DetailLevel>/<Mount>/Content` → `Content/<Mount>`へコピー。mount先を`$Destination`配下に封じ込め、既存fileは上書きせず停止 | 同左 |
| `EditDetailLevelPreference` | 展開先のdetail level解決に使う。そのlevelに実体が無いmount（`TP_FirstPerson`の`Weapons`は`Standard`のみ）は、`High` → `Standard` の順で実在するlevelを選ぶ | 同左 |
| その他のキー（`FilenameReplacements` / per-mount `DetailLevels` 等） | 未実装（無声で無視）。規則解釈の忠実性は`DOT-3135`の担当 | 同左 |

封じ込め判定は`Resolve-ContainedPath`1つに集約し、`GetFullPath`で正規化したpathが出力ディレクトリ+区切り文字で始まるか（`OrdinalIgnoreCase`）で判定する。出力ディレクトリ自体の`Production/`内判定も同じ関数を使う。

| `FolderRenames` / `ReplacementsInFiles` / `FilenameReplacements` | 適用しない（project名/module名がtemplate名のまま残るため） | 適用 |

- `SharedContentPacks`はmountごとの`DetailLevels`宣言を先に試し、実体が無い場合だけ`EditDetailLevelPreference` → `High` → `Standard` の順にfall backする。fall backしたときは警告し、実際に使ったlevelと「宣言どおりか」を`template-lock.json`の`template_defs.shared_content_packs`（`mount` / `detail_level` / `declared`）に記録する。
- `FilenameReplacements`（**ファイル名**）と`ReplacementsInFiles`（**ファイル本文**）は別宣言であり、片方の`Extensions`をもう片方の判定に使わない。どちらも`From`/`To`/`bCaseSensitive`をtupleごとに使い、`%TEMPLATENAME%`系のtokenを展開する。`From`が一致しないtupleは何も置換しない。
- module名（`.uproject`の`Modules[].Name`）にも`ReplacementsInFiles`を適用する。`.uproject`はJSONであり`ReplacementsInFiles`の`Extensions`（`cpp`/`h`/`ini`/`cs`等）に含まれないため、module名の書換はidentity契約を保つための別処理として同じ宣言規則を適用する。宣言規則がmodule名に届かなければ生成後のidentity検査で非0停止し、未一致pathを列挙する。
- 上表に無いキー（`LocalizedDisplayNames` / `LocalizedDescriptions` / `Categories` / `ClassTypes` / `AssetTypes` / `bThumbnailAsIcon` / `SortKey` / `Variants` 等）はウィザードの表示・選択metadataであり、本generatorは使わない。**適用せず、警告して継続**し、`template-lock.json`の`template_defs.applied_keys` / `ignored_keys` / `unreadable_lines`に記録する。実engine templateはこれらを必ず含むため、停止ではなく警告とlock記録を選んでいる。
- "UEウィザードと同じ規則"とは書かない。公式文書にschemaが無く、engine同梱`TemplateDefs.ini`の実物との照合も限定的なので、実装範囲をキーの列挙で示す。

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

### redirect契約（素材を書き換えずに旧名を解決する）

Blueprintなどの`.uasset`はtemplateのままbyte単位でコピーする。生成物が旧クラス名を解決できるよう、generatorはウィザードと同じく2種類のredirectを`Config/DefaultEngine.ini`へ書く。

| 出力 | 対象 | 判定 |
|---|---|---|
| `[/Script/Engine.Engine] +ActiveClassRedirects=(OldClassName=...,NewClassName=...)` | コピーでファイル名が変わった reflected ヘッダ | 拡張子が`h`、**コピー後**の内容が`.generated.h"`を含む、元と生成後でベース名が違う（`GameProjectUtils.cpp` / `DefaultTemplateProjectDefs.cpp` の`IsClassRename`相当）。新旧名は置換規則から実際に生成された名前を使う |
| `[CoreRedirects] +PackageRedirects=(OldName="/Script/<Template>",NewName="/Script/<Name>")` | `/Script` package部分だけ | 常に出力。クラス名は変換しないため、上のclass redirectを置き換えてはならない |

どちらが何件出たかは生成時のstdout（`Class redirects: ...`行）で確認でき、`template-lock.json`は変更しない。`Test-UETemplateScaffold.ps1`は「改名した reflected ヘッダ数だけclass redirectが出る」「`h`だが`.generated.h`を含まないヘッダは出さない」「ファイル名が変わらない reflected ヘッダは出さない」「`+PackageRedirects`が残る」をassertする。

### project identity契約（1つだけ）

| 項目 | 契約 | 確認先 |
|---|---|---|
| projectファイル名 | `materialize_project`のrecipeは`<Name>.uproject`、生コピーのrecipeは`<EngineTemplate>.uproject`（`TP_FirstPerson` / `TP_BlankBP`）。どちらも`Source/<Module>/<Module>.Build.cs`と一致していること | 実ファイル、`template-lock.json`の`identity.project_file` |
| module名 | `.uproject`の`Modules[].Name`は`Source/<Module>/<Module>.Build.cs`と一致する。`materialize_project`なら`<Name>`、生コピーならtemplate名のまま | `identity.project_modules`、`Source/` |
| `EngineAssociation` | 空にしない。templateが値を持たない場合は`Engine/Build/Build.version`の`MajorVersion.MinorVersion`から導く | `identity.engine_association` |
| 置換不能時 | コピー前に照合し、既知パターンに一致しない場合は停止して未一致pathを列挙する。生コピーを黙って出力しない | generatorのstderr/例外、`scripts/Test-UETemplateScaffold.ps1`の負例 |
| 規約外の書き込み先 | `FolderRenames` / `SharedContentPacks` が出力ディレクトリの外を指す場合は書き込み前に停止し、外に残骸を残さない | generatorの例外メッセージ（`Container escape stopped the scaffold`）、`scripts/Test-UETemplateScaffold.ps1`の負例 |

lockは`schema_version: 4`で、上記3項目を`identity`に、template provenanceを`template_*`に持つ。単位は作品（`Production/<Name>_<runid>/template-lock.json`）であり、identityを手で書き換えない。

### lockが固定するengine build identity（`schema_version: 4`）

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

### 公開と完成マーカー

generatorは`Production/.stage-<runid>-<nonce>/`に全成果物を作り、最後に単一renameで`Production/<Name>_<runid>/`へ公開する。renameは既存パスを拒否するので、これが最終的な排他判定でもある。途中で失敗したrunは自分のstagingだけを削除して停止するため、`Production/<Name>_<runid>/`は部分出力を残さない。

`template-lock.json`は**完成マーカー**であり、最後に書かれる。生成直後に`template-lock.json`が無いディレクトリは未完成として扱い、完成projectと区別する。残骸（lockの無い公開済パス）の削除は、そのrunの失敗終端を確認できた場合に限る。他runの出力・他人のstagingを消さない。判断できない場合は停止し、観測したpathをQAへ記録する。
同じlockが、templateの`Config/TemplateDefs.ini`から実際に何を適用したかを追加fieldで記録する（schema_versionは据え置き）。

| field | 内容 |
|---|---|
| `shared_content_packs` | 出力`Content/`へ展開したmount名の配列。宣言が無いtemplate（`TP_BlankBP`）は空配列 |
| `shared_content_pack_detail_levels` | mount名 → 実際に展開元としたdetail level（例: `Weapons: Standard`） |
| `template_defs_ignore_rules` | 適用した`FoldersToIgnore` / `FilesToIgnore`の件数（`folders_to_ignore` / `files_to_ignore`） |
| `template_defs` | 適用したキー（`applied_keys`）、適用できなかったキー（`ignored_keys`）、解釈できなかった行（`unreadable_lines`）、`edit_detail_level_preference`、mountごとの`shared_content_packs`（`mount` / `detail_level` / `declared`） |

生成後の検査として、生成された`Config/DefaultEngine.ini`の`GameDefaultMap` / `EditorStartupMap`が`/Game/...`を指す場合、その`.umap`が出力に存在することを確認する。無ければgeneratorは停止して欠落pathを列挙し、`template-lock.json`を書かず`Created ...`も出さない。`/Engine/...`（engine content）を指す宣言は出力treeの対象外として検査しない。

## preflight・leaseの配置（正本）

生成前に書くもの（preflight記録とlease）の置き場所は1つだけにし、生成先`Production/<Name>_<runid>/`と重ねない。

`preflight-lease-placement: Production/.runs/run_<runid>/`

- このpathは生成先project dirの外にある台帳dir。`Production/*`はgitignore対象なのでclean-tree gateを踏まない。
- `Production/<Name>_<runid>/`を作るのはgeneratorだけで、lease工程はこのdirを作らない。中身が空でも`LEASE.json`だけでも`Out/`だけでも、generatorは「順序誤り」と判別できるメッセージで停止する（削除・上書きはしない）。
- 上の1行を機械可読な正本とし、`scripts/Test-UETemplateScaffold.ps1`が`AGENTS.md`・`README.md`・`docs/01-start.md`が同じpathを指していることを照合する。文書を変えるときはこの行を先に変え、他文書を追随させる。

### lockが固定するtemplate provenance（`schema_version: 4`）

| field | 意味 | 値を読むときの約束 |
|---|---|---|
| `template_repository` | 生成に使ったcheckoutの**実測**clone元（`git remote get-url origin`）。定数ではない | `null`は「clone元が不明」。公開repoを名乗らない。値がbundleのpathなら、そのbundleが正本であって公開repoではない |
| `template_source_kind` | `remote` / `local-path` / `bundle` / `no-remote` / `no-origin` のいずれか | `remote`以外は「第三者が同じものを取りに来られる場所」ではない。`no-origin`はremoteはあるが`origin`が無い（clone元不明）状態 |
| `template_commit` | 実際に生成したtemplate checkoutのHEAD SHA | **形式がSHAであることは到達性の証明ではない。**下記`template_commit_published`と組みで読む |
| `template_commit_published` | そのSHAを`template_repository`が配信できるかを`git fetch --depth 1 <repo> <sha>`で実測した結果 | `true`=取得できた。`false`=「not our ref」を実測（未push等）。`null`=**未検査**（bundle、probe不能、`-SkipTemplatePublishCheck`）。`null`を`true`と読まない・合格扱いしない |
| `template_worktree_dirty` | 生成時の作業ツリーがdirtyだったか | `true`は再現性なし。既定ではdirty自体が生成停止 |

生成の既定は「`template_commit_published`が`true`でなければ停止」である。停止するのは、未push commit、originの無いcheckout、`origin`がbundle、probeが答えを出せないoffline相当のいずれか。理由は毎回メッセージに出す。

この検査を通すための明示switchが2つあり、**どちらも「合格」を作らない。**

- `-AllowUnpublishedTemplate`: 停止せず生成し、lockに`template_commit_published`の**実測値**（`false`または`null`）を残す。生成物を第三者へ渡す前に、記録されたSHAを配信できる場所へpushし、新しいRunIdで再生成する。
- `-SkipTemplatePublishCheck`: probeを実行しない。lockは`null`（未検査）になる。repoに到達できないhostでの作業用で、未pushを隠すためのものではない。

## lockと更新手順

lockはtemplate commit SHA、clean/dirty状態、UE version/changelist、Engine/plugin version、recipe/use、作品差分、project identityを固定する。`recipe`/`purpose`はrecipe.jsonから、`plugins`は`required_plugins`から生成される。実作はcommit済み・cleanなtemplateから生成する。dirty時の生成は拒否し、テストだけ明示的な`-AllowDirtyTemplate`を使う。

lockはtemplate commit SHA、clean/dirty状態、engine template、UE version、engine build identity（`engine_changelist` / `engine_changelist_raw` / `engine_compatible_changelist` / `engine_is_licensee_version` / `engine_is_promoted_build` / `engine_branch_name`）、Engine/plugin version、recipe/use、作品差分、project identityを固定する。実作はcommit済み・cleanなtemplateから生成する。dirty時の生成は拒否し、テストだけ明示的な`-AllowDirtyTemplate`を使う。

lockはtemplate commit SHA、clean/dirty状態、UE version/changelist、Engine/plugin version、recipe/use、作品差分、project identity、適用した共有content packを固定する。`shared_content_packs`（展開したmount名）と`shared_content_pack_detail_levels`（mount → 実際に展開元としたdetail level）が「何を入れたか」の記録であり、packの宣言が無いrecipe（`TP_BlankBP`）では空配列になる。packのコピー挙動は変えない。実作はcommit済み・cleanなtemplateから生成する。dirty時の生成は拒否し、テストだけ明示的な`-AllowDirtyTemplate`を使う。

共通更新は新RunIdの空Production directoryへ生成し、既存projectを上書きせず、lock・作品差分・移行手順・対象版の検品結果を比較する。UE/Plugin更新の自動伝播はしない。

### 変更理由・移行手順の宛先（`CHANGELOG.md`）

上の「移行手順を比較する」は、差分を読んだ人が後から追える形で残さなければ意味がない。置き場はリポジトリ直下の `CHANGELOG.md` 1 つだけ（作品ごとの記録は作品の `QA.md` / `DELIVERY.json`）。`## ` 見出しは `## Unreleased — <DOT番号 or 名前> — <YYYY-MM-DD or 40桁SHA>` の形にし、識別子は必須。各節の本文に (1) 何が変わったか、(2) 移行が必要か（不要なら「移行不要」）、(3) Unverified Scope を 1 項目ずつ書く。識別子は日付を必須、SHA は書かれたときだけ `git cat-file -e <sha>^{commit}` で解決を検査する（CI の checkout が shallow で古い SHA を解決できないため）。

この宛先は読み取り経路からも名指す: `README.md` の「入口」表と `AGENTS.md` の「先に読む」の両方が `CHANGELOG.md` を指す。片方だけだと route が 2 系統になる。到達性と見出し書式は `scripts/Test-UETemplateDocs.ps1` が検査し、`.github/workflows/verify.yml` の `docs-route` job で回る。

**変更理由:** 共通環境の二重管理を避けながら、同じsetのプレイ/撮影と映像専用入口を小さく始める。生成時のdependency driftをlockで可視化し、template更新で制作中作品を壊さない。

lockは`schema_version: 3`で、上記3項目を`identity`に持ち、plugin identityを`plugins`に持つ。単位は作品（`Production/<Name>_<runid>/template-lock.json`）であり、identityを手で書き換えない。

### plugin identity契約（1つだけ）

| 項目 | 契約 | 確認先 |
|---|---|---|
| 記録範囲 | `plugins`は生成`.uproject`の`Plugins`配列の**全entry**を、`Name`の昇順で1件ずつ持つ。recipeの`required_plugins`だけを記録しない（template出来のpluginも載る） | 生成`.uproject`の`Plugins`、`template-lock.json`の`plugins`のkey集合 |
| 各entryの形 | `{ version, source, enabled_in_project }`。`version`はそのinstallの`.uplugin`の`VersionName`（空なら`Version`）、読めなければ文字列`unknown`。`source`は`project`／`repository`／`engine`。`enabled_in_project`は生成`.uproject`で`Enabled: true`かどうか | `plugins.<Name>`、実`.uplugin` |
| 実在検証 | 生成`.uproject`で`Enabled: true`のpluginは、コピー前に`.uplugin`の実在を確認する。存在しなければ**出力directoryを作らずに停止**し、未解決plugin名と探索したpathを列挙する | generatorの例外、`scripts/Test-UETemplateScaffold.ps1`の`PhantomPlugin`負例 |
| 探索順 | 生成projectの`Plugins/<Name>/<Name>.uplugin` → repoの`templates/online/<Name>/<Name>.uplugin` → engineの`Engine/Plugins/<Category>/<Name>/<Name>.uplugin` → `Engine/Plugins/**`の再帰探索。固定mapに無いplugin名でも止まらない | `plugins.<Name>.source` |
| 版を捏造しない | `.uplugin`から読めない版は`unknown`として残し、推測値・既定値を入れない。`engine_version`/`engine_changelist`は`Engine/Build/Build.version`のみを写し、plugin版を混ぜない | `plugins.<Name>.version` |

同一の`ProjectName`/`RunId`/`ProjectDiff`を、plugin集合か版が違う2つのEngine installで生成した場合、`plugins`が違うのでlockはbyte一致しない。

## lockと更新手順

lockはtemplate commit SHA、clean/dirty状態、UE version/changelist、Engine/plugin version、recipe/use、作品差分、project identityを固定する。「Engine/plugin version」は2つを指す — **Engine build**（`engine_version`/`engine_changelist`、`Engine/Build/Build.version`の写し）と、**生成projectがenableするpluginの版**（`plugins.<Name>.version`、各`.uplugin`の写し）。lockに載らないpluginは無い。実作はcommit済み・cleanなtemplateから生成する。dirty時の生成は拒否し、テストだけ明示的な`-AllowDirtyTemplate`を使う。

共通更新は新RunIdの空Production directoryへ生成し、既存projectを上書きせず、lock・作品差分・移行手順・対象版の検品結果を比較する。UE/Plugin更新の自動伝播はしない。

**変更理由:** 共通環境の二重管理を避けながら、同じsetのプレイ/撮影と映像専用入口を小さく始める。生成時のdependency driftをlockで可視化し、template更新で制作中作品を壊さない。plugin側のdriftも同じlockで見えるようにした（記録範囲を`.uproject`の実体に合わせ、存在しないpluginを有効化したまま成功しない）。

方式比較とsource別の費用・制約は[docs/08-online-foundations.md](08-online-foundations.md)。Null/LANを初期動作とし、EOS/Steamは設定と実測を満たす独立adapter候補として扱う。

初期は1repoで共通文書を参照し、再利用が実証された部品のみPlugin化する。深いBlueprint継承、ジャンルごとの全量fork、submoduleの大量追加は避ける。
作品には共通commit SHA・UE/Plugin版・レシピ・ローカル差分を記録する。lockの`template_commit`は「その値をlockが名指しするrepoから取得できると確認済み」の意味でしか使わない。確認できていないlockを配布しない。制作中の作品は固定版を使い、自動更新・上書きをしない。更新時は差分、移行方法、検品結果を残す。

納品記録（`CREDITS.md` / `DELIVERY.json`）は、作品の`Content/`を構成するasset群の**出所**を保持する。`DELIVERY.json`は`template_repository` / `template_commit` / `template_lock_sha256` / `recipe` / `engine_template` / `engine_version` / `engine_changelist` / `shared_content_packs` / `content_inventory`を持つ（既存fieldは削除・改名しない。未記入は`null`）。監査: `scripts/Measure-UECreditsInventory.ps1`（回帰: `scripts/Test-UECreditsInventory.ps1`）。

## 継続改善

Multicaの既存ボードと管理機会で「出典調査→候補→小さな検証→採否→変更理由・移行手順」を記録。公式仕様・掲示板の事例・当該host実測を区別する。未検証情報を既定値へ昇格しない。

「同梱する／しない」という主張は散文ではなく `docs/PROVENANCE.inventory.json` を正本とし、`scripts/Test-UETemplateProvenance.ps1` が tracked file と照合する（R1 虚偽の「無い」、R2 宙に浮いた「有る」、R3 未分類の新規層、R4 解決しない相対リンク）。新しい層や area を追加するときは同じ commit で inventory を更新し、`scripts/Test-UETemplateProvenance.Tests.ps1` の負例を回す。実績と未確認点の本文は [docs/PROVENANCE.md](PROVENANCE.md)。

作品には共通commit SHA・UE/Plugin版・レシピ・ローカル差分を記録する。制作中の作品は固定版を使い、自動更新・上書きをしない。更新時は差分、移行方法、検品結果を残す（repo 側の変更理由と移行手順は `CHANGELOG.md`、作品固有の差分は作品の `QA.md` / `DELIVERY.json`）。

## 継続改善

Multicaの既存ボードと管理機会で「出典調査→候補→小さな検証→採否→変更理由・移行手順」を記録。公式仕様・掲示板の事例・当該host実測を区別する。未検証情報を既定値へ昇格しない。採否に至った repo の変更理由と移行手順は `CHANGELOG.md` に残す（ここに書いて終わりにしない）。
Epic公式Custom TemplatesとPluginsを参考にするが、文書テンプレートはUE登録済みproject templateとは別物。

- https://dev.epicgames.com/documentation/en-us/unreal-engine/converting-a-project-to-an-unreal-engine-template
- https://dev.epicgames.com/documentation/en-us/unreal-engine/plugins-in-unreal-engine

課金、素材権利、認証、他作品の公開gateは変えない。オンラインサービスも無料枠・運用費・接続制約を都度確認し、無料保証をしない。
