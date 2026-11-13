# 鑑賞・探索（プレイ）

- 操作可能なPawn、入力、衝突、リセット、終了の受入条件を作品単位で決める。
- プレイ入口から共通の環境マップ/レイヤーを一度だけ参照する。撮影用の複製マップは作らない。
- 生成物の`Content/`には、`TP_FirstPerson`が宣言する共有content pack（`Characters` / `LevelPrototyping` / `Input` / `Weapons`）が入る。既定map（`/Game/FirstPerson/Lvl_FirstPerson`）はこれらを参照するので、`Content/`から該当mountが消えている生成物は開く前に作り直す（欠落したままPlayしない）。どのpackが入ったかは`template-lock.json`の`shared_content_packs`で確認する。
- `Config/TemplateDefs.ini`と`Media/`はtemplate側のignore規則で出力に入らない。これらを手で戻さない（戻すと次回再生成時の比較が崩れる）。
- 生成直後は未build。Editor targetをbuildし、Playで視点・移動・ズーム・衝突・リセット・終了を確認するまではUnverified。
- ゲーム用HUDと性能設定はこの用途差分に置く。撮影用カメラやHUDを常時有効にしない。
- 少人数LANの開始例は `docs/08-online-foundations.md` と
  `Plugins/MulticaOnlineStarter/README.md` を参照。Null/LAN以外は別途設定・検証する。
- `HostListenServer`には、手順で選択または作成したmapのpackage pathを渡す（例: `/Game/Maps/L_Lobby`）。`L_Lobby`自体は必須ではない。
- 実際のマップ、Pawn、入力、UI、ゲームルールは作品側で作成して検証する。
