# 納品・リポジトリ公開

## 納品セット

納品セットの正本は次の表だけ。各項目の雛形と`Out/run_<runid>/`のファイル名はここで決まり、`AGENTS.md`のフォルダ契約と`templates/`の実ファイルはこの表に従う（表を増やさず、規則を2箇所に書かない）。

| 納品物 | `Out/run_<runid>/`の配置 | 正本 |
|---|---|---|
| 映像（MP4） | `final/` | 生成物。雛形なし（検査は`docs/05-qa.md`） |
| thumbnail | `final/` | 生成物。雛形なし |
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
