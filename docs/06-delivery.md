# 納品・リポジトリ公開

## 納品セット

同一版のMP4/thumbnailまたは実行版ZIP、README操作表、CREDITS、QA、DELIVERY.json、SHA256SUMS。
添付または許可済みprivate経路で本人が受け取れる状態を確認する。ローカルpathは納品URLではない。
Multicaでの納品はファイル添付＋最終comment1回。親へのACK/agent mentionは不要。公開/SNSの許可を推定しない。

## GitHub配置（未実行）

ownerがowner/repo・公開範囲・push対象を確定してから、許可された既存GitHub service連携で実行。既存repoがあればdefault branch/history/dirty差分を保護する。新repo名を推定して作らない。force-pushしない。
テンプレート公開前はtracked path一覧を再点検し、Production、Out、資格情報、素材・派生uasset、ライセンス文書の私用情報がないことを確認する。.gitignoreだけで防止できたと主張しない。
本テンプレートはコード/文書のOSSライセンスを勝手に選ばない。ownerのライセンス指定がない間は外部配布を保留。

## 受入

1. 文書/placeholder-only Git repo作成。
2. fresh cloneからリンク/placeholder漏れを検査。
3. 許可Windowsでdocs/01-startの小project smoke。可能なら同期Shipping/MP4まで。
4. GitHub URLとvisibilityをreadback。作成済み/commit済み/push済み/起動確認済みを別々に記録。
5. Issueをin_reviewへ。blockedや一部成果を完成/Doneにしない。
