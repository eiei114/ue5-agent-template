# QA記録（新規run用。未記入はUnverified）

Issue/run/日時/担当：
source commitまたはsnapshot SHA：
host/OS/UE/SDK/GPU/RAM/disk：
指定model/effort / 保存値 / 実session / 応答 / quota観測範囲：
writer/lease nonce・取得/解放receipt：

## 撮影preset（期待値の出所）

期待値は`templates/CAPTURE-PRESETS.json`のpreset定義から転記する。**ここに手書きした数値を期待値にしない。** 実測を見てから期待値を決めない。`fps × 秒数 = frame数`は定義側で導出され、`Measure-UECaptureEncode.ps1`が同じ定義で照合する。

```powershell
.\scripts\Get-UECaptureEncodePlan.ps1 -Preset <vertical|landscape>
```

| 項目 | 記入 |
|---|---|
| preset名（`vertical` / `landscape`） | |
| 期待frame数（preset定義の`fps × 秒数`） | |
| 期待秒数 | |
| 期待解像度（幅×高さ） | |
| 期待fps | |
| 期待画像列の範囲（start / end-exclusive） | |
| 期待値の転記元（`templates/CAPTURE-PRESETS.json`のpreset名と確認日） | |
| encodeに使った`-frames:v`の値と、それがpresetの期待frame数と一致するか | |

`-frames:v`は出力frame数の**上限**であり、尺の検証ではない。元画像列が短ければ短いままexit 0で出力される。

| 項目 | pass/fail/unverified/non-goal | 対象版/hash・実測・証拠 |
|---|---|---|
| 新規project生成・Editor build | unverified | |
| 初期map/camera・黒frameなし | unverified | |
| 視点/移動/zoom/collision/reset/help/終了 | unverified | 項目別に記録 |
| 最新版5分Play・性能 | unverified | 解像度/品質/平均/スパイク/測定時間 |
| ゲーム実音の聴取 | unverified | |
| エンコード前の画像列検査 | unverified | `evidence/frames-check.json`。start/end(exclusive)/命名/期待解像度、欠番・範囲外・曖昧名・0 byte・decode・解像度の各判定 |
| MRQ完了通知・exit code | unverified | 通知本文/exit。画像列検査とは別欄に記録 |
| MRQ/ffprobe実測 | unverified | 幅/高さ/fps/frame数/秒数/codec/音声 |
| MP4尺のpreset照合（`Measure-UECaptureEncode.ps1`） | unverified | `evidence/encode-check.json`。観測frame数/秒数/解像度/fps、`-frames:v`の値、不一致時の失敗category |
| 先頭/中間/末尾目視・全編再生 | unverified | |
| 映像と音のloop継ぎ目 | unverified | |
| Shipping成功・ZIP別展開起動/操作 | unverified | |
| Mac.app/architecture/署名/公証 | unverified | 必要な場合のみ |
| CREDITS/権利・同一版manifest・SHA | unverified | |

## 画像列・通知・MP4・目視・音の独立判定

1項目のpassを他項目へ読み替えない。特に次を守る。

- 通知成功/exit 0があっても、画像列の負例（欠番・余分なframe・0 byte・decode不能・解像度不一致）をpassにしない。
- 画像列がpassでも、render成功・全編目視・音・loopを合格にしない。
- MP4のframe数だけでは、元の画像列の欠番・余分を排除できない。
- **ffmpegのencodeがexit 0でも尺の合格にしない。** `-frames:v`は上限であり、短い画像列は短いMP4として成功裡に出力される。尺は`Measure-UECaptureEncode.ps1`がpreset定義と照合した結果で判定する。
- ffprobeが報告した値を見てから「期待値」を書き換えない。期待値はpreset定義のみ。
- 音声streamの存在は聴取ではない。
- 解像度や範囲を入力しなかった項目は`unverified`と書き、空欄のままpassにしない。

検査対象の画像列・run専用出力先・実施SHA・tool版を記録する。旧runの同数frame混入はこの検査だけでは判定できないため、run所有権の照合結果を別途残す。

残作業/次担当/再開条件：
run所有process終了・他人のprocess非干渉：
