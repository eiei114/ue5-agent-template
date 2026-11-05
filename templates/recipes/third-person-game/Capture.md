# 三人称ゲーム（同じセットで撮影）

- 撮影入口はプレイと同じ環境マップ/レイヤーを参照し、セットをコピーしない。
- カメラ/Sequence、撮影専用演出、露出・画質・MRQ presetを分離する。三人称カメラのspring armとHUDを撮影時に映さない。
- 書き出し前にpreviewと最終フレームを目視し、ffprobe・全編・継ぎ目・音を記録する。
- このrecipeはSequence、camera、levelなどの`.uasset`を生成しない。
