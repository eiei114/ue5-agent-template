# 根拠・検証範囲

2026-10-31、DOT-2946でIssue本体と関係threadをMultica CLIから参照して抽出。素材/元project/認証はコピーしていない。記録は公開許諾ではない。

| 出典 | 抽出内容 | 証拠の限界 |
|---|---|---|
| DOT-2929 / comment 01a18bc7-e562-7ea6-ab87-a1c994aeff39 | AuraVertical_01a18bbf、8秒、240f、1080×1920/30、Out/Tools/Art、排他lease、MRQ | 過去workerの報告。今回render/全編再生なし |
| DOT-2929本文 / smoke 01a18bba、comment 01a18bbc | 正式thinking_level=xhighとcustom_args、拡張0.3.0 | API effort通信captureなし。新案件のClaude利用許可なし |
| DOT-2935 / thread 01a18d18-6d95-7859-9229-841ab05cdb46 | First Person C++、UE5.8.4系譜、黒い初frameの失敗、xhigh再現 | 初回Editor build成功はShipping完成ではない |
| DOT-2935 / thread 01a18d5f-ba57-7619-81e0-33f1c7addaa6 | CDP9223、Chrome起動script、Fab price詳細確認 | 当時のhost限定。新hostの実path/ログイン未確認 |
| DOT-2935 / thread 01a18d63-d4e7-7770-b999-11416e304647 | CLI実体/RoomSeven map区別、Splice同期basename、play8/hitch | sync scriptフルpath/引数未確定。音の聴取なし |
| DOT-2935 / thread 01a18d62-d52b-712c-ae6f-5c2f430671d9 | H264/AAC・10秒MP4、版ずれ防止、未所有credit gate | 当時の5分測定は旧版。素材実物を流用不可 |
| DOT-2936本文 / DOT-2941記録 | Windows主導準備、Mac SDK・実行先不足、sourceと.app区別 | Windows単独.app成功なし。キット受入は実Mac完成でない |
| 制作 repo `charakuru-dance-ue`（非公開）`docs/video-to-animation.md`・`docs/mediapipe-skeleton-workflow.md`、2026-11-11〜12 | 動画モーキャプの工程・補い方・実測（docs/09-video-mocap.md） | 1 本の動画・1 体のキャラ・UE 5.9 / VRM4U での実測。UE 5.8 系・別動画・別キャラは未検証 |
| Epic公式docs（各工程のURL、2026-10-31参照） | packaging段階、MRQ前提、UE5.8 Xcode表 | 公式仕様は当該hostの実証でない |
| Epic [macOS開発要件](https://dev.epicgames.com/documentation/en-us/unreal-engine/macos-development-requirements-for-unreal-engine) / Apple [Xcode対応表](https://developer.apple.com/support/xcode/)、2026-11-05参照 | UE5.8の最低/推奨macOS・プロセッサ・メモリ・Metal・Xcodeと、Xcode各版が要求するmacOS（docs/04-package.md、DOT-3220） | リンクと独自要約のみ。両表の不整合（Sonoma 14.5 対 Xcode 26.0）をどちらが誤記かは決めていない。Mac実機のbuild/署名は未検証 |

## このrepo自体

文書・運用記録テンプレートだけ。UE生成/build/render/アセット取得scriptは同梱しない。Windows/MacBook Piは初回参照時offline。
ローカルbundle clone・リンク・禁止ファイル点検の実結果は納品添付の検証記録を参照。

## 切断時の追加指示

DOT-2946 thread `01a18fc3-63ee-739a-9b3b-f767e1c7e68d`（2026-10-31 11:21 JST、オーナー代理投稿）の指示により、AGENTSと着手手順へ「切断で停止せずコンピュータユーズで復旧・続行を試みる」を明記。所有権照合・操作後の画面確認は実施手順として具体化したもの。復旧実機成功・自動再接続実装の証拠ではない。既存の費用/認証/公開gateは変更しない。
