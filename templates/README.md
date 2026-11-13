# README操作表（納品用の雛形。記入は利用許諾の代わりではない）

`Out/run_<runid>/README.md`へ複製して記入する。納品セットの正本はこの雛形で、`docs/06-delivery.md`の表が納品物の名前と正本を1箇所に定義する。記入後はSHA-256を採り、`DELIVERY.json`の`artifacts[]`と`readme_receipt`へ同じ値を書く。

未記入の欄を残したまま納品しない。書けない欄には`unverified`と理由を書く（空欄を合格にしない）。

## 作品

| 項目 | 記入 |
|---|---|
| 作品名 / Issue / run ID | |
| 納品種別（映像 / 実行版 / ソースZIP） | |
| 納品ファイル名 | |
| 対象版のSHA-256（MP4またはShipping ZIP） | |
| README自身のSHA-256（記入後に採る） | |
| host / OS / UE / plugin版 | |
| 制作日 / 記入者 | |

## 起動方法

- 実行版：`extracted-check/`へZIPを展開した後のexe名と起動引数、必要なPak/IoStore。
- 映像：再生するMP4のファイル名と尺（フレーム数と秒数）。
- 起動に必要な追加手順（作業dir、ショートカット、管理者権限の有無）。推定で書かない。手順を書ける根拠がない場合は`unverified`と書く。

## 操作表

実キーは作品のInput Action / `Config/DefaultInput.ini`を開いて確認し、この表を実機の値へ書き換える。確認せずに書いた行は`unverified`と記録する。

| 操作 | 入力（既定キー/デバイス） | 画面/挙動 | `docs/05-qa.md`の該当行 |
|---|---|---|---|
| 視点 | | | 視点/移動/zoom/collision/reset/help/終了 |
| 移動 | | | 同上 |
| zoom / 追加操作 | | | 同上 |
| reset | | | 同上 |
| help表示 | | | 同上 |
| 終了 | | | 同上 |

## 既定の表示

解像度 / fps / 尺 / 音声の有無 / 色空間。`docs/05-qa.md`の実測値と一致させる。食い違う場合は実測側を直すか、このREADMEへ未確認と書く。

## 前提

UE版 / plugin版 / 必要素材と権利範囲（`CREDITS.md`が正本）/ 必要disk / 追加インストールの有無。追加インストールが無い場合は「追加インストール不要」と明記する。

## 同一版であること

- 対象版（MP4またはShipping ZIP）のSHA-256と、このREADMEのSHA-256を両方書く。
- 同じ2つの値を`DELIVERY.json`の`artifacts[]`（`kind`は`artifact_kind_vocabulary`の語彙）と`readme_receipt`へ書く。
- SHA-256を採った後にZIP/MP4/READMEを編集したら採り直す。README自身のhashは最後に採る。
- 旧runのREADME・MP4・manifestの値を持ってこない。`Out/run_<runid>/`の同一版だけを指す。

## 非目標 / 未実装

この版でやらないと決めたこと、実装していない機能、未検証の範囲。`docs/05-qa.md`の`unverified`行と対応させる。非目標と未検証を「実装済み」と書かない。

## 既知の不具合

再現手順 / 影響 / 回避策 / 未修正であること。無い場合は「既知の不具合なし（未検証範囲は上）」と書く。見つけた不具合をREADMEから消さない。

## 権利

素材・音・フォントの扱いは`CREDITS.md`が正本。README自体は第三者READMEの流用ではなく、repoの記述と実機で確認した事実だけから作る。
