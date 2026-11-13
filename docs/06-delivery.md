# 納品・リポジトリ公開

## 納品セット

同一版のMP4/thumbnailまたは実行版ZIP、README操作表、CREDITS、QA、DELIVERY.json、SHA256SUMS。
添付または許可済みprivate経路で本人が受け取れる状態を確認する。ローカルpathは納品URLではない。
Multicaでの納品はファイル添付＋最終comment1回。親へのACK/agent mentionは不要。公開/SNSの許可を推定しない。

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
