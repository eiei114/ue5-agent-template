# 鑑賞・探索（プレイ）

- 操作可能なPawn、入力、衝突、リセット、終了の受入条件を作品単位で決める。
- プレイ入口から共通の環境マップ/レイヤーを一度だけ参照する。撮影用の複製マップは作らない。
- ゲーム用HUDと性能設定はこの用途差分に置く。撮影用カメラやHUDを常時有効にしない。
- 少人数LANの開始例は `docs/08-online-foundations.md` と
  `Plugins/MulticaOnlineStarter/README.md` を参照。Null/LAN以外は別途設定・検証する。
- `HostListenServer`には、手順で選択または作成したmapのpackage pathを渡す（例: `/Game/Maps/L_Lobby`）。`L_Lobby`自体は必須ではない。
- 実際のマップ、Pawn、入力、UI、ゲームルールは作品側で作成して検証する。
