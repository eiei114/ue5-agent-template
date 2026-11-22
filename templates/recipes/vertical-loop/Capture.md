# 映像専用・縦型ショートループ

- 操作・HUD・ゲーム用Pawnは必須にしない。インストール済みの`TP_BlankBP`を起点にする。
- 共通セットの正本を一つ作り、Sequenceとカメラはそのセットを参照する。
- 開始案：1080×1920、30fps、8秒（240フレーム）。案件要件・実測で変更する。
- 末尾/先頭、カメラ・光・粒子・音の継ぎ目を全編再生で確認する。
- MRQのpreview/最終renderは目視とffprobeを記録する。書き出しは生成物へ同梱された`docs/05-qa.md`に従う（画像列検査、preset、encode/ffprobe、独立判定の分離はその文書にある）。書き出し経路は経路A（画像列＋既存ffmpeg）と経路B（MRQの`H.264 MP4 [8bit]`直接出力）のどちらでもよいが、経路・MRQの出力設定名・元PNG列の有無をQAへ記録する。経路Bは元PNG列が存在しない。
- 画像列検査helper `scripts/Measure-UERenderArtifacts.ps1` と `templates/CAPTURE-PRESETS.json` はsource checkout相対で、生成物には同梱されない。`template-lock.json` の `template_repository` / `template_commit` でsource checkoutを特定し、そのrootを作業directoryにして`docs/05-qa.md`のコマンドを実行する（参照閉包の規則はsource checkoutの `docs/07-architecture.md`、生成物には同梱されない）。
- このrecipeはSequence、camera、level、縦動画を含む`.uasset`/`.mp4`を生成しない。
