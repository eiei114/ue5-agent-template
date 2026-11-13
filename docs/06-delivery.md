# 納品・リポジトリ公開

## 納品セット

納品セットの正本は次の表だけ。各項目の雛形と`Out/run_<runid>/`のファイル名はここで決まり、`AGENTS.md`のフォルダ契約と`templates/`の実ファイルはこの表に従う（表を増やさず、規則を2箇所に書かない）。

| 納品物 | `Out/run_<runid>/`の配置 | 正本 |
|---|---|---|
| 映像（MP4） | `final/` | 生成物。雛形なし（検査は`docs/05-qa.md`） |
| thumbnail | `final/` | 生成物。雛形なし |
| ソースZIP | `final/` | 生成物。雛形なし（sourceは実行版ではない） |
| 実行版ZIP | `final/` | 生成物。雛形なし（梱包は`docs/04-package.md`） |
| README操作表 | `README.md` | `templates/README.md` |
| CREDITS | `CREDITS.md` | `templates/CREDITS.md` |
| QA | `QA.md` | `templates/QA.md` |
| 納品manifest | `DELIVERY.json` | `templates/DELIVERY.json` |
| 完全性manifest | `SHA256SUMS.txt` | 生成物。雛形なし（書式・検証はDOT-3065） |

- 映像納品と実行版納品のどちらでも、納品セットの`README.md`・`CREDITS.md`・`QA.md`・`DELIVERY.json`・`SHA256SUMS.txt`は同じ版で揃える。映像納品はMP4とthumbnail、実行版納品はZIPを加える。必須項目が1つでも欠けたら納品しない（種別によって不要な項目だけを省略する）。
- `README.md`は`templates/README.md`を複製して記入し、操作表・起動方法・同一版SHA・非目標・既知の不具合を空欄のまま残さない。記入後の`README.md`自身のSHA-256を`DELIVERY.json`の`readme_receipt`へ書く（受領証欄の定義は`templates/DELIVERY.json`）。
- 表の`正本`が`templates/`を指す項目は、実ファイルが無ければ納品セットが成立しない。`scripts/Test-UETemplateScaffold.ps1`が表・`AGENTS.md`の列挙・`templates/`の実ファイルを機械照合し、`templates/README.md`を消すと落ちる。
- `kind`の値は`templates/DELIVERY.json`の`artifact_kind_vocabulary`だけを使う。未定義の`kind`を増やさない。

添付または許可済みprivate経路で本人が受け取れる状態を確認する。ローカルpathは納品URLではない。
Multicaでの納品はファイル添付＋最終comment1回。親へのACK/agent mentionは不要。公開/SNSの許可を推定しない。

### CREDITSは`Content/`の出所を説明する義務を持つ

CREDITSは「素材を使っていない」という宣言ではなく、納品した作品の`Content/`を構成するasset群の**出所の記録**である。engine同梱templateから複製したcontentも共有content packから複製したcontentも、生成物には実在する。

- 記入契約は`templates/CREDITS.md`。`Content/`の先頭ディレクトリごとに1行、`出所区分 (origin)`と`同梱形態 (bundle)`を書く。未記入は Unverified で、「未使用」ではない
- mount名とdetail levelは`template-lock.json`の`shared_content_packs`から転記する（推測しない）
- template側の項目（`template_commit` / `template_repository` / `recipe` / `engine_version` / `engine_changelist` / `shared_content_packs`）は`templates/DELIVERY.json`の追加fieldとlockに書く

### 監査targetの規約

CREDITSは`Out/run_<runid>/`、`Content/`は1階層上のproject rootにある。**どちらをtargetにしても同じ結論になること**が要求され、片方だけの実行は監査の証拠にしない。

```powershell
powershell -NoProfile -File scripts\Measure-UECreditsInventory.ps1 -Target Production\<Name>_<runid>
powershell -NoProfile -File scripts\Measure-UECreditsInventory.ps1 -Target Production\<Name>_<runid>\Out\run_<runid>
```

- exit 0 = 通過 / 1 = 検出 / 2 = 入力不備（`CREDITS.md`不在、`Content/`か`CREDITS.md`が2つ以上解決できる）
- `Content/`のassetが1件以上あり、出所を述べた行が1件も無い → FAIL
- `Content/`の各先頭ディレクトリ名が、出所を述べた行に現れない → FAIL（group名を報告）
- `Content/`が無い作品（`vertical-loop`）はplaceholder 1行でPASS（偏陽性なし）
- 旧9列の表（`origin`列なし）はengine同梱contentを説明できないためFAIL（既存作品の書き換えを強制はしない。Unverifiedのまま）
- 回帰: `scripts/Test-UECreditsInventory.ps1`（fixtureは自作。engine同梱`.uasset`/`.umap`をrepoへ置かない）

## GitHub配置

ownerがowner/repo・公開範囲・push対象を確定してから、許可された既存GitHub service連携で実行。既存repoがあればdefault branch/history/dirty差分を保護する。新repo名を推定して作らない。force-pushしない。
本テンプレートの指定先 `eiei114/ue5-agent-template`・public作成/pushは2026-11-01のowner包括承認の範囲内。指定先への既存gh・通常git pushを利用できる。他repo、新認証、force-pushへの許可ではない。
コード/文書のOSSライセンスは勝手に選ばない。public配置と第三者への再配布許諾は別で、第三者素材の配布制限も維持する。

### 公開前の公開面監査（必須・実行コマンド）

公開・pushの前に、tracked path の形を機械的に監査する。判定は次の1コマンドだけで行う。

```powershell
./scripts/Test-UETemplatePublishSurface.ps1 -RepoRoot <公開するcheckout>
```

- **pass条件**: 終了コード `0` かつ `SUMMARY: tracked=<n> fail=0 warn=<m>`。
- **fail条件**: 終了コード `1`。`FAIL: <区分>: <path>` が1行1件で出る。区分は `generation-output`（`Production/` 等の生成先、`Production/PLACEHOLDER.md` だけ許可）/ `distribution-binary`（`.bundle` `.7z` `.exe` `.uasset` `.mp4` 等）/ `credential`（`auth.json` `.env*` `id_rsa` `*.pem` 等）/ `tracked-ignored`（index内かつexclude pattern一致）/ `link`（fresh cloneで解決できないMarkdownリンク）/ `placeholder`（`Production/PLACEHOLDER.md` の欠落）/ `environment`（gitを読めない・indexが空 等）。
- **exit 2**: 監査自体が実行できなかった（git worktree でない、indexが空、pathに `"` を含む）。**pass扱いにしない。**
- `WARN:` は失敗ではない。`git add -A` したら公開面に入る未追跡物（`untracked` / `untracked-distribution-binary` / `untracked-credential`）なので、commit前に読んで判断する。
- 結果は `docs/05-qa.md` のQAへ exit code ごと貼る。

`.gitignore` だけで防止できたと主張しない。理由を3つに分けて残す。

1. `git status --porcelain --untracked-files=all` が clean でも、**commit済みの禁止物は見えない**。オフライン引渡し用の `ue5-agent-template.bundle`、`Tools/helper.exe`、`backup.7z` をcommitしたfixtureでは、statusは0行、`git check-ignore` は3件とも "not ignored"（＝意図した文書と読める）、`git ls-files | grep -E '^(Production|Out)/'` は該当なし、で3通りともPASSする。
2. 強制追加した資格情報をworktreeから消すと `git status` は `D auth.json`（＝削除しただけ）に見え、`git check-ignore` も "not ignored" を返す。実際はindexに残り、fresh cloneに載る。git公式の `gitignore` NOTES も「追跡済みには効かない、`git rm --cached` が必要」と明記している。
3. `.gitignore` の一致判定は `core.ignorecase` に依存する。同じindexで `OUT/x.txt` `SAVED/a` `ART/a` `PRODUCTION/Proj/TP.uproject` を追跡した場合、本host（`core.ignorecase=true`）では `git ls-files -ci --exclude-standard` が4件を返すが、`core.ignorecase=false`（Linux runner相当）では0件になる。したがって判定は監査器自身のcase-insensitiveなpath規則が持ち、`ls-files -ci` は補助信号に留める。

pathに改行を含む追跡物は `git ls-files`（改行区切り）では分割されて壊れる。監査器は `git ls-files -z` で読む。
`.gitignore` の拡張（`*.bundle` `*.7z` `*.exe` `*.dll` `*.pdb` と未網羅の資格情報形状）は未追跡物の抑制だけを目的に置き、**公開可否の根拠にはしない**。

## 受入

1. 文書/placeholder-only Git repo作成。
2. fresh cloneからリンク/placeholder漏れを検査。実行コマンドは `./scripts/Test-UETemplatePublishSurface.ps1 -RepoRoot <fresh clone>`、pass条件は終了コード `0` かつ `fail=0`、fail条件は終了コード `1` と `FAIL: link` / `FAIL: placeholder` の出力（自然文の目視で代替しない）。リンクはindex上のpathと**大文字小文字を区別して**照合し、case-insensitiveなfilesystemでしか解決しないリンクはfailにする。
3. 許可Windowsでdocs/01-startの小project smoke。可能なら同期Shipping/MP4まで。
4. GitHub URLとvisibilityをreadback。作成済み/commit済み/push済み/起動確認済みを別々に記録。
5. Issueをin_reviewへ。blockedや一部成果を完成/Doneにしない。

source納品もREADME/CREDITS/QA/DELIVERY.json/SHA256SUMS.txtを同一版で揃え、source ZIPを加える（kind=`source_zip`）。push/public前はindex監査だけでなく `scripts/Test-UETemplatePublishSurface.ps1 -PushRevision HEAD` で配信する全履歴のpath形状も監査する。履歴にcredential等が残れば、indexから消しただけでは通過しない。
