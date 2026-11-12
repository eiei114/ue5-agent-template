# QA記録（新規run用。未記入はUnverified）

Issue/run/日時/担当：
source commitまたはsnapshot SHA：
host/OS/UE/SDK/GPU/RAM/disk：
指定model/effort / 保存値 / 実session / 応答 / quota観測範囲：
writer/lease nonce・取得/解放receipt：

| 項目 | pass/fail/unverified/non-goal | 対象版/hash・実測・証拠 |
|---|---|---|
| 新規project生成・Editor build | unverified | |
| 初期map/camera・黒frameなし | unverified | |
| 視点/移動/zoom/collision/reset/help/終了 | unverified | 項目別に記録 |
| 最新版5分Play・性能 | unverified | 解像度/品質/平均/スパイク/測定時間 |
| ゲーム実音の聴取 | unverified | |
| エンコード前の画像列検査 | unverified | `evidence/frames-check.json`。start/end(exclusive)/期待解像度、欠番・範囲外・曖昧名・0 byte・decode・解像度の各判定。MRQの`Output Frame Step` / `Frame Number Offset` / `Handle Frame Count` / `Zero Pad Frame Numbers` / `File Name Format`の実値と、helperへ渡した`-FrameStep` / `-FrameNumberOffset` / `-Digits`も同じ欄に書く |
| MRQ完了通知・exit code | unverified | 通知本文/exit。画像列検査とは別欄に記録 |
| MRQ/ffprobe実測 | unverified | 幅/高さ/fps/frame数/秒数/codec/音声 |
| 先頭/中間/末尾目視・全編再生 | unverified | |
| 映像と音のloop継ぎ目 | unverified | |
| Shipping成功・ZIP別展開起動/操作 | unverified | |
| Mac.app/architecture/署名/公証 | unverified | 必要な場合のみ |
| CREDITS/権利・同一版manifest・SHA | unverified | |

## 画像列・通知・MP4・目視・音の独立判定

1項目のpassを他項目へ読み替えない。特に次を守る。

- 通知成功/exit 0があっても、画像列の負例（欠番・余分なframe・0 byte・decode不能・解像度不一致）をpassにしない。
- 画像列がpassでも、render成功・全編目視・音・loopを合格にしない。
- 画像列のfailは2種類に切り分ける。**成果物の不備**（欠番・余分なframe・0 byte・decode不能・解像度不一致）と、**`index_lattice_mismatch`**（画像列は規律正しい等差数列だが、宣言した`FrameStep`と公差が違う＝renderは正常でhelper入力が違う）である。後者を「240枚欠番」と読んで再renderしない。MRQの`Output Frame Step`を確認し、同じ値で再検査する。
- MP4のframe数だけでは、元画像列の欠番・余分を排除できない。step格子を`%06d`連番templateでencodeすると、ffmpegは**exit 0のまま1frameのMP4**を作る。尺と`nb_read_frames`を必ず見る。
- 音声streamの存在は聴取ではない。
- 解像度や範囲を入力しなかった項目は`unverified`と書き、空欄のままpassにしない。

検査対象の画像列・run専用出力先・実施SHA・tool版を記録する。旧runの同数frame混入はこの検査だけでは判定できないため、run所有権の照合結果を別途残す。

残作業/次担当/再開条件：
run所有process終了・他人のprocess非干渉：
