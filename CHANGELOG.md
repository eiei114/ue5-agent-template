# 変更履歴

## Unreleased — DOT-2997

- エンコード前の画像列検査を追加。`scripts/Measure-UERenderArtifacts.ps1`が期待範囲（start/end-exclusive）と実ファイルの番号集合を照合し、欠番・範囲外・曖昧名・0 byte・decode不能・解像度不一致を検出する。読み取り専用で、既存画像の改名・修復・削除をしない。
- MRQ完了通知/exit、画像列、MP4、目視、音を独立した判定に分けた。通知成功やexit 0を画像列のpassへ、画像列のpassをrender/映像/音の合格へ読み替えない。
- decoderは既存環境の`ffprobe`を任意で使う。PATHに無ければ`-DecoderPath`で既存実体を指定し、無い・失敗・timeoutは`unverified`/`fail`のまま総合passにしない。新規導入はしない。timeoutは既定10秒、deadline超過は成功へ丸めない。
- `scripts/Test-UERenderArtifacts.ps1`で自作PNG fixtureの負例を固定。240枚そろっていても1枚欠番+末尾1枚超過の列をfailにすること、先頭/中間/末尾欠番、241枚目、桁数/拡張子の揺れ、0 byte、切り詰め・payload破損、解像度不一致、decoder不在/失敗/timeoutを確認する。
- 根拠：Epic公式Image Settings（frame offset/handle/frame step/終端排他を設定できる＝枚数だけで期待連番を決めない、2026-11-02参照）とFFmpeg公式（`-frames:v`は出力上限であり元画像列の整合性検査ではない）。いずれも当該hostの実測ではない。

移行: 新しいRunIdの`Out/run_<runid>/evidence/`へ検査reportを新規作成し、既存の作品・`Out`・画像列・MP4を上書きしない。旧runの画像列を対象にする場合は、所有権を照合してから新規出力先へreportだけを書く。UE実機のMRQ/ffprobe・render成功・映像/音/loopの実測は未検証（Unverified）。fixture成功はUE5.8.4動作確認ではない。

## Unreleased — DOT-2959

- 共通setを一つだけ使う鑑賞・探索（プレイ＋撮影）と、映像専用縦ループの2 recipeを追加。
- インストール済みUE公式project templateから新規projectを排他的に作るPowerShell generatorと、UE/plugin version・recipe/use・作品差分・template commitのlock記録を追加。
- Null/LAN用のserver-authoritative replication/session starter plugin、公式source付き方式比較、失敗/timeout手順を追加。

移行: template checkoutをcleanにし、新しいRunIdのscaffoldを生成する。`template-lock.json`と作品差分を比較してから手動で採用し、既存の生成project/Production/Outを再生成・上書きしない。EOS/Steamにはprovider固有実装、認証、service利用条件、実測を揃えるまで切替えない。
