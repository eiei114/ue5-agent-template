# 納品README操作表（記入は納品の代わりではない）

受け取った人が**同じ版**を起動・再生し、**何を押すと何が起きるか**を自分で確かめるための1枚。
新規runの `Out/run_<runid>/README.md` へ複製して記入する。未記入欄は `Unverified` と書き、空欄のまま納品しない。
値は `docs/04-package.md`（梱包）と `docs/05-qa.md`（検品）の実測から写す。web上の一般論や推測を書かない。
納品セットの正本は `docs/06-delivery.md`。このファイルはそのうちREADME操作表の雛形で、置き場所と受領証の契約もそちらに従う。

## 1. 同一版の識別

| 項目 | 値 |
|---|---|
| 作品名 | （`Production/<Name>_<runid>/` の `<Name>`） |
| Issue / run ID | |
| 納品種別 | 実行版ZIP / MP4 / Mac source ZIP（当てはまるもの） |
| 対象版のファイル名 | |
| 対象版の SHA-256 | |
| 対象版を採った日時・host | |
| 対象版の UE / plugin 版 | （`Engine/Build/Build.version` と `template-lock.json` の `plugins` から） |

SHA-256 は対象版を閉じた後に採る（PowerShell `Get-FileHash -Algorithm SHA256 <file>`）。採った後にZIPやMP4を編集したら採り直す。`docs/04-package.md` の手順どおり、ZIPは閉じてから、MP4はエンコード完了後に採る。

**README 自身の SHA-256 は本文に書かない。** ファイルは自分の完成了後のhashを自分の中へ書けないため、READMEのhashは `templates/DELIVERY.json` の `readme_receipt.sha256` と、QAの「納品READMEが同一版を指すか」の行に記録する。本文には「対象版のSHA-256」と「紐付け先のファイル名」を書き、両者が同じ版を指すことをその2箇所で証明する。

## 2. 起動 / 再生

| 納品種別 | 手順 |
|---|---|
| 実行版（Windows Shipping ZIP） | 新規フォルダ（例 `Out/run_<runid>/extracted-check/`）へZIPを展開し、**そのフォルダから**Shipping exeを起動する。UEや元sourceの絶対pathへ依存していないことをここで確認する。起動引数を使う場合は実引数をそのまま書く。 |
| 実行版（起動引数） | 例: `<Shipping exe> -log -windowed -ResX=<幅> -ResY=<高>`。実際に使った引数だけを書き、未使用なら「引数なし」と書く。 |
| 映像（MP4） | 対象MP4をプレイヤーで開く。数値は同じファイルを `ffprobe` で測り、`docs/05-qa.md` の例どおりに記録する。 |
| Mac source ZIP | source ZIPは**実行版ではない**。実行版はMac側でbuild/cook/stageした `.app` だけを指す。source ZIPしか無い場合は「実行版なし（sourceのみ）」と明記する。 |

## 3. 操作表（実キー）

`docs/05-qa.md` のPlay検品項目（視点・移動・zoom・collision・reset・help・終了）を、**この版の実キー**で埋める。未実装の項目は空欄にせず「非目標」と書き、合格へ読み替えない。

| 操作 | キー / 入力 | 期待する結果 | 実測（対象版での確認） |
|---|---|---|---|
| 視点（mouse look） | | | |
| 移動（前後左右） | | | |
| zoom（往復） | | | |
| collision（台・壁・外周） | | | |
| リセット | | | |
| help 表示 | | | |
| 終了 | | | |

## 4. 既定の解像度・fps・尺

| 項目 | 値 | 出典 / 測り方 |
|---|---|---|
| 解像度（幅×高さ） | | MRQ preset の実値、またはPlay画面の実測 |
| fps | | MRQ preset の実値（`docs/05-qa.md` の初期提案は縦1080×1920 / 30fps / 8秒=240frame。実測値ではない） |
| 尺（frame数 / 秒） | | 同じMP4の `ffprobe`（`nb_read_frames` / `duration`） |
| codec / 音声 | | `ffprobe`。音声streamの存在は聴取の証明ではない |

## 5. 前提

| 項目 | 値 |
|---|---|
| UE 版 | （例 5.8.4 / CL 58902052。`Engine/Build/Build.version` から） |
| plugin 版 | `MulticaOnlineStarter` の `VersionName`（`template-lock.json` の `plugins`） |
| 必要素材 | `CREDITS.md` に載せた実素材のみ。placeholderのみなら「実素材なし」 |
| host / OS / GPU / RAM / disk | |
| 実行に必要なもの | Shipping exe / MP4プレイヤー / Mac `.app`（納品種別に合わせる） |

## 6. 非目標 / 未実装

- 例: online は Null/LAN のみで、EOS/Steam 接続は非目標（`docs/08-online-foundations.md` の範囲）。
- 例: PIE・2-client・MRQ実render・Shipping実起動をこのhostで実行していない項目は、`Unverified` としてQAに残す。

## 7. 既知の不具合

| 症状 | 再現条件 | 回避策 | 記録先 |
|---|---|---|---|
| | | | |

## 8. 記録の対応

| 記録 | 何を持つか |
|---|---|
| `README.md`（本書） | 操作表・起動方法・対象版SHA-256・非目標・既知の不具合 |
| `QA.md` | 判定ごとの pass/fail/unverified と実測証拠（READMEの同一版行を含む） |
| `DELIVERY.json` | 成果物の `sha256` と `readme_receipt`（READMEのSHA-256と紐付け先） |
| `CREDITS.md` | 素材の権利と出典。READMEの「必要素材」はここだけを指す |
| `SHA256SUMS.txt` | 納品ファイルのSHA-256一覧（書式は `docs/06-delivery.md` に従う） |
