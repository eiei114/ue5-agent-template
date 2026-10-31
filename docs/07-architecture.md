# 構造と更新

2026-11-01、owner包括承認により採用。巨大な全ジャンル共通実装ではなく、薄い共通基盤にレシピを組み合わせる。

| 層 | 責務 | 実装状態 |
|---|---|---|
| 共通基盤 | host・lease・環境構築・素材権利・検品・納品 | 既存docsと記録書式 |
| ジャンル差分 | 鑑賞・探索等の固有設定、受入条件 | 次工程で追加 |
| 用途部品 | プレイ／撮影。ジャンル別は両対応が基本 | 運用手順のみ |
| 映像専用 | 縦動画・ループ等、操作不要の入口 | 次工程で追加 |
| オンライン | 小人数listen server、セッション、replication | 調査・実装・実測は次工程 |

作品のセットは正本1つをプレイと撮影から参照し、撮影のためにマップ全体を複製しない。用途別の画質・カメラ・照明・UIの差分は明示する。

初期は1repoで共通文書を参照し、再利用が実証された部品のみPlugin化する。深いBlueprint継承、ジャンルごとの全量fork、submoduleの大量追加は避ける。
作品には共通commit SHA・UE/Plugin版・レシピ・ローカル差分を記録する。制作中の作品は固定版を使い、自動更新・上書きをしない。更新時は差分、移行方法、検品結果を残す。

## 継続改善

Multicaの既存ボードと管理機会で「出典調査→候補→小さな検証→採否→変更理由・移行手順」を記録。公式仕様・掲示板の事例・当該host実測を区別する。未検証情報を既定値へ昇格しない。
Epic公式Custom TemplatesとPluginsを参考にするが、文書テンプレートはUE登録済みproject templateとは別物。

- https://dev.epicgames.com/documentation/en-us/unreal-engine/converting-a-project-to-an-unreal-engine-template
- https://dev.epicgames.com/documentation/en-us/unreal-engine/plugins-in-unreal-engine

課金、素材権利、認証、他作品の公開gateは変えない。オンラインサービスも無料枠・運用費・接続制約を都度確認し、無料保証をしない。
