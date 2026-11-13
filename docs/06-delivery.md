# 納品・リポジトリ公開

## 納品セット

同一版のMP4/thumbnailまたは実行版ZIP、README操作表、CREDITS、QA、DELIVERY.json、SHA256SUMS。
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
テンプレート公開前はtracked path一覧を再点検し、Production、Out、資格情報、素材・派生uasset、ライセンス文書の私用情報がないことを確認する。.gitignoreだけで防止できたと主張しない。
本テンプレートの指定先 `eiei114/ue5-agent-template`・public作成/pushは2026-11-01のowner包括承認の範囲内。指定先への既存gh・通常git pushを利用できる。他repo、新認証、force-pushへの許可ではない。
コード/文書のOSSライセンスは勝手に選ばない。public配置と第三者への再配布許諾は別で、第三者素材の配布制限も維持する。

## 受入

1. 文書/placeholder-only Git repo作成。
2. fresh cloneからリンク/placeholder漏れを検査。
3. 許可Windowsでdocs/01-startの小project smoke。可能なら同期Shipping/MP4まで。
4. GitHub URLとvisibilityをreadback。作成済み/commit済み/push済み/起動確認済みを別々に記録。
5. Issueをin_reviewへ。blockedや一部成果を完成/Doneにしない。
