# 制作エージェント契約

## 先に読む

README → docs/01-start → 対象工程のdocs。現行Issue・owner指示・ホストの既存AGENTSも読み、矛盾を隠さない。文書は権限付与ではない。

## 最短ループ

1. Issueの納品種別（映像/実行版/ソース）と非目標、既存writerを確認。
2. online Windows Pi優先。OS/GPU/空き容量/既存UE/SDK/モデル・effort/利用枠/active runsを現地照合。Mac miniでbuild/render/downloadしない。
3. 新規 `Production/<Name>_<runid>/` を排他的作成。既存なら停止。既存project再開は所有権照合後、LEASE.jsonをCreateNew相当で取得。
4. 最初は追加素材なしの立方体・床・光・カメラ。小さいpreview→目視→調整→本番。UEテンプレートは当該hostの正規既存インストールから生成。
5. 映像はフレーム・全編・継ぎ目・音を検査。実行版はShipping梱包後、別フォルダ展開から起動・操作・5分測定。
6. CREDITS / QA / manifest / SHAを**同じ最終版**へ固定して納品。見た目未検品や旧版ZIPは完成でない。
7. 自分のrun所有processを同期回収し、自分のleaseだけ解放。共有Chromeは維持指示と所有権に従い触らない。

## 禁止・ゲート

- RoomSevenの稼働writer/Content/素材/Audio/downloadsに接触・複製しない。運用知識は本書に抽出済み。必要な既存tool mapの限定読取はそのhostで許可がある場合だけ。
- 新Claude/Anthropic割当は既定禁止。docs/02-runtimeのOpus例は過去案件固有の許可記録であり、汎用テンプレートの既定モデルにしない。
- 購入、credit消費、追加API billing、新認証・資格情報移送、GitHub作成/push/public/SNS/配布はそれぞれの現行許可を確認。既存案件の2credit許可を再利用しない。
- secrets、cookie、token、署名URL、auth.json、環境変数全体、生transcriptを読取/出力/commitしない。
- 既存writerへ割込まない。名前指定kill、leaseの時刻だけでの強制解除、他人のdirty差分のstash/restore/削除は禁止。
- run終了後に残すbuild/renderは不可。完了・安全停止を当該turn内で回収。
- `completed` は成果完成でない。未検証はUnverified、owner受入前はDoneにしない。

## フォルダ

```text
Production/<Name>_<runid>/
  <Name>.uproject / Config/ / Content/ / Source/ [Plugins/]
  Art/                 # 許可済み取得物。Gitテンプレートへ入れない
  Tools/               # 当該project用。秘密なし
  Out/run_<runid>/
    preview/ frames/ final/ staging/ extracted-check/ evidence/
    QA.md CREDITS.md DELIVERY.json SHA256SUMS.txt
  LEASE.json           # active所有者のみ。Git外
```

旧版は上書きしない。Out/_v1のような旧運用よりrun別の分離を推奨。Outに置いただけで納品とは呼ばない。
