# 三人称ゲーム（プレイ）

- 公式 `TP_ThirdPerson`（C++、全variant同梱）を、テンプレート自身の `Config/TemplateDefs.ini` の置換規則で `<ProjectName>.uproject` / `Source/<ProjectName>` へ実体化する。ファイル名の改名は `FilenameReplacements`、本文の置換は `ReplacementsInFiles` で、それぞれ別の `Extensions` と `From` / `To` / `bCaseSensitive` に従う（宣言規則が一致しなければ何も置換しない）。共有content pack（LevelPrototyping / Characters / Input）は mount ごとの `DetailLevels` で `Content/` へ入る。未実装の `TemplateDefs.ini` キーは警告として出るだけで、生成物は lock の `template_defs` で適用範囲を確認できる。
- Blueprintは `/Script/TP_ThirdPerson` 参照で保存されているため、`Config/DefaultEngine.ini` に `[CoreRedirects] +PackageRedirects` を追記する。消さない。
- ジャンル起点はvariantで選ぶ。例: アクション/ハンティング＝`Variant_Combat`、探索/アスレチック＝`Variant_Platforming`、街/生活＝基本 `ThirdPerson`（車両は ChaosVehicles を作品差分として追加）。選んだvariant・既定map・GameModeは `-ProjectDiff` と作品側に記録する。
- 生成直後は未build。Editor targetをbuildし、Playで歩行・カメラ・入力を確認するまでは Unverified。
- 実際のマップ、Pawn、入力、UI、ゲームルールは作品側で作成して検証する。
