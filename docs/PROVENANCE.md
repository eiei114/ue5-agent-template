# 根拠・検証範囲

本ファイルは repo 自身の「**実績と未確認点**」の正本である（[README](../README.md) の入口表）。scope 日付（最後に tree と照合した日）は 2026-11-13（JST）で、[PROVENANCE.inventory.json](PROVENANCE.inventory.json) の `last_reviewed` と同じ値にする。以後 tree が変わったら同じ PR で更新する。検証履歴の各行は、その行自身の測定日を持つ（scope 日付とは別）。

同梱物の有無は散文ではなく [PROVENANCE.inventory.json](PROVENANCE.inventory.json) を機械可読な正本とし、[scripts/Test-UETemplateProvenance.ps1](../scripts/Test-UETemplateProvenance.ps1) が tracked file と照合する。散文側の「同梱しない／する」は inventory の写しであり、判定は guard の結果で行う。

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

## このrepo自体

正本は [PROVENANCE.inventory.json](PROVENANCE.inventory.json)。tracked file の総数はこの文書に固定値を書かない（guard が毎回 `git ls-files -z` で実際の tree と照合するため）。

### 同梱する（実装物）

- **文書・運用記録**：`docs/`（着手・起動・素材・梱包・検品・納品・構造・online方式）、`AGENTS.md`、`README.md`、`CHANGELOG.md`、`LICENSE-NOTICE.md`
- **記録テンプレート**：`templates/CREDITS.md`、`templates/DELIVERY.json`、`templates/QA.md`
- **project generator と検品helper**：`scripts/New-UETemplateScaffold.ps1`（インストール済み Engine の公式 project template から `.uproject` を排他的に生成し、recipe 文書・`template-lock.json` を加える）、`scripts/Measure-UERenderArtifacts.ps1`（MRQ 後の画像列を encode 前に読み取り専用で照合）。いずれも同梱する UE 生成／検品 script であり、「script は同梱しない」は撤回した
- **回帰suite**：`scripts/Test-UETemplateScaffold.ps1`、`scripts/Test-UERenderArtifacts.ps1`、`scripts/Test-UETemplateProvenance.ps1`
- **lease 記録**：`scripts/Lease-UETemplateProject.ps1`（`Production/<Name>_<runid>/` の取得・所有権照合・解放の3動作）とその assertion `scripts/Test-UETemplateLease.ps1`
- **ジャンルrecipe と用途部品**：`templates/recipes/common/SET.md`、`spectator-explore`（`Play.md`＋`Capture.md`＋`recipe.json`）、`vertical-loop`（`Capture.md`＋`recipe.json`）、`third-person-game`（`Play.md`＋`Capture.md`＋`recipe.json`）
- **online 基盤（Null/LAN starter plugin）**：`templates/online/MulticaOnlineStarter/`（`.uplugin`、C++ module/Build.cs、GameMode/GameState/PlayerController/SessionSubsystem、UE automation test）
- **CI**：`.github/workflows/verify.yml`（provenance guard とその回帰 suite、scaffold suite、lease protocol、render-artifact suite を windows-latest で実行）
- **生成先の空プレースホルダ**：`Production/PLACEHOLDER.md`、`.gitignore`

### 同梱しない

- UE 本体・Engine の install 済み tree（`Engine/*`、`Content/*` など）。`EngineAssociation` は利用 host の既存 install から解決する
- build／render の本体（UBT・MRQ・ffmpeg・Shipping 梱包物）。手順と受入だけを文書化し、実体は同梱しない
- 素材実物：Fab／Splice／Mixamo／NCS 等の購入物・ライセンス asset（`.uasset`／`.umap`／`.fbx`／`.wav`／`.mp3`）、Room Seven の Content、映像成果物（`.mp4`）、配布物（`.zip`／`.pak`／`.utoc`／`.ucas`／`.bundle`／`.app`／`.exe`／`.dll`）
- 生成物と実行時 soil：`Production/<Name>_<runid>/`、`Out/`、`Art/`、`Saved/`、`Binaries/`、`Intermediate/`、`DerivedDataCache/`

### 検証記録の在処

ローカル bundle clone・相対リンク・禁止ファイル形状の点検結果は、この repo の tracked file には置いていない。現在の検証履歴は [docs/08-online-foundations.md](08-online-foundations.md) の「検証履歴」と `CHANGELOG.md` の該当項目、および各 Issue の comment 添付を参照する（存在しない検証記録ファイルを指さない）。Windows/MacBook Pi は初回参照時 offline。

## 層の対応表

層の定義と責務は [docs/07-architecture.md](07-architecture.md) を正本とする。ここでは「実装状態」と「未検証範囲」だけを対応づける。07-architecture は 8 行を宣言しており、この表は 6 行に集約している（三人称ゲームはジャンルrecipe の行、検品helper は共通基盤の行に含む）。

| 層（07-architecture の宣言） | tracked での実体 | 実装状態 | 未検証範囲 |
|---|---|---|---|
| 共通基盤 | `docs/01`〜`docs/06`・`docs/09`（動画モーキャプ）、`AGENTS.md`、記録テンプレート、lease 記録・検品helper | 文書・書式・画像列helper は実装済み。`Test-UERenderArtifacts.ps1` は合成PNG fixture で PASS | 実 MRQ 出力・ffprobe・映像/音/ループ継ぎ目の実測（Unverified Scope） |
| ジャンルrecipe | `templates/recipes/spectator-explore/`、`third-person-game/` | `spectator-explore` は生コピー、`third-person-game` は `TemplateDefs.ini` による materialize で実装済み | 実 Engine install での materialize 結果、生成物の Editor build／Play（生成器 fixture までしか検証していない） |
| 用途部品 | 各 recipe の `Play.md`／`Capture.md`、`templates/recipes/common/SET.md` | プレイ／撮影の差分を文書として分離済み | 実際に同一 set から両入口を開いた実測なし |
| 映像専用 | `templates/recipes/vertical-loop/`（capture-only） | 生成器・docref とも実装済み | MRQ 実行、尺・縦解像度・fps・出力先の実測、ループ継ぎ目の目視 |
| オンライン | `templates/online/MulticaOnlineStarter/`（Null/LAN） | plugin scaffold・session identifier の project scope・UE automation test まで実装済み | 2-client PIE、session create/find/join/leave、replication、切断復旧の実測。EOS/Steam は未実装 |
| project generator | `scripts/New-UETemplateScaffold.ps1`、`scripts/Test-UETemplateScaffold.ps1` | 排他作成・上書き禁止・project identity 照合・lock 記録を実装済み。suite は assertion group PASS | 実 UE install での全 recipe 生成と、生成直後の Editor 起動は限定的（`docs/08` の build 実績を参照） |

## 検証履歴（この repo の実績）

実施者の報告と本 round の再実行を区別して書く。`tested_sha` は git 読取・PowerShell 実行の証拠であり、UE 実行の証拠ではない。

| 日付 (JST) | 対象 | 結果 | 証拠クラス |
|---|---|---|---|
| 2026-11-01 | `TP_FirstPersonEditor Win64 Development` compile | PASS（UE 5.8.4 / CL 58902052、MSVC 14.44、37 actions、58.62 秒） | 実施者報告（[docs/08](08-online-foundations.md) の検証履歴）。本 round 再実行なし |
| 2026-11-02 | CodeRabbit 指摘の追加修復後の Editor build | 実施者報告では exit 0 / 37 actions / 94.22 秒、scaffold suite は通常・detached 両方で 5 assertion groups PASS | 実施者報告。`PROVENANCE.md` はこの実績を長く持っていなかったため本行で記録した。本 round で UE は起動していない |
| 2026-11-02 | project identity 契約と負例 | PASS（7 assertion groups、合成 Engine fixture） | 実施者報告（[docs/08](08-online-foundations.md)） |
| 2026-11-11〜12 | 動画モーキャプ（MediaPipe → VRMA → UE 5.9/VRM4U）、[docs/09](09-video-mocap.md) の実測 | 実施者報告。踊ってみた動画 1 本・571 フレーム・キャラ 1 体を UE 5.9 で通した。UE 5.8 系・別動画・別キャラは未検証 | 実施者報告（非公開の制作 repo `charakuru-dance-ue` の記録を抽出）。本 round で UE は起動していない |
| 2026-11-13 | `docs/PROVENANCE.md` と tree の一致 | 本 round の実測。修正後 tree は `PASS: R1`〜`R4` で exit 0。guard 追加前の tree（`a9e31bc`）は素のままでは `FAIL: inventory: the inventory file does not exist` で exit 2（guard は inventory を要求するので R1 まで到達しない）。当時の主張（`not_bundled` に `scripts/*`）を inventory として seed した同 tree では、R1 が `scripts/New-UETemplateScaffold.ps1` 等を検出して exit 1（seed は測定用の改変であり、a9e31bc そのものの出力ではない） | 本 round 実測（PowerShell と git のみ） |

UE の install / compile / Editor / PIE / MRQ / render / Shipping / packaged build は本 round で一切実行していない。上の UE 行はすべて実施者報告の引用であり、本 round の受入ではない。

## 切断時の追加指示

DOT-2946 thread `01a18fc3-63ee-739a-9b3b-f767e1c7e68d`（2026-10-31 11:21 JST、オーナー代理投稿）の指示により、AGENTSと着手手順へ「切断で停止せずコンピュータユーズで復旧・続行を試みる」を明記。所有権照合・操作後の画面確認は実施手順として具体化したもの。復旧実機成功・自動再接続実装の証拠ではない。既存の費用/認証/公開gateは変更しない。
