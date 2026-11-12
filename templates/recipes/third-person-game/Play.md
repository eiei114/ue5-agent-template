# 三人称ゲーム（プレイ）

- 公式 `TP_ThirdPerson`（C++、全variant同梱）を、テンプレート自身の `Config/TemplateDefs.ini` の置換規則で `<ProjectName>.uproject` / `Source/<ProjectName>` へ実体化する。共有content pack（LevelPrototyping / Characters / Input）も `Content/` へ入る。
- 適用するのは `FoldersToIgnore` / `FilesToIgnore` / `FolderRenames` / `ReplacementsInFiles` / `SharedContentPacks` だけで、UEウィザードの全規則ではない（`FilenameReplacements` や per-mount `DetailLevels` は未実装。Epic公式docsに `TemplateDefs.ini` のschemaは無い）。
- `FolderRenames` / `SharedContentPacks` が出力ディレクトリ（`Production/<Name>_<runid>/`）の外を指す場合、generatorは**書き込み前に停止**する。生成先の外に残骸は残らない。共有packがテンプレート側の同名fileを持つ場合も、上書きせず停止する。
- Blueprintは `/Script/TP_ThirdPerson` 参照で保存されているため、`Config/DefaultEngine.ini` に `[CoreRedirects] +PackageRedirects` を追記する。消さない。
- ジャンル起点はvariantで選ぶ。例: アクション/ハンティング＝`Variant_Combat`、探索/アスレチック＝`Variant_Platforming`、街/生活＝基本 `ThirdPerson`（車両は ChaosVehicles を作品差分として追加）。選んだvariant・既定map・GameModeは `-ProjectDiff` と作品側に記録する。
- 生成直後は未build。Editor targetをbuildし、Playで歩行・カメラ・入力を確認するまでは Unverified。
- 実際のマップ、Pawn、入力、UI、ゲームルールは作品側で作成して検証する。
