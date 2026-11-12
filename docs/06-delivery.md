# 納品・リポジトリ公開

## 納品セット

同一版のMP4/thumbnailまたは実行版ZIP、README操作表、CREDITS、QA、DELIVERY.json、SHA256SUMS。
添付または許可済みprivate経路で本人が受け取れる状態を確認する。ローカルpathは納品URLではない。
複製元の雛形と中身の正本は次の表。各項目は `templates/` の実ファイルから作る。

| # | 項目 | 雛形（`templates/`） | 中身 |
|---|---|---|---|
| 1 | 同一版のMP4/thumbnail、または実行版ZIP | —（成果物そのもの） | 対象版の実体。SHA-256はファイルを閉じた後に採る |
| 2 | README操作表 | `templates/README.md` | 同一版の識別（対象版SHA-256）、起動/再生手順、実キーの操作表、既定解像度/fps/尺、前提、非目標、既知の不具合 |
| 3 | CREDITS | `templates/CREDITS.md` | 素材の権利・出典・配布範囲 |
| 4 | QA | `templates/QA.md` | 判定ごとのpass/fail/unverifiedと実測証拠。納品READMEが同一版を指すかを含む |
| 5 | DELIVERY.json | `templates/DELIVERY.json` | 成果物の `sha256` と `readme_receipt`（READMEのSHA-256と紐付け先） |
| 6 | SHA256SUMS | （下記の書式で作る） | 納品ファイルのSHA-256一覧。`SHA256SUMS.txt` |

`templates/` に無い項目を納品物と呼ばない。`templates/README.md` は必須物で、生成物にも手作業の納品にも同じ雛形を使う。
`SHA256SUMS.txt` は1行1ファイル（`<hex>  <filename>`）。README自身のhashも含める。README本文には自分のhashを書かない（自分の完成後のhashを自分の中へは書けないため）。READMEのhashと紐付け先は `DELIVERY.json` の `readme_receipt` とQAの該当行に記録する。
Multicaでの納品はファイル添付＋最終comment1回。親へのACK/agent mentionは不要。公開/SNSの許可を推定しない。

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
