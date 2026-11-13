# 変更履歴

## Unreleased — DOT-3117

- `templates/QA.md` が、repo 自身が要求する受入項目のうち10項目（起動map・Pawn・開始姿勢、座位/立位、host の session 作成、2 人目 client の join、score と player count の replication、client leave、reconnect、failed search、timeout）に対応する行を持っていなかった。行が無ければ検品者はその欄自体を書かないため、`docs/05-qa.md:36` の「合否・版/hash・実施者・日時・証拠・未確認をセットにする」を満たさないまま `Out/run_<runid>/` の QA が納品セットに入った。行を追加し、各行に機械検査用の `[QA-...]` ID を付けた。
- online/LAN 行は `spectator-explore` 使用時のみ対象で、他の recipe は `non-goal` を記録することを雛形の冒頭と行本文の両方に明記した。実接続を実施していない `spectator-explore` の run は `unverified` のままとし、`non-goal` へ読み替えないことも書いた。
- timeout は「timeout の発生」（`QA-NET-08`）と「timeout 後の後始末」（`QA-NET-09`）を別行にした。`docs/08-online-foundations.md` が遅延成功した create/join の cleanup を独立の主張として扱っているため、片方の pass でもう片方を埋めない。
- `scripts/Test-UETemplateScaffold.ps1` に QA 雛形の行被覆 assertion を追加した。要求 24 行の存在、行 ID の重複なし、値が `pass`/`fail`/`unverified`/`non-goal` の 4 択であること、online 行が `spectator-explore` 限定と `non-goal` を明記していること、timeout の 2 行が別の主張であることを検査する。**負例**として fixture 内のコピーから `QA-NET-02`・`QA-NET-09`・`QA-PLAY-01`・`QA-BUILD-01` を 1 行ずつ削り、それぞれ欠けた行 ID を名指しで落ちることを同じ suite で固定した。`unverified` を `ok` へ書き換えた負例も追加した。
- `docs/05-qa.md` の末尾に、QA 雛形の表の行が受入項目の正本であることと、recipe により `non-goal` になりうることを追記した。
- `scripts/Test-UETemplateScaffold.ps1` の QA 行パーサが `\|`（Markdown の escape された pipe）も列区切りとして扱っており、証拠欄に `\|` を書いた行だけが 3 列でなくなり、行検査から静かに外れていた。未エスケープの `|` だけで分割するよう直し、証拠欄に `\|` を入れた雛形が行として認識され続けることを suite の assertion にした。

移行: 既存生成物の QA は書き換えない。旧 run の QA は当時の雛形のまま残し、新しい受入項目の行は次の run から使う。`templates/DELIVERY.json` の field、recipe の中身、online plugin の C++、UE Content には触れていない。

実測（本 host、Windows、Windows PowerShell 5.1.26100.9711 と `pwsh 7.6.9` の両方、repo SHA `adfb5eebab9d1a3d90a60928ee31bfa35cb20b4a`、`templates/QA.md` の変更前 sha256 `AC1C02940CD6639C4CE451C4EF83A18E7E210D219D9031605F5C3D74470DC277` / 変更後 `D24FE74633EEC8649406C259B4E678177C177DCCF03BF28AF5511EEE1A72800D`）: `scripts/Test-UETemplateScaffold.ps1` は 11 group PASS / exit 0（既存 8 group を含む）。負例は 4 行それぞれ `required acceptance row <id> is missing` で exit 1、値の負例は `row QA-MRQ-01 uses 'ok' …` で exit 1 になることを、`a9e31bc` の clone に新 suite を当てて確認した（`QA template contract violated: … the table carries 11 data rows, fewer than the 24 required acceptance rows …` で exit 1）。suite 前後の `git status --porcelain --untracked-files=all` は同一（この変更の 4 ファイルのみ）。**UE install / compile / Editor / PIE / MRQ / render / Shipping / 実 LAN 接続は一切実行していない**（Unverified Scope）。行があることは 2-client 接続の実測ではない。

## Unreleased — DOT-3119（UE-PROV-001）

`template-lock.json`が「公開repoのcommit」を名乗りながら、未pushのcommitを書いていた問題を修正した。旧generatorは`template_repository`を文字列定数で固定し、`git rev-parse HEAD`の値を無条件に`template_commit`として書いていたため、bundle clone・fork・remote無しのcheckoutから生成してもlockは公開repoを名乗り、そのSHAは公開repoからは取得できなかった。

- `scripts/New-UETemplateScaffold.ps1`
  - `template_repository`は**実測値**。`git remote get-url origin`の結果を書き、remoteが0本なら`null`、`origin`が無い場合は`null`、`origin`がlocal pathならそのpath、`*.bundle`ならbundleのpath、URL/SSHならそのURL。定数は廃止した。
  - `template_source_kind`を追加（`remote` / `local-path` / `bundle` / `no-remote` / `no-origin`）。
  - `template_commit`の**到達性検査**を追加。使い捨てのbare repoへ`git fetch --depth 1 <template_repository> <sha>`を実行し、取得できた場合だけ既定経路が成功する。lockには`template_commit_published = true|false|null`を残す。`false`は「not our ref」の実測、`null`は未検査（bundle・probe不能）であり、`null`を公開済みと読ませない。
  - 明示switchを2つ追加。`-AllowUnpublishedTemplate`（停止せず生成しlockに実測の`false`/`null`を残す）と`-SkipTemplatePublishCheck`（probeせず`null`を残す）。どちらも`true`を作らない。
  - `schema_version`を`3`→`4`へ（`template_*` 追加のため）。
- `scripts/Test-UETemplateScaffold.ps1`
  - provenance群を追加。fixture remoteを持つ使い捨てrepoで「push済み / 未push / remote無し / bundle clone」の4状態を**実際に生成**し、既定の停止とlockの中身をassertする。
  - `template_commit`のassertは「40桁hexか」から**fixture remoteからそのSHAを実際に`git fetch`できること**へ置き換え、全ゼロSHAがkillされることを固定した（旧suiteはM6変異を見逃していた）。
  - `template_repository`のassertは0件だったため、実測origin・source kind・`published`の3値のassertを追加した。
  - 既存群（dirty template / game+capture / vertical-loop / path traversal / engine build identity / 既存出力保護）は回帰で維持し、suiteは17群PASS（PR #20のbase時点13群＋provenance 4群。両shell実測、2026-11-12）。
- `docs/07-architecture.md`: lockの`template_*`の意味と、`null` = 未検査で合格ではないことを明記。`docs/01-start.md` / `AGENTS.md` / `README.md`: 同じ契約と、lockを第三者へ渡す前の条件を記載。

旧lockは**書き換えない**。`schema_version: 4`のlockが`template_commit_published: true`を持つ場合だけ、`template_commit`がlockの名指しするrepoから取得できると読める。`schema_version: 3`以下のlockはこの保証を持たないので、新契約が必要な作品は新RunIdで再生成し、旧lockとparse後のfieldで比較して採用する。

`schema_version`の順序: `main`は`2`なので、本変更は`4`を使う。競合して未マージのUE-LOCK-001（DOT-3114、PR #20）が`3`を使っているため、`3`は予約であり、どちらが先にマージされても残った側が**単調増加**で再採番する（本PRが先なら#20が`5`、#20が先なら本PRをrebaseして`5`）。どちらも`schema_version`の値で新旧を判別できる。

## Unreleased — DOT-3114

`template-lock.json`のengine build identityを、UE自身の規則と一致させた。旧generatorは`Build.version`／`.uplugin`に存在しないfieldを`0`／`""`へ黙って変換してlockに書いており、実測で**Engine installが異なる2つの生成物がbyte一致のlock**を持っていた。

- `scripts/New-UETemplateScaffold.ps1`
  - `Build.version`の`MajorVersion`／`MinorVersion`／`PatchVersion`を`PSObject.Properties`で存在確認し、欠落または非数値なら**停止**。`'5.8.'`のような壊れた版文字列を成功出力しない。
  - `engine_changelist`をUEの`FBuildVersion::GetEffectiveCompatibleChangelist()`（`Engine/Source/Runtime/Core/Private/Modules/BuildVersion.cpp:21-24`）と同じ規則（両方が非0なら`CompatibleChangelist`、それ以外は`Changelist`）で導出。生値も`engine_changelist_raw`／`engine_compatible_changelist`／`engine_is_licensee_version`／`engine_is_promoted_build`／`engine_branch_name`として併記する。
  - `Changelist`キー自体が無い場合は導出を中止し、`engine_changelist`／`engine_changelist_raw`／`engine_changelist_source`をJSON `null`にする。UEのparserは省略を既定値0として扱うが、「ファイルが0と書いた」と「ファイルが何も書いていない」は別の証拠なので0へ倒さない。
  - `CompatibleChangelist`／`IsLicenseeVersion`／`IsPromotedBuild`／`BranchName`は存在するときだけlockに載せ、無い場合は`null`。`BranchName`は空文字も`null`へ正規化。
  - plugin版は`VersionName`→`Version`の順に読み、両方とも未設定または空なら`plugins.<name> = null`（`""`ではない）。
  - `schema_version`を`2`→`3`へ。
- `scripts/Test-UETemplateScaffold.ps1`
  - fixtureの`Build.version`をEpic実形状（`Changelist:58902052` + `CompatibleChangelist:55116800` + `IsLicenseeVersion`/`IsPromotedBuild`/`BranchName`）へ。`Changelist`単独形も併置。
  - 追加group: (a) 必須field欠落＋非数値で停止、(b) `Changelist:0`＋`CompatibleChangelist`のみの実形状で導出値と生値が両方正しく載る、(c) **`CompatibleChangelist`だけが異なる2 installでlockがbyte一致にならない**、(d) 必須版field欠落で停止、(e) plugin版未設定が`null`、(f) `Changelist`キー欠落が`null`、(g) 整形だけが違うlockのsemantic比較。
  - 既存5群（dirty template / game+capture / vertical-loop / 版field負例 / 既存出力保護）は回帰で維持。
- `docs/07-architecture.md`: lockが固定するengine build identityを実field名で列挙し、`null` = 不明、0/空文字は「エンジンがそう書いた」値だけと明記。lock比較は**semantic比較**とし、byte比較は同一shell・同一入力に限定する理由（`ConvertTo-Json`の整形差でcross-shellのsha256が異なる）を記載。
- `docs/01-start.md`: 「不明を0や無料と扱わない」がQA記録だけでなくgeneratorのlockにも適用されることを明記。
- 移行: 既存生成物のlockは書き換えない。新しいengine build identityが必要な作品は**新RunIdで再生成**し、旧lock（`schema_version: 2`／`1`）と新lockをsemantic比較して差分を`QA.md`に記録する。`schema_version`で新旧を判別でき、旧lockを手で編集しない。

本host実測（Windows PowerShell 5.1.26100.9711 / pwsh 7.6.9、2026-11-03、template `adfb5eebab9d1a3d90a60928ee31bfa35cb20b4a`）: `scripts/Test-UETemplateScaffold.ps1`は両shellで13 group PASS / exit 0。`a9e31bc`のgeneratorに同じsuiteを当てると`generated project descriptor has a non-empty EngineAssociation`で失敗（engine_changelist assertion 0件のbaseline）。UE install / compile / Editor / PIE / MRQ / render は実行していない（本変更はUE非依存、**Unverified Scope**）。

## Unreleased — DOT-3220

- `docs/04-package.md` のMac節がEpicのUE 5.8表から引用していたのはXcodeの1行だけだった。同じ表にある最低/推奨のmacOS、プロセッサ、メモリ、Metal、Xcodeの行を独自要約の表として揃え、行ごとに出典URLと参照日（2026-11-05）を付けた。表・本文の転載ではなくリンクと要約のみ。
- Epicの「最低macOS = Sonoma 14.5」と「最低Xcode = 26.0」は、Appleの[Xcode対応表](https://developer.apple.com/support/xcode/)（Xcode 26.0〜26.3はmacOS 15.6以上を要求）と両立しない。どちらの表が誤記かは決めず、host判定は**両表の交差**で行う規則として明記した。Epic内の「Sequoia 14（上部）/ Sequoia 15（Version History）」の不整合と、「Xcode 26.4は非互換」が単一buildか26.4系全体か確定できない点も、推定せず未確定として残した。
- `scripts/Test-UEMacHostRequirements.ps1`（新規・読み取り専用）を追加。hostの観測値（`-MacOSVersion` / `-XcodeVersion` / `-ProcessorFamily` / `-MemoryGB` / `-MetalSupported`）を呼び出し側が渡し、判定は`pass` / `fail` / `unverified`の3値。終了codeはpass=0 / fail=1 / unverified=2。`sw_vers` / `xcodebuild`は自動実行せず、値の無い欄・公開表に記載の無い版は`unverified`に落としてpassへ丸めない。reportは`-ReportPath`の新規pathにのみ排他作成する。
- `-SelfTest`で13のhost組とreport排他作成、`docs/04-package.md` / `templates/QA.md`の必要行・出典URL・参照日の静的検査、および本scriptがBOM無しASCIIのままであること（Windows PowerShell 5.1がBOM無しUTF-8をANSIとして読み、日本語リテラルがあると`-SelfTest`実行前に構文エラーで止まるため）を固定した。負例: Ventura 13.5（Epic最低OS未満）、Tahoe 26.2 + Xcode 26.4.1（非互換系）、Sonoma 14.5 + Xcode 26.0（Epicの2行は満たすがApple表で不成立）、Sonoma 14.5 + Xcode 15.4（UE 5.8のXcode最低未満）、Xcode未申告、Intel、8 GB、Metal非対応、無観測、解読不能な版表記。正例: Sequoia 15.6 + 26.1.1 + M3 + 32 GB + Metal。
- `templates/QA.md`にMac host適格のpass/fail行を1行追加（macOS版/Xcode版/プロセッサ/Memory/Metal/判定/出典参照日、report path）。既存行は削除していない。判定の独立記録（片方の表だけでpassにしない、`unverified`をpassに丸めない、hostのpassをMac実機build/署名の合格に読み替えない）も追記した。

実測（本host、`pwsh 7.6.9` と Windows PowerShell 5.1.26100.9711）: `scripts/Test-UEMacHostRequirements.ps1 -SelfTest` → 17 group PASS / exit 0（両shell同一、5.1は`-File`で起動）。負例として`docs/04-package.md`から`macOS Sonoma 14.5`を削った複製では exit 1 で落ちる。個別判定4組（pass/fail/unverified/fail）も両shellで同じverdictと同じexit codeになった。`scripts/Test-UETemplateScaffold.ps1`と`scripts/Test-UERenderArtifacts.ps1`は回帰なし。

移行: 既存作品のQA記録は書き換えない。Mac host行が無い旧記録は**Unverifiedのまま**残し、新規runから本行を埋める。Mac実機のbuild / UAT / `.app`生成 / 署名・公証、`sw_vers` / `xcodebuild`の実測は未検証（Unverified Scope）。fixtureと文書の検査成功はMac実行の証明ではない。

## Unreleased — DOT-3232

- `docs/05-qa.md` は MP4 への書き出し経路を **1 本（MRQ 画像列 → 既存 ffmpeg）しか書いておらず**、UE 5.8.4 の実インストールが同梱する MRQ の MP4 直接出力を encoder として数えていなかった。同ファイル `:7` の「既存 encoder がなければ勝手に導入しない」は、UE 自身が持つ encoder を「無い」と読ませる書き方で、ffmpeg の無い host の agent を停止させうる。加えて `templates/QA.md` には**どの経路で MP4 を作ったかを記録する欄が 0 行**だったため、direct-MRQ の MP4 と ffmpeg で組んだ MP4 が納品記録上で区別できなかった。
- `docs/05-qa.md` に「書き出し経路（2つ）」節を追加し、**経路A（`mrq-image-sequence+external-ffmpeg`、元 PNG 列が存在し画像列検査が効く）** と **経路B（`mrq-native-mp4`、MRQ の出力設定 `H.264 MP4 [8bit]` で直接 MP4、元 PNG 列は存在しない）** を、元 PNG 列の有無つきで明示した。既定は経路A のままで、経路B を既定にしない。`:7` の文は「UE 同梱の MRQ 出力設定も encoder として数える。外部 ffmpeg の新規導入はしない」へ書き換えた（**新規導入禁止は維持**）。既存の ffmpeg 例は削除していない。独立判定表の「画像列」行にも、経路B では対象が存在しないことを追記した。
- `templates/QA.md` に `encode_path` / `mrq_output_setting` / `source_png_sequence` の 3 行を `MRQ/ffprobe実測` 行の直前に追加した。direct-MRQ MP4 は「元 PNG 列が無いから unverified」ではなく「経路B として記録済み」と書ける。既存行の意味は変えていない。
- `docs/01-start.md` の最小 smoke chain と、`templates/recipes/{vertical-loop,spectator-explore,third-person-game}/Capture.md` の ffprobe 前提の 1 行に、どちらの経路でもよいこと・経路と出力設定名を QA へ記録することを 1 文ずつ追記した。
- レビュー指摘への修正（PR #30）: EXR 列を検査するときは `Measure-UERenderArtifacts.ps1` に `-Extension .exr` を渡すことを明記（既定の `.png` のままだと正しい EXR 列を fail にする）。経路B の判定は ffprobe と目視だけでなく**音が対象なら実聴取も必須**とし、経路B の画像列欄は `non-goal` と書けるようにした（`evidence/frames-check.json` は経路Bに存在しないため、要求しない）。
- 理由・出典: (a) Epic 公式 docs（UE 5.8 の MRQ 概要／高品質フレーム描画ガイド、2026-11-05 参照）の出力設定表に `.bmp`/`.jpg`/`.png`/`.exr`/`.wav` のみで **MP4 の記載が無い**（= 文書の不在。機能の不存在や非推奨の公式見解ではない）、(b) 実インストールの `Engine/Plugins/MovieScene/MovieRenderPipeline/MovieRenderPipeline.uplugin` に `MovieRenderPipelineMP4Encoder`（`PlatformAllowList` は Mac/Win64/Linux）と `Binaries/Win64/UnrealEditor-MovieRenderPipelineMP4Encoder.dll`、`Source/MovieRenderPipelineMP4Encoder/Public/MoviePipelineMP4EncoderOutput.h`（`GetFilenameExtension() == "mp4"`、`GetDisplayText() == "H.264 MP4 [8bit]"`）が実在し、PNG/EXR 出力と同じ `UMoviePipelineSetting` 系として登録されている、(c) 同梱 source の `Source/MovieRenderPipelineMP4Encoder/Private/Windows/MoviePipelineMP4Encoder.h:11` に `Experimental.` の明記がある。**このため既定経路を MP4 へ倒す提案はしない。**
- 移行: 既存作品の `Out`・画像列・MP4 を再生成しない。既存 run の QA 記録は当時の経路が不明なら `encode_path` を空欄のまま `unverified` とし、遡って推測で埋めない。`MovieRenderPipelineMP4Encoder` を recipe の `required_plugins` へ追加していない（`.uplugin` の `MovieRenderPipeline` に同梱される）。ffmpeg / ffprobe の導入・更新・画質パラメータの変更も無い。
- Unverified Scope: UE 5.8.4 で経路B（`H.264 MP4 [8bit]`）が実際に動くこと、direct-MRQ MP4 の画質・frame 数・音声同期・loop 継ぎ目が経路A と同等であること、`Experimental` 表記が将来の UE 版で外れること、Epic が MP4 出力を非推奨としていること、ffmpeg の無い host で agent が実際に停止すること（本 host には ffmpeg 8.1.2 がある）。本変更は UE を起動せず、engine 同梱物（`.dll` / `.uasset` / `TemplateDefs.ini`）を repo へ追加していない。

## Unreleased — DOT-3229

- `scripts/New-UETemplateScaffold.ps1` の `Read-TemplateDefs` が `TemplateDefs.ini` の区切り文字の空白に依存していたのを直した。`FolderRenames` の `From=` / `To=` の間と `Extensions=(` / `MountName="` の直後に、任意個の空白・タブを許容する。
  - 実測: 本hostの実 install `UE_5.8`（`Engine/Build/Build.version` = 5.8.4 / CL 58902052）の `Templates/*` 34本のうち `Config/TemplateDefs.ini` を持つ32本を読み、うち**15本**が `FolderRenames=(From="…", To="…")`（カンマ直後に空白）形式で書いている。`Source/` を持つ spaced 形式の template は `TP_Blank` と `TP_SIM_Blank` の2本で、`TP_Blank` を `materialize_project: true` の recipe で実体化すると、宣言された改名規則が**無言で捨てられ**、`.uproject` が宣言する module 名と `Source/` の実ディレクトリ名が食い違った tree を exit 0 で出力していた（`aa11370`）。
  - 変更は**受理する形式を増やすだけで、既存の受理形式を狭めていない**。キー名・括弧内の照合は従来どおり PowerShell 既定の大文字小文字を区別しない比較を維持し（以前に読めた表記が今は読めない、という縮小を起こさない）、セクション見出しの外にある行も従来どおり適用する（以前に受理した file を落とさない）。
  - パターン末尾の `$` を付けた版を一度入れたが、旧 reader は `$` を持っていなかったため、`FolderRenames=(…) ; note` のように**規則の後ろに trailing text が付いた行**は旧 reader が適用していたのに新 reader が捨てるという狭小化になっていた。末尾の `$` を外して旧と同じ「規則の終わりまでで一致、後続 text は無視」に戻してある（DOT-3552 の照合で検出、test で固定）。`EditDetailLevelPreference` の値も旧どおり「閉じ引用符までの任意文字列」に戻し、`"High Quality"` のような quoted multi-word が既定値に落ちる狭小化を防いでいる（値は path の一部になるので前後の空白だけ Trim する）。
- 解釈できなかった既知キー行を無言で捨てるのを止めた。読者が適用すると称するキー（`FoldersToIgnore` / `FilesToIgnore` / `FolderRenames` / `ReplacementsInFiles` / `SharedContentPacks` / `EditDetailLevelPreference`）で、かつ \[/Script/GameProjectGeneration.TemplateProjectDefs\] セクション内にある行が規則を作らなかった場合、**警告して run を継続**する（停止ではなく警告を選んだ理由: 実 engine template には本 reader が未実装のキーや書式が残っており、停止にすると install 済み template を丸ごと拒否してしまう。「行が黙って捨てられる」ことを成功にしないのが本質で、誤った tree を出す歯止めは次項の不変条件検査が担う）。警告には file path と行番号・行内容を含める。
  - `FilenameReplacements` は警告対象に**含めない**。同キーの実装要否は materialization 忠実性の別 issue（DOT-3135）が持つ層で、ここでは適用も報告もしない（二重実装しない）。
- test を両形式で回すようにした。`scripts/Test-UETemplateScaffold.ps1` は `", To="` 形式と `",To="` 形式の `FolderRenames` を1つの fixture に同居させ、両方で `Source/<ProjectName>/<ProjectName>.Build.cs` へ改名されること、`Source/` 以外の改名、spaced な `FoldersToIgnore` / `ReplacementsInFiles` / `SharedContentPacks` / `EditDetailLevelPreference` が効くこと、解釈不能な `SharedContentPacks` 行が警告になることを assert する。さらに、区切り記号を落とした `FolderRenames` 行を持つ fixture で (a) 警告が出る、(b) run が project identity 検査で**停止**する、(c) 停止 message が未一致 path を名指しすることを assert する。
  - **現行 HEAD（`8f58615`）の generator に同じ assertion を当てると落ちる**ことも記録した（下記「修正前後の実測」）。
- 生成後の不変条件検査は既存の `Get-ScaffoldIdentityReport`（DOT-3041 で着地済み、`.uproject` の `Modules[].Name` と `Source/<Name>/<Name>.Build.cs` の双方向照合）を再利用し、重複実装していない。DOT-3135 の完了条件 2/3 と重なる層も同じ検査を再利用する。

### `TemplateDefs.ini` の受理形式（本変更後の契約）

| 項目 | 受理する形 |
|---|---|
| セクション | `[Section]` 行で切り替え。規則の適用は従来どおり全セクション。警告の報告だけを `[/Script/GameProjectGeneration.TemplateProjectDefs]` に限定 |
| 区切り | `=` の前後、`(` の直後、`,` の前後、`)` の直前に任意個の空白・タブ |
| `FolderRenames` | `(From="…", To="…")` / `(From="…",To="…")` / `( From = "…" , To = "…" )`。規則の後ろに trailing text が付いた行も旧どおり適用する |
| `ReplacementsInFiles` | `(Extensions=("cpp","h"))` / `( Extensions = ( "cpp" , "h" ) )` |
| `SharedContentPacks` | `(MountName="X",DetailLevels=(…))` / `( MountName = "X" , … )` |
| `EditDetailLevelPreference` | `"High"` / `High` / `= "High"`（前後の空白つき）。quoted な複数語の値も旧どおり受理 |
| 解釈不能な既知行 | 警告（`TemplateDefs.ini rule was not understood …`）を出して run を継続。生成物が実際に壊れていれば project identity 検査が非 0 で停止する |

本契約は Epic の `TemplateDefs.ini` 文法仕様に**基づかない**。公式 docs は `LocalizedDisplayNames` / `LocalizedDescriptions` / `Categories` しか記述しておらず、区切り空白の許容可否は公開されていない。根拠は「本hostの実 install の template が実際にその形式で書いており、本 repo の解析器がそれを捨てていた」ことだけである。

### 修正前後の実測（本host、Windows 10.0.26300、`pwsh 7.6.9` と Windows PowerShell 5.1.26100.9711）

- 改造前 `aa11370` の generator + 実 install `TP_Blank`（`", To="` 形式、`Source/` あり）を `materialize_project: true` の recipe で実行: `exit 0` / `Created Probe_a …`、`.uproject` `Modules[0].Name = Probe`、`Source/TP_Blank/Probe.Build.cs`。module 名の合わない tree を成功として出す。
- 変更後、同じ実 install `TP_Blank` で同じ実行: `exit 0` / `Source/Probe/Probe.Build.cs`（`Source/TP_Blank/` は残らない）。
- 現行 HEAD `8f58615`（DOT-3041 の identity 検査あり）で spaced fixture を実行: project identity 検査が未一致 path を列挙して**停止**（`Source/TP_SpacedRenames/…` と `Modules[].Name "Probe"` の双方を報告）。`aa11370` は同じ fixture で `exit 0` の壊れた tree を出した。
- `scripts/Test-UETemplateScaffold.ps1`: 変更後 `pwsh 7.6.9` と Windows PowerShell 5.1 の双方で 10 group PASS / exit 0（既存 7 group + 新規 2 group + 既存の最終 group）。`aa11370` に同じ suite を当てると新規 group で落ちる。

### 移行

既存 project / `Production/` の生成物には触れない。過去に `", To="` 形式の template から生成した project（例: `TP_Blank` 由来で `Source/TP_<Template>/` が残るもの）は、`.uproject` の module 名と `Source/` が食い違っているので**新しい RunId で生成し直す**か、`Source/<Template>/` を `Source/<Module>/` へ手で合わせるかを案件ごとに選び、QA に記録する。本変更は generator と test と本書に閉じ、`.uproject` の identity 契約（DOT-3041）と lock の shape は変えていない。

Unverified: UE の install 操作 / 起動 / compile / Editor / PIE / cook / MRQ / render / Shipping は実行していない。`Source/Probe/Probe.Build.cs` + `.uproject Modules[0].Name = "Probe"` の tree を UE / UBT が読んだときの挙動、UE ウィザードが `", To="` 形式を受理するか、タブ区切り・行末コメント・引用符なし等他の書式変種、UE 5.8.4 以外の版の同梱 template の書き方は未確認。

## Unreleased — DOT-3235

- `templates/CREDITS.md` のデータ行は1行だけで全列が `未使用` を主張していたが、generator は生成物の `Content/` に engine 同梱の `.uasset`/`.umap` を最大 753 件置く。**「素材を一切使っていない」と書いたまま engine 同梱 content を納品する経路**を閉じるため、記入契約を「`Content/` の先頭ディレクトリごとに1行、`出所区分 (origin)`（`engine-template` / `shared-content-pack` / `third-party` / `original`）と `同梱形態 (bundle)`（`repo-bundled` / `generated-only`）を明記」に変えた。未記入は Unverified であり「未使用」の主張ではない。記入例は code fence 内に置く（監査器は fence の中を記録として読まない）。
- 監査器 `scripts/Measure-UECreditsInventory.ps1` を追加。納品dir（`Out/run_<runid>/`）と project root のどちらを渡しても同じ組（`Content/` と `CREDITS.md`）を解決し、同じ結論を返す。`Content/` に asset が1件以上あり出所を述べた行が無ければ FAIL、`Content/` の各先頭ディレクトリ名が出所行に現れなければ FAIL（group 名を報告）、`Content/` が無ければ placeholder 1行で PASS、`CREDITS.md` 不在や `Content/`・`CREDITS.md` が2つ以上解決できる場合は exit 2。exit 0 = 通過 / 1 = 検出 / 2 = 入力不備。
- 回帰 `scripts/Test-UECreditsInventory.ps1` を追加。実測した形（753 asset + placeholder CREDITS）の fixture を自作 placeholder bytes で作り、project root 監査 FAIL・納品dir 監査 FAIL（0件 PASS しない）・`CREDITS.md` 不在 exit 2・0 asset PASS・全 group 列挙 PASS・`templates/CREDITS.md` の記入例をそのまま使うと 753 asset/9 group で PASS・部分記入 FAIL・旧9列表 FAIL・曖昧入力 exit 2・checkout 不変を固定した。engine 同梱 `.uasset`/`.umap` は repo へ置いていない。
- `templates/DELIVERY.json` に `template_repository` / `template_commit` / `template_lock_sha256` / `recipe` / `engine_template` / `engine_version` / `engine_changelist` / `shared_content_packs` / `content_inventory` を追加した。`docs/07-architecture.md` が要求する「共通 commit SHA・UE/Plugin版・レシピ・ローカル差分」を納品記録が保持できるようにするため。**既存 field は削除・改名していない**（未記入は `null`）。
- `template-lock.json` は、`TemplateDefs.ini` の `SharedContentPacks` を適用した recipe では実際にコピーした mount 名（`shared_content_packs`）と mount → 実展開元 detail level（`shared_content_pack_detail_levels`、例 `Weapons: Standard`）を記録し、宣言の無い recipe では空配列になる。この記録は DOT-3157 の `Copy-TemplateTree` 実装で既に書かれており、本変更はそれを**CREDITS 記入の正本**として文書と監査に接続しただけで、**pack のコピー挙動と lock の field 構成は変えていない**。
- `docs/03-assets.md` / `docs/04-package.md` / `docs/06-delivery.md` / `docs/07-architecture.md` / `AGENTS.md` の tree 図 / `templates/QA.md` の1行を、上記の実行コマンドと pass/fail 条件へ接続した。lock は既存の field 名（`shared_content_packs` = mount 名の配列、`shared_content_pack_detail_levels` = mount → 実展開元 level）で参照する。

本hostでの実測（Windows、UE 5.8.4 CL 58902052、`powershell` 5.1 と `pwsh`、**UE は起動していない**、生成はファイルコピーのみ。base = `3ed94b6`（DOT-3157 適用後の `main`））:

```text
recipe              生成物の .uasset+.umap  lock.shared_content_packs
spectator-explore   542                     Characters(High) / LevelPrototyping(High) / Input(High) / Weapons(Standard)
third-person-game   753                     Characters(High) / Input(High) / LevelPrototyping(High)
vertical-loop       0（Content/ 無し）        []

placeholder CREDITS のまま（3 生成物、project root / 納品dir の両方）
  spectator-explore  exit 1 / exit 1  （542 asset、9 group 未記載）
  third-person-game  exit 1 / exit 1  （753 asset、9 group 未記載）
  vertical-loop      exit 0 / exit 0  （0 asset）
全 group を列挙した CREDITS（third-person-game）
  project root exit 0 / 納品dir exit 0（assets total=753 groups=9 credits_rows=4）
`templates/CREDITS.md` の fenced 記入例をそのまま複製（third-person-game）
  project root exit 0 / 納品dir exit 0（出力一致）
旧9列表（origin 列なし、third-person-game）
  project root exit 1 / 納品dir exit 1

scripts/Test-UECreditsInventory.ps1     9 PASS 行 / exit 0（powershell 5.1 と pwsh）
scripts/Test-UETemplateScaffold.ps1     12 group PASS / exit 0（無改変）
git status --porcelain --untracked-files=all  実行前後とも 0 行（生成物は削除済み）
```

移行: 既存作品の `CREDITS.md` は**書き換えを強制しない**。旧9列表は監査で FAIL になるが、それは Unverified のままであることを意味し、権利判断ではない。再生成する場合は `template-lock.json` の `shared_content_packs` を見て `Content/` の先頭ディレクトリごとに出所行を書く。engine 同梱 content の再配布可否は本変更の対象外（Epic の template 機構文書に記載が無いという不在の観測のみ）。

## Unreleased — DOT-3225（UE-PROCTREE-001）

**理由**: `AGENTS.md` は「自分のrun所有processを同期回収」を必須にし、`templates/QA.md` がその合否を記録させ、同じ `AGENTS.md` が名前指定killを禁止している。ところが repo は「run所有」の**範囲を定義せず**、回収・検証のscriptを1つも同梱していなかった。lease が保存するのは単一の `pid` だけで、`Stop-Process` / `taskkill` / `Win32_Process` / `ParentProcessId` の参照は repo 全体で 0 件だった。結果、文書に従うagentは「回収しない」か「禁止された方法で回収する」のどちらかに落ち、さらにPID生存だけでleaseをfreeと報告すると、子孫がprojectを掴んだまま次のrunが失敗する。

- **run所有の範囲を定義**（`docs/01-start.md` の「run所有プロセスの範囲」）。writer自身、writerが起動した子孫（build/Editor/cook/render/UBT/ShaderCompileWorker/UnrealPak/CrashReportClient 等、名前を問わない）、run開始後に同じsnapshotへ記録されたprocessが**所有**。writerの親（runtime/adapter/shell）、共有Chrome、他runのleaseがactiveなprocess、runが起動していない常駐toolは**所有でない**（停止対象から明示的に除外）。`AGENTS.md` の「名前指定kill禁止」は維持し、停止は常に `(process_id, creation_utc_ticks)` の同一性で行う。
- **lease に帰属材料を追加**。DOT-3042 のlease契約（8 field、`Acquire`/`Release`/`Test` は `scripts/Lease-UETemplateProject.ps1`）はそのまま維持し、`pid` を**残したまま**任意field `process_snapshot`（`path` / `sha256` / `captured_at_utc` / `writer_process_id` / `writer_creation_utc_ticks` / `root_process_ids` / `boundary_ancestor_process_ids` / `process_count`）を取得直後に追記する。snapshot本体は `Out/run_<runid>/evidence/process-snapshot.json` に run 別で1本。`scripts/Lease-UETemplateProject.ps1` は必須8 fieldの厳密一致を保ち、`process_snapshot` だけを任意fieldとして受理し、存在する場合は `path` と `sha256` の両方を要求する（docs の列挙も同時に更新して「列挙に厳密一致」と衝突させない）。
- **script 3本 + 共通helper を追加**（すべて UE を起動しない。`Win32_Process` の読取と JSON だけ）。
  - `scripts/Start-UETemplateRunProcessSnapshot.ps1` — run開始時に writer とプロセス表を1回観測し、snapshotを作る。`-LeasePath` 指定時は lease に `process_snapshot` を追記し、**既存fieldが1つでも変われば停止**する。排他createと競合検出は DOT-3042 の領域として実装しない。
  - `scripts/Stop-UETemplateRunProcesses.ps1` — dry-run で**停止対象一覧を先に出力・保存**し、`-Execute` で一覧のidentityだけを停止する。`-Execute` は同じsnapshotに対する dry-run plan が無ければ**拒否**する（実行前に一覧が出ない経路がない）。停止は深い順。帰属不明は停止せず `unknown`。PID再利用（`creation_utc_ticks`不一致）は対象外。共有Chrome・他run・writerの親は `excluded`。
  - `scripts/Get-UETemplateLeaseVerdict.ps1` — lease を **`free` / `held` / `unknown` の3値**で判定する。`pid` が死んでいるだけでは `free` を返さない。snapshot欠落・hash/run/writer不一致・帰属不明のいずれでも `unknown`。検査自体が実行できない場合も `unknown`（exit 2）を返し、例外のexit 1を`held`と読み替えさせない。`writer_alive` は identity 一致時だけ `true`（`writer_pid_present` / `writer_identity_verified` を別fieldで持つ）。
  - `scripts/UETemplateProcessOwnership.ps1` — 上記3本が dot-source する共通helper（snapshot union、親子鎖、深さ、identity判定）。
  - DOT-3042 が同梱した `scripts/Test-UETemplateLease.ps1`（leaseプロトコル `Acquire`/`Release`/`Test` のsuite）は名前も役割も変えない。3値判定の検査器は別名の `Get-UETemplateLeaseVerdict.ps1` として追加した（同名の suite と衝突させない）。
- **`templates/QA.md` を機械可読にした**。`run所有processの回収` 行と `## run所有processの回収` 節を、**停止対象件数・停止件数・残存件数・残存の帰属不明件数・判定** の5項目 + report path で記録する形にした。`unknown` は合格にしない。DOT-3042 の lease nonce/receipt 行はそのまま残す。
- **回帰suite を追加**（`scripts/Test-UETemplateProcessOwnership.ps1`、14 group、UE不使用・fixtureはsystem temp）。負例を固定: (a) writer→子→孫を snapshot の親子鎖で列挙・停止、(b) snapshotに無いlive process は停止せずgapとして報告、(c) PID再利用は停止しない、(d) writer PID死亡だけでは `unknown`（`free`でない）、(e) 変更前のlease形状（snapshot無し・単一PID）では孫に到達できず `unknown`。加えて、読めないleaseは `held` ではなく `unknown`（exit 2）を返し、writer PIDが生存していても`creation_utc_ticks`が不一致なら`alive=False` / `pid-present=True`と記録する。
- `.github/workflows/verify.yml` の `lease` job に `scripts/Test-UETemplateProcessOwnership.ps1` を追加した（`scripts/Test-UETemplateLease.ps1` はそのまま実行する）。

**検証（本host、Windows 10.0.26300、`pwsh 7.6.9` と Windows PowerShell 5.1.26100.9711）**: `scripts/Test-UETemplateProcessOwnership.ps1`（14 group PASS / exit 0、両PS）。`scripts/Test-UETemplateLease.ps1`（DOT-3042 のsuite、11 PASS / exit 0、両PS）。`scripts/Test-UETemplateScaffold.ps1` = **8 group PASS / exit 0**（両PS、回帰なし）。`git status --porcelain --untracked-files=all` は test 前後で不変（suite 自身が断言）。UEは一度も起動していない。main への追随は merge で行い、docs/CHANGELOG は手作業で意味的に統合した（どちらの記述も捨てていない）。

**移行**: 既存の生成projectと `Production/` の生成物は書き換えない。`process_snapshot` が無い旧leaseは `Get-UETemplateLeaseVerdict.ps1` で `unknown` になるので、新runは `Start-UETemplateRunProcessSnapshot.ps1` を lease 取得直後に1回実行する（snapshotが無いまま `free` を主張しない）。既存runを遡って snapshot を捏造しない。`Lease-UETemplateProject.ps1` の `Acquire`/`Release`/`Test` の手順は変わらない（`-Action Test` は従来どおりPID生存だけを見、子孫の帰属は `Get-UETemplateLeaseVerdict.ps1` が答える）。

**Unverified Scope**: 実UE 5.8.4 の起動/compile/Editor/PIE/MRQ/render/Shipping は実行していない。job object の `KILL_ON_JOB_CLOSE` は本hostで成立を確認できていないため採用せず、帰属はsnapshotの親子鎖だけで行う。Microsoftの仕様上 `Win32_Process.Create` 経由の子はjobを継承しない（[Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects)、2026-11-05参照）ので、job単独を根拠にしない。実際のUE runがどのprocessをどの親子関係で出すかは未観測で、fixtureでの一致だけを合格根拠にしている。


## Unreleased — DOT-3076

- `scripts/New-UETemplateScaffold.ps1` は `Production/.stage-<runid>-<nonce>/` に全成果物を書き、最後に単一renameで`Production/<Name>_<runid>/`へ公開するようになった。`Directory.Move`は既存パスを拒否するので、これが生成のatomicな公開と最終的な排他判定を兼ねる。
- 失敗時はcatchが**そのrun自身のstagingだけ**を削除する。公開済の既存projectや他runのstagingには触れない。従来の「失敗時は出力ディレクトリをそのまま残す」は廃止した。
- 途中で失敗したrunの`Production/<Name>_<runid>/`は存在しないため、同じ`Name`/`RunId`での再生成を残骸が恒久的にブロックしなかった（従来は`Output already exists; it was not modified`で拒否され、`AGENTS.md`の削除禁止規則と衝突して解消不能だった）。
- `template-lock.json`を完成マーカーとして明文規定した（最後に書き、公開前に存在を確認する）。`docs/01-start.md`、`AGENTS.md`、`docs/07-architecture.md`に「lockの無い生成ディレクトリは未完成」「残骸の削除は自runの失敗終端を確認できた場合だけ、他runには触れない、判断できない場合は停止」を書いた。
- `scripts/Test-UETemplateScaffold.ps1`に途中失敗のassert群を追加した（既存8群は維持）: plugin metadata欠落（`.uproject`コピー後）とrecipeコピー段階の失敗で出力ディレクトリとstagingが残らないこと、失敗後に同じ`Name`/`RunId`で正しく再生成できること、既存出力は従来どおり拒否され内容が保持されること。`Production/`の残骸gateは`.stage-*`も検出する。
- 実測（本host Windows、`powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Test-UETemplateScaffold.ps1`）: 変更前のgeneratorでは`ASSERT FAILED: a mid-copy failure publishes no Production/<Name>_<runid> directory`でexit 1。変更後は11 group PASS・`EXIT=0`。
- Unverified: UE実機（Editor/build/PIE/MRQ/Shipping）は実行していない。本変更はPowerShell層のみで、`Production/`の既存生成物には触れていない。
## Unreleased — DOT-3157

- 生コピー経路（`materialize_project`を持たない`spectator-explore` / `vertical-loop`）がtemplateの`Config/TemplateDefs.ini`を一度も読まず、templateフォルダを丸ごとコピーしていた。出力`Content/`に`TP_FirstPerson`の既定mapが参照する共有content pack（`Characters` / `LevelPrototyping` / `Input` / `Weapons`）が入らず、逆にignore対象の`Media/`と`Config/TemplateDefs.ini`・`Config/config.ini`が残っていた。generatorはexit 0で`Created ...`を表示し、testは6群PASSしていたため、"assetが足りない"を出力から判別できなかった。
- `scripts/New-UETemplateScaffold.ps1`のコピー実装を1つ（`Copy-TemplateTree`）に統合し、両経路とも`TemplateDefs.ini`を読むようにした。`FoldersToIgnore` / `FilesToIgnore` / `SharedContentPacks`は共通、`FolderRenames` / `ReplacementsInFiles` / `FilenameReplacements`によるrenameは`materialize_project`のrecipeだけで適用する（生コピーの2 recipeはproject名/module名をtemplate名のまま維持する契約を変えていない）。
- `SharedContentPacks`の展開は`Templates/TemplateResources/<DetailLevel>/<Mount>/Content`から`Content/<Mount>`。`EditDetailLevelPreference`のlevelに実体が無いmountは、`High` → `Standard` の順で実在するlevelを使う（実install UE 5.8.4の`TP_FirstPerson`は`Weapons`を`Standard`のみで提供している）。per-mountの`DetailLevels` tuple解釈は含まない（DOT-3135の担当）。
- 生成後検査を追加した。生成物の`Config/DefaultEngine.ini`の`GameDefaultMap` / `EditorStartupMap`が`/Game/...`を指す場合、その`.umap`が出力にあることを確認し、無ければ**停止**して欠落pathを列挙する。`/Engine/...`の宣言は出力treeの対象外として検査しない。
- `template-lock.json`に`shared_content_packs`（展開したmount名）、`shared_content_pack_detail_levels`（mount → 実展開元level）、`template_defs_ignore_rules`（適用した`FoldersToIgnore` / `FilesToIgnore`件数）を追加した。`schema_version`は`2`のまま（追加fieldのみ）。
- `scripts/Test-UETemplateScaffold.ps1`のfixture`TP_FirstPerson`に`SharedContentPacks` 3種（`Characters` / `LevelPrototyping` / `Input`）・`FoldersToIgnore=Media`・`FilesToIgnore="Config/TemplateDefs.ini"`を持たせ、`Templates/TemplateResources/High/**`に実体を置いた。assertion追加: 生コピー出力にpackが入る／`Media/`と`Config/TemplateDefs.ini`・`Config/config.ini`が入らない／lockにpack一覧とignore件数が載る。負例2件: 既定mapが`SharedContentPacks`側にしか無いfixtureではpack展開後に成功し、pack宣言を外すと**停止**する。

本host実測（Windows / `pwsh 7.6.9` / UE 5.8.4 CL 58902052、repo base `96f8de0b7016b86f1a9861558000bed7d9d2c743`（`main` をmerge済み））: 変更後`scripts/Test-UETemplateScaffold.ps1` = **12 group PASS / exit 0**（`pwsh`と`powershell`の両方で確認）。同じsuiteを`aa113700b0ce4d2bbe32dbb7bd2bdec91d5531d0`のgeneratorに当てると **exit 1**（`ASSERT FAILED: generated project descriptor has a non-empty EngineAssociation` — 既存のidentity契約のassertで先に落ちるため、追加assertまで届かない）。そこで追加assertと同じ観点だけを実install生成物に対して直接照合する比較を別途行い、`aa11370`は14項目すべてFAIL（pack 3種が不在、`Media/`・`Config/TemplateDefs.ini`・`Config/config.ini`が残留、lock field不在、既定mapの共有pack参照17種が1つも解決せず、既定map欠落で停止せず）、変更後は14項目すべてPASSした。実install生成物の`spectator-explore`は`Content/`に`Characters` / `LevelPrototyping` / `Input` / `Weapons`を持ち、`Media/`・`Config/TemplateDefs.ini`・`Config/config.ini`を持たない。既定map参照17種は17/17解決する。`vertical-loop`は`TP_BlankBP`がpackを宣言しないので`shared_content_packs`が空配列になり、`Media/`と`Config/TemplateDefs.ini`は入らない。

移行: **既存の生成済みprojectはコピーし直さない**（欠落packの後入れや手動修復をこの変更は行わない）。packが必要なら同じ`-ProjectName`のまま新RunIdで再生成し、`template-lock.json`の`shared_content_packs`と`identity`を読んでからEditorで開く。`Production/`の既存ディレクトリは上書きされない（排他的作成）。

未検証（Unverified）: UE Editorでの起動、既定mapを開いたときのmissing reference表示、PIE、MRQ、Shipping、パッケージ済みbuild。本変更の検証はPowerShell層のfixture回帰と実installのコピー結果までで、UE実機でmapを開いた確認ではない。

## Unreleased — DOT-3132

- `scripts/New-UETemplateScaffold.ps1` had **no path-length budget**: it accepted `ProjectName` up to 40 characters and `RunId` up to 64, so the output folder `<Name>_<RunId>` could reach 105 characters and the generated tree could exceed 260 characters while the generator still printed `Created ...` and exited 0. This repository already records 260 characters as a real failure (`docs/08-online-foundations.md`: a 2026-11-01 UE Editor build had to move the checkout to a temporary `Q:` drive), yet nothing in `scripts/` or the docs checked it.
- The generator now measures the longest absolute path it is about to write — copied engine template (projected through `TemplateDefs.ini` for materializing recipes), shared content packs, the bundled `MulticaOnlineStarter` payload, and its own `Recipe/`, `docs/08` and `template-lock.json` — **before the exclusive mkdir**, and stops when it exceeds `-MaxPathLength` (default **260**). A rejected run leaves no `Production/<Name>_<RunId>/` behind. The stop message carries the measured length, the relative path, the overrun, the current clone-root length, the clone-root length that would fit, and concrete ways to shorten.
- Success output gains one line: `Path budget: longest planned path <N> characters, <M> characters of headroom under the <B>-character budget (<relative path>).` so the residual budget can be recorded in QA.
- The generator's "where does this template file land" projection is now one function (`Get-MaterializedTarget`), shared by the budget measurement and the copy, so the measured paths are the written paths instead of a second, drifting guess.
- `scripts/Test-UETemplateScaffold.ps1` gained a budget group with negative cases: success with an exact-fit budget, stop with budget−1 (output directory absent), stop with the default budget on a full-length name, and stop driven by clone-root depth alone (the same generated tree passes when the budget is explicitly raised, proving the depth is what changed). The pre-existing groups declare `-MaxPathLength 32767` explicitly, because their long fixture names are generator-behaviour fixtures, not budget fixtures; none of their assertions were removed.
- `docs/01-start.md` adds "checkout and output absolute path length" to the Preflight completion criteria plus a "パス長の予算" section (budget target list, stop behaviour, default and its sources, and the fact that UE build output is out of scope). `README.md` gives a short clone recommendation and says why. Both cite the existing `docs/08-online-foundations.md` record instead of rewriting it.

Evidence class: the default 260 comes from this repository's own recorded failure plus Microsoft's documented `MAX_PATH`; Epic's Build Configuration page does document `WindowsPlatform` `MaxRootPathLength`/`MaxNestedPathLength` ("ensure paths are portable between machines"), but its values and failure behaviour were not obtained, so this is **not** a claim that Epic requires 260. Measured on this host (Windows 11 `10.0.26300`, `pwsh 7.6.9`, `PowerShell 5.1`): `scripts/Test-UETemplateScaffold.ps1` = 9 groups PASS / exit 0 in both shells. With `spectator-explore` / `EmberWatch` / `01a19b22-18dc-7bcc-ba2d-f647ec88dcf3`, clone root 85 → longest 260 (passes), 86 → 261 (stops), 94 → 269 (stops); the pre-fix generator wrote 261/263/269-character trees and exited 0 at the same depths.

Migration: **existing generated projects are not moved, renamed or regenerated.** The check applies to new generations only; an existing `Production/<Name>_<RunId>/` stays as it is, and work already under way continues. If a new generation stops, either clone the template into a shallower directory or pass a larger `-MaxPathLength` and record the measured length and the reason in QA. UE build output (`Intermediate/`, `*.generated.h`, `*.obj`) is not generated here and is not measured; whether UE/UBT/MSVC actually fail above 260 characters on long-path-enabled hosts remains **Unverified** (this host has `LongPathsEnabled=1` and can write such paths, so no "always fails" claim is made).

## Unreleased — DOT-3090

- 公開前の公開面監査を実装した。`scripts/Test-UETemplatePublishSurface.ps1` は **index を正本**（`git ls-files -z`）とし、`generation-output`（`Production/` `Out/` `Art/` `Saved/` `Binaries/` `Intermediate/` `DerivedDataCache/`、`Production/PLACEHOLDER.md` だけ許可）/ `distribution-binary`（`.bundle` `.7z` `.exe` `.dll` `.pdb` `.uasset` `.mp4` 等）/ `credential`（`auth.json` `.env*` `id_rsa` `*.pem` 等）のpath形状規則を**監査器自身がcase-insensitiveに持つ**。終了コードは0=通過 / 1=検出あり / 2=監査不能。`throw` を使わず `FAIL:` / `WARN:` / `SUMMARY:` を1行1件で出す。
- なぜ `git status` 目視・`git check-ignore` 突き合わせ・`.gitignore` だけで足りないかを、fixtureで固定した。commit済みの `.bundle` / `.exe` / `.7z` は status 0行・check-ignore は3件とも not-ignored・`^(Production|Out)/` grep 該当なしで**3通りともPASS**する。強制追加した `auth.json` をworktreeから消すと status は `D auth.json` に見え check-ignore も not-ignored を返すが、indexに残り fresh clone に載る。
- `git ls-files -ci --exclude-standard`（追跡済み かつ exclude pattern 一致）を補助信号として `tracked-ignored` 区分で併記する。**判定には使わない。** 同じindexで `OUT/x.txt` `SAVED/a` `ART/a` `PRODUCTION/Proj/TP.uproject` を追跡した場合、本host（`core.ignorecase=true`）は4件、`core.ignorecase=false`（Linux runner相当）は0件を返すため、`.gitignore` の一致判定に委ねると runner ごとに結論が変わる。
- pathに改行を含む追跡物は `git ls-files`（改行区切り）では分割されて壊れる。監査器は `-z` で読む。fixture `Prod\nuction/secret.bundle` で、plain `git ls-files` が1レコードとして返さないことと、監査が `FAIL: distribution-binary: Prod\nuction/secret.bundle` として1行で報告することをassertする。
- 受入2（fresh clone のリンク/placeholder漏れ）を実行可能な検査にした。tracked `.md` のリンクを index と**ordinal比較**で解決し、未追跡・別caseのみ・リポジトリ外へ出る・tracked entryの無いディレクトリを `link` として落とす。`Production/PLACEHOLDER.md` がindexに無ければ `placeholder` で落とす。
- `git add -A` で公開面に入る未追跡物は fail ではなく `WARN:`（`untracked` / `untracked-*`）で報告する。
- `scripts/Test-UETemplatePublishSurface.Tests.ps1` を追加。workdir配下（`Production/.publish-surface-test-<id>/`）に使い捨てgit repoを作り、12 group をassertする。clean repo の PASS、commit済みbinary/exe/archive、強制追加credential、生成projectと`Out/`、改行path、`core.ignorecase` 両方向、リンク4種、未追跡WARN、placeholder欠落、**規則を1つ消した監査器では該当fixtureがPASSに戻る**こと（恒真assertでないことの固定）、開発checkoutの `git status` 不変。suite終了時に自分のfixtureだけを削除し、過去runの残骸は `Production/` 実列挙で検出する。
- `docs/06-delivery.md` の公開前点検と受入2を、自然文の目視から**実行コマンド＋pass/fail条件**へ置換した。`SUMMARY: tracked=<n> fail=0` と exit 0 がpass、`FAIL: <区分>: <path>` が出る exit 1 がfail、exit 2（worktreeでない・indexが空・pathに `"`）は**pass扱いにしない**。exit 2 の追加は「監査を実行できなかった」を「問題なし」と読ませないため。
- `.gitignore` に `*.bundle` `*.7z` `*.rar` `*.tar.gz` `*.tgz` `*.exe` `*.dll` `*.pdb` `*.lib` `*.so` `*.dylib` `*.psd` `*.mov`、および未網羅だった資格情報形状（`secrets.json` / `secrets.yaml` / `token.json` / `service-account.json` / `id_rsa` / `id_ed25519` / `id_ecdsa` / `id_dsa` / `.netrc` / `_netrc` / `.npmrc` / `.pypirc` / `client_secret*` / `api-token.txt` / `GH_TOKEN` / `keystore` / `.htpasswd` / `*.p12` / `*.pfx` / `*.jks` / `*.p8` / `*.ppk`）を追加した。**監査の判定は `.gitignore` に依存させない**（上記の case 依存のため）。冒頭に「このfileは未追跡物しか止めない、公開可否の正本は監査器」と明記した。

検証（本host、Windows 11 10.0.26300、`pwsh 7.6.9` と Windows PowerShell 5.1.26100.9711、git 2.55.0.windows.5）：`Test-UETemplatePublishSurface.Tests.ps1` = 12 group PASS / exit 0（両shell）。`Test-UETemplatePublishSurface.ps1 -RepoRoot <this checkout>` = exit 0 / `SUMMARY: tracked=50 fail=0 warn=2`（warnは本turnで未追跡の2 file）。`Test-UETemplateScaffold.ps1` = 8 group PASS / exit 0（両shell、回帰なし）。`Test-UERenderArtifacts.ps1` = 13 group PASS / exit 0（回帰なし）。実行前後の `git status --porcelain --untracked-files=all` は本変更の4 pathのみで、suite由来の差分は0。

移行: 既存の生成物・`Production/`・`Out/` には触れない。公開判定の根拠を「目視」から「`Test-UETemplatePublishSurface.ps1` の exit code」へ移す。`.gitignore` の拡張は未追跡物の抑制だけで、追跡済みの禁止物は `git rm --cached` しない限り公開面に残る（監査はそれを `FAIL` で報告する）。UE compile / PIE / Editor / MRQ / render は本件で一切実行していない（この変更は UE 非依存、Unverified Scope）。

## Unreleased — DOT-3042

- `docs/01-start.md` は lease プロトコルを「実装要件。スクリプト未同梱」と宣言したままで、排他的 mkdir と `LEASE.json` の CreateNew 相当を各エージェントの手作業に委ねていた。`New-Item -Force` や `Set-Content` で代替した生成物は別 run の active lease を黙って上書きして「成功」として通る。
- `scripts/Lease-UETemplateProject.ps1` を追加した。`Acquire` / `Release` / `Test` の3動作で、出力先 dir の排他的作成は generator と同じ P/Invoke `CreateDirectoryW` + Win32 183 判定、`LEASE.json` の書き込みは `[IO.File]::Open($path, CreateNew, Write, None)` のみ。`Set-Content` / `WriteAllText` / `Out-File` / 一時ファイル rename は使わない（rename は他所の active lease を置換できる）。既存 dir への取得は「生成と取得の区別」として継続し、`Test` は読み取りだけで書き込み・mtime 更新をしない。
- lease のフィールドは `docs/01-start.md` の列挙（run ID / issue ID / host / project realpath / 取得日時 / nonce / writer phase / PID）に固定し、余分な field を持つ記録は読み取り時に拒否する。`Release` は run/nonce 不一致・記録欠落・receipt 既存のいずれでも停止し、`LEASE.json` を消さない。`Test` は 0=active / 1=free / 2=unknown を返し、`free`（記録は残存・手動照合要）と `unknown`（記録なし/読めない/他 host）を混同しない。
- `scripts/Test-UETemplateLease.ps1` を追加した。既存 dir への取得成功・再取得拒否と byte 一致保持・他所 run lease の保持・script 本文の静的検査（非排他書き込み経路が無いこと）・8 プロセス同時取得で勝者1/敗者7と記録が勝者一致・nonce/run 不一致 Release の停止・Release 成功後の `LEASE_RELEASED` と `LEASE.json` 削除・`Test` 前後の content/size/mtime 不変・記録欠落/破損/他 host の `unknown`・文書と AGENTS/QA/CHANGELOG の参照一致を assertion 化した。既存 `Test-UETemplateScaffold.ps1` は変更していない。
- `.github/workflows/verify.yml` に `Test-UETemplateLease.ps1` を実行する `lease` job を追加した（既存 2 job は変更なし）。

**落ちる側（変更前 `8f58615` の repo 本文＋新しい suite）**: `scripts/Test-UETemplateLease.ps1` は変更前 HEAD に存在しないため新 assertion 群は必ず失敗する。実測では新 suite 2 本の script だけを変更前 HEAD の worktree へ置くと 10 PASS の後 `ASSERT FAILED: docs/01-start.md names the shipped lease script` で exit 1になる。

**検証（本 host, Windows, `powershell 5.1.26100.9711` と `pwsh 8` の両方）**: `scripts/Test-UETemplateLease.ps1` → 11 PASS 行 / exit 0。`scripts/Test-UETemplateScaffold.ps1` → 8 group PASS / exit 0（既存 group は不変）。両 suite とも fixture を `Production/` 内の `.lease-test-<id>` に作り、cleanup 後に残骸 0・`git status --porcelain --untracked-files=all` 差分 0 を再確認している。

**Unverified Scope**: UE 実機（compile / PIE / MRQ / Shipping）は実行していない。本変更は UE を起動しない PowerShell 層のみで、実 UE 5.8 系 install を `-ProjectDirectory` にした実 project 生成は未実行。

## Unreleased — DOT-3153

- **文書どおりに最初の1回を実行すると必ず停止していた。** preflight 記録先（`docs/01-start.md:5`）・lease 取得先（`AGENTS.md:11` / `docs/01-start.md:21`）・生成先（`scripts/New-UETemplateScaffold.ps1` の排他的 mkdir）が同じ `Production/<Name>_<runid>/` を要求していたため、記録を先に書くと generator が `Output already exists; it was not modified` で停止した。
- preflight と lease の正本を **`Production/.runs/run_<runid>/`**（生成先 project dir の外）へ一本化した。`Production/*` は `.gitignore:2` の対象なので clean-tree gate を踏まない。正本は `docs/07-architecture.md` の `preflight-lease-placement: Production/.runs/run_<runid>/` 1 行で、`AGENTS.md`・`README.md`・`docs/01-start.md` はそれを指す。
- `docs/01-start.md:5` は「`templates/QA.md` に記録」から「`templates/QA.md` を複製して `Production/.runs/run_<runid>/preflight.md` に記録（生成後は project 内の `Out/run_<runid>/QA.md` へ移す）」へ改正。`templates/` を編集対象にしない。
- `docs/01-start.md:21` の「新 project dir の排他的 mkdir と `LEASE.json` の排他的 create」を、台帳 dir の排他的 mkdir と `LEASE.json` の排他的 create に改め、**生成先 `Production/<Name>_<runid>/` は lease 工程で作らない**（作るのは generator だけ）と明記した。
- generator の 183 分岐を原因別にした。中身が空、`LEASE.json` のみ、`Out/` のみなど、既知の先行生成物しか無い場合は「**順序誤りであり既存成果物ではない**」と、正しい配置とともに述べる。既存成果物がある場合は中身を列挙する。**削除・上書きは行わない**（破壊は別 gate）。
- `scripts/Test-UETemplateScaffold.ps1` に順序契約の assertion を 5 group 追加（既存 8 group は不変）: 配置の一元性（`docs/07` の 1 行と 3 文書の一致）、`Production/.runs/run_<runid>/` に preflight と lease を置いたままでも生成が exit 0、空 dir / lease のみ / `Out/` のみが順序誤りとして判別できること、`templates/QA.md` 編集では従来どおり clean-tree gate で停止すること。

**落ちる側（変更前 `adfb5ee` の repo 本文＋新しい suite）**: `ASSERT FAILED: docs/07-architecture.md states the single preflight/lease placement as a machine-readable line` で exit 1。順序の assertion は変更前 HEAD では成立しない。

**検証（本 host, Windows 10.0.26300, `pwsh 7.6.9`）**: `scripts/Test-UETemplateScaffold.ps1` → 13 group PASS / exit 0（既存 8 + 新規 5）。suite が作る一時 dir は `Production/.runs/` のみで、cleanup 後に残骸 0・checkout 差分 0 を再確認している。

移行: 既存 project と `Production/<Name>_<runid>/` の生成物には触れない。既存の生成済み project では preflight/lease を従来どおり `Out/run_<runid>/QA.md` と台帳へ移して続行できる。新規 run は `Production/.runs/run_<runid>/` に preflight と lease を書いてから生成する。

**Unverified Scope**: 実 UE 5.8 系 install を `-EngineRoot` にした実 project 生成・Editor build・PIE・MRQ は本 turn で実行していない。根拠は合成 Engine fixture と PowerShell 実測のみ。`docs/06-delivery.md` の `SHA256SUMS.txt` 検証 cwd との整合（DOT-3065 の領域）は未検証。

## Unreleased — DOT-3156

- `third-person-game`の実体化は、template自身の置換規則でコピーした**reflected ヘッダ**のうち、ファイル名が変わったもの（実測: `TP_ThirdPersonCharacter` / `TP_ThirdPersonGameMode` / `TP_ThirdPersonPlayerController`の3つ）について、`Config/DefaultEngine.ini`の`[/Script/Engine.Engine]`へ`+ActiveClassRedirects=(OldClassName="…",NewClassName="…")`を書くようになった。UEウィザードの`IsClassRename`（拡張子`h`かつ**コピー後**の内容に`.generated.h"`を含む）と同じ判定で、新旧名は実際に生成された名前を使う。
- 従来は`[CoreRedirects] +PackageRedirects`しか書いておらず、これは`/Script` package部分だけを付け替えるため、改名済みクラスを指すBlueprint（既定`GlobalDefaultGameMode`と既定mapが依存する`BP_ThirdPersonGameMode`等）は存在しないクラス名を指したまま残っていた。**`+PackageRedirects`は残し、class redirectを追加する**（置き換えではない）。
- 出力したredirectは生成時のstdoutに`Class redirects: <旧> -> <新>, ...`（0件なら`Class redirects: none (...)`）として出る。`template-lock.json`のprovenance契約（`UE-PROV-001` / `UE-LOCK-001`）は変えていない。
- `scripts/Test-UETemplateScaffold.ps1`に回帰assertionを追加。fixtureのtemplateへ reflected ヘッダ3つ（改名され生成物に残る）、`h`だが`.generated.h`を含まないヘッダ（`TP_ThirdPerson.h`同等）、ファイル名が変わらない reflected ヘッダ（`Variant_Combat/CombatEnemy.h`同等）を置き、**改名した reflected ヘッダ数だけ**`+ActiveClassRedirects`が出ること、負例2件がredirectを出さないこと、`+PackageRedirects`が残ること、section配置とstdoutの報告をassertする。
- `templates/recipes/third-person-game/Play.md`と`docs/07-architecture.md`の記述を実際の出力に合わせた。

実測（本host: Windows 10.0.26300 / pwsh 7.6.9 / 実インストール済みUE 5.8.4 CL 58902052を`-EngineRoot`に指定）: `third-person-game`生成物の`Config/DefaultEngine.ini`は`+ActiveClassRedirects`3行と`+PackageRedirects`1行を持つ。`spectator-explore`（432ファイル）と`vertical-loop`（12ファイル）の生成物は、同一commit内で比較して**ファイル一覧も内容も不変**（`template-lock.json`の`template_commit`のみcommit差を反映）。`scripts/Test-UETemplateScaffold.ps1`は8群PASS / exit 0で、前後の`git status --porcelain --untracked-files=all`は一致。

移行: 旧版で生成済みの`third-person-game`projectは、同じ`-ProjectName`で再生成するか、`Config/DefaultEngine.ini`の`[/Script/Engine.Engine]`へ同等の`+ActiveClassRedirects`を手で追記してからEditorで開く。`.uasset`は書き換えない。**UE Editor起動・Blueprint compile・PIE・MRQ・renderは未実行**で、redirectによる解決は実機確認していない（Unverified）。

## Unreleased — DOT-3217（UE-ENCODEPRESET-001）

- **文書にあった唯一のエンコード例が landscape preset の尺を落としていた。** `docs/05-qa.md` は `vertical`（8秒）と `landscape`（10秒）の2 preset を定義していたが、encode 例は `-frames:v 240` 固定だった。`-frames:v` は出力フレーム数の**上限**なので、landscape の 300 frame に同じコマンドを当てると **240 frame / 8.0 秒で ffmpeg が exit 0** を返し、続く ffprobe も「240 frame / 8.0 秒」と正しく報告する。文書は期待値の出所を書いていなかったため、「240 を期待値にする」経路が残っていた。
- **preset を1箇所のデータにした。** `templates/CAPTURE-PRESETS.json` が解像度・fps・秒数・開始番号・桁数・codec/crf の唯一の定義で、フレーム数は `fps × 秒数` から導出する（定義に `frame_count` を併記すると `preset_invalid` で落ちる）。`docs/05-qa.md` と `README.md` から同じ数値の再掲を外し、文書は定義から生成した行を使う形にした。`templates/recipes/vertical-loop/Capture.md` の開始案の数値（1080×1920/30fps/8秒）は変えていない（この recipe の差分ではないため）。
- **`scripts/Get-UECaptureEncodePlan.ps1` を追加。** preset 名を引数に取り、画像列検査（`Measure-UERenderArtifacts.ps1`）・ffmpeg encode・ffprobe・尺検査の各コマンドを定義から生成して表示する。render/encode は実行しない。
- **`scripts/Measure-UECaptureEncode.ps1` を追加。** エンコード済み MP4 を、preset 定義の期待 frame 数・秒数・解像度・fps と照合する読み取り専用の検査器。期待値をコマンド引数で受け取らない（手書き期待値の経路を作らない）。video stream 数が1本でない・ffprobe 不在・timeout・値不一致は pass にしない。新規 render / UE 起動 / process kill は行わない。
- **`scripts/Test-UECaptureEncode.ps1` を追加。** 自作 fixture（ffmpeg `testsrc2`）で、旧コマンド相当の「300 frame preset を 240 frame で encode → ffmpeg は exit 0、検査は `fail`」、正しい 300 frame の `pass`、299 frame の `fail`、fps/尺だけ違う動画の `fail`、ffprobe 不在の `unverified`、video stream 2本の `fail`、未定義 preset と既存 report path の拒否、定義側の frame 数重複・非整数の拒否を固定した（11 group）。
- `docs/05-qa.md` に「**`-frames:v` は上限であり尺の検証ではない**」「尺は preset 定義と ffprobe 実測の照合で判定する」を明記し、`templates/QA.md` に preset 名・期待 frame 数・秒数・解像度・fps・画像列範囲・転記元の記入欄と、`evidence/encode-check.json` の判定行を追加した。
- `.github/workflows/verify.yml` に `capture-encode` job を追加し、`scripts/Test-UECaptureEncode.ps1` を CI で回す。ffmpeg/ffprobe が無い runner では suite は `SUITE_EXIT=2`（UNVERIFIED）で止まり、pass にはしない。
- 定義ファイルは BOM なし UTF-8 なので、3 script とも `Get-Content -Raw` ではなく `[System.IO.File]::ReadAllText(..., UTF8Encoding)` で読む。Windows PowerShell 5.1 は BOM なし UTF-8 を ANSI code page で復号し、`templates/CAPTURE-PRESETS.json` の日本語 `use` 欄が `ConvertFrom-Json` の前に壊れるため（本 host の 5.1 で再現、`pwsh` では出ない）。

実測（本 host、Windows 10.0.26300、`pwsh 7.6.9` と `Windows PowerShell 5.1.26100`、ffmpeg/ffprobe 8.1.2-full_build-www.gyan.dev を既存のまま使用・新規導入なし）: 300 枚の 1920×1080 PNG に旧文書のコマンドを逐語で当てると `ffmpeg` exit 0 / ffprobe `nb_read_frames=240` `duration=8.000000` / 1920×1080。同じ MP4 を `Measure-UECaptureEncode.ps1 -Preset landscape` に当てると `VERDICT: fail` / exit 1 / `frame_count_mismatch`（期待300・実測240・差 -60）と `duration_mismatch`（期待10秒・実測8秒）。`Test-UECaptureEncode.ps1` は 11 group PASS / `SUITE_EXIT=0`（`pwsh` 約27秒、`powershell.exe` 5.1 も `SUITE_EXIT=0`）。

回帰: 変更前 HEAD `8f58615` の使い捨て clone に新規 3 script と `templates/CAPTURE-PRESETS.json` だけを置いて `Test-UECaptureEncode.ps1` を実行すると **`SUITE_EXIT=1` / `ASSERT FAILED: docs\05-qa.md does not repeat the vertical frame count as a literal encode limit`** で落ちる（検査器が盲目でないことの確認）。既存 `scripts/Test-UETemplateScaffold.ps1` 8 group と `scripts/Test-UERenderArtifacts.ps1` は本変更の前後で変化させていない。

移行: 既存 project と `Production/`・`Out/` の生成物には触れない。新しい案件は `Get-UECaptureEncodePlan.ps1 -Preset <vertical|landscape>` の出力行を使い、encode 後に `Measure-UECaptureEncode.ps1` の report を `evidence/` へ残す。preset を変える案件は `templates/CAPTURE-PRESETS.json` を更新し、文書側の数値を手で直さない。

未検証（Unverified Scope）: UE 5.8.4 の MRQ / compile / PIE / Editor / Shipping は本 host で実行していない。実 MRQ が landscape preset で 300 枚出力するかは観測していない。MRQ の既定命名（`ZeroPadFrameNumbers` などの engine 既定）と `docs/05-qa.md` が前提する `%06d`・0 開始の一致も未確認。本変更の根拠は、本 host の ffmpeg/ffprobe 実測と自作 PNG fixture に限る。

## Unreleased — DOT-3448

- 納品セットが要求していた「README操作表」に、雛形・配置先・受領証欄・検査のどれもが無かった。`templates/README.md`を新規に追加し、作品名/Issue/run ID、対象版とREADME自身のSHA-256、起動方法、操作表（視点/移動/zoom/reset/help/終了）、既定解像度・fps・尺、前提、同一版の紐づけ、非目標/未実装、既知の不具合の欄を持つ雛形にした。web上の一般論ではなく、`docs/04-package.md`と`docs/05-qa.md`の実手順に合わせている。
- `docs/06-delivery.md`の納品セットを表にし、各項目の`Out/run_<runid>/`の配置先と正本（`templates/README.md`等）を1箇所で定義した。`AGENTS.md`の`Out/run_<runid>/`列挙に`README.md`を加え、フォルダ契約と納品セットの不一致（README欠落）を解消した。規則を2箇所に重複して書かず、納品セットを正本にした。
- 受領証欄を追加した。`templates/DELIVERY.json`に`readme_receipt`（`filename` / `sha256` / `version_sha256` / `operation_table_rows` / `unverified_rows`）と、未定義のまま増やさないための`artifact_kind_vocabulary`（`video_mp4` / `thumbnail` / `shipping_zip` / `readme` / `credits` / `qa` / `delivery_manifest` / `sha256sums`）を置いた。`templates/QA.md`に「納品READMEの操作表・起動方法・対象版SHA」の1行を追加した。
- `scripts/Test-UETemplateScaffold.ps1`に、`docs/06-delivery.md`の納品セット各項目が`AGENTS.md`の列挙と`templates/`の実ファイルへ解決し、`DELIVERY.json`が`kind`語彙と`readme_receipt`を定義し、`QA.md`がREADMEの行を持つことを機械照合するgroupを追加した。既存8 groupは1件も削っていない。
- 同じgroupに、isolated fixtureを`git clone`で作り、`templates/README.md`削除、`AGENTS.md`の列挙から`README.md`削除、`QA.md`のREADME行削除、`DELIVERY.json`の`readme_receipt`削除の4通りを当てて、それぞれpathを名指しで落ちることと、復旧すると沈黙することをassertした。gate自体が空assertに戻ればこのgroupが落ちる。

### 実測（本host）

- `pwsh 7.6.9` / `git rev-parse HEAD` = `8f586157c2e58734bdbce90b4d975f8d4f8201f7`（base）+ 本変更: `scripts/Test-UETemplateScaffold.ps1` = **9 group PASS / exit 0**。
- Windows PowerShell 5.1: 同suite = **9 group PASS / exit 0**。
- 変更前HEAD `34f2cbb61c8e43901325376ea7c69cb9555f9e32`のtreeに同じgateだけを当てた probe: `PROBLEMS=14`（`templates/README.md`の不在、`AGENTS.md`の列挙欠落、`readme_receipt`不在、`artifact_kind_vocabulary`の`readme`不在、`QA.md`のREADME行不在、納品セット4項目の記載なし）。変更前は落ちる。
- `scripts/Test-UERenderArtifacts.ps1`は未変更。回帰として実行し、**13 group PASS / exit 0**。
- `git status --porcelain --untracked-files=all` はsuite実行の前後で不変（suite末尾の比較で確認）。

### 移行

- 既存の納品物と`Production/`の生成物には触れない。`templates/README.md`は新規で、既存作品のREADMEを流用していない。
- これまでREADME無しで納品した作品は、納品セットの必須項目が欠けたままである。再納品する場合は新runの`Out/run_<runid>/README.md`として`templates/README.md`から作る。旧runの成果物を書き換えない。
- `DELIVERY.json`の`schema_version`は1のまま。既存の納品記録がある場合は、`readme_receipt`と`artifact_kind_vocabulary`を追加するまで次回の納品は`Unverified`として扱う。

### Unverified Scope

- README操作表の内容が実機で正しいか（実際のキー割当・起動引数・既定解像度）は本hostで検証していない。本変更が固定するのは「雛形があり、納品セット・`AGENTS.md`・`templates/`が一致し、消せば落ちる」という機械的事実だけ。
- UE Shipping ZIP / Mac `.app`の実梱包物と、実exeの起動は未実行。
- `artifact_kind_vocabulary`の追加が既存の納品記録と衝突しないかは、実案件の`DELIVERY.json`実物がrepoに無いため未確認。
- UE install / compile / Editor / PIE / MRQ / render / Shippingは本変更でも実行していない。

## Unreleased — DOT-3451

- `scripts/New-UETemplateScaffold.ps1` の `template-lock.json` の `plugins` は、recipe の `required_plugins` だけではなく **生成 `.uproject` の `Plugins` 配列の全 entry** を記録する。各 entry は `{ version, source, enabled_in_project }` で、`version` は当該 install の `.uplugin` の `VersionName`（空なら `Version`）、`source` は `project`／`repository`／`engine`、`enabled_in_project` は生成 `.uproject` の `Enabled`。`lock.schema_version` は 3。
- 生成 `.uproject` で `Enabled: true` の plugin は、コピー**前**に `.uplugin` の実在を確認する。生成projectの`Plugins/<Name>/<Name>.uplugin` → repo の `templates/online/<Name>/<Name>.uplugin` → `Engine/Plugins/<Category>/<Name>/<Name>.uplugin` → `Engine/Plugins/**` の再帰探索の順で探し、見つからなければ**出力directoryを作らずに停止**して未解決plugin名と探索pathを列挙する。以前は `ModelingToolsEditorMode` / `StateTree` / `GameplayStateTree` などの template 由来 plugin を実在確認せず `Enabled = $true` で書き、`exit 0` で「その Engine では開けない project」を出していた。
- plugin 版は `.uplugin` から読めない場合に文字列 `unknown` を残し、推測値・既定値を入れない。固定 map（`MovieRenderPipeline` / `OnlineSubsystem*` / `MulticaOnlineStarter`）に無い plugin 名でも停止しない（探索で解決する）。`engine_version` / `engine_changelist` は従来どおり `Engine/Build/Build.version` の写しで、plugin 版を混ぜていない（DOT-3114 の領域は変えない）。
- 変更理由: `docs/07-architecture.md:33` が「Engine/plugin version を固定する」と宣言し `:37` が「生成時の dependency drift を lock で可視化する」と述べていたが、plugin 側は recipe 宣言分だけを記録し、実在検証も無かった。実在 plugin 集合が異なる 2 つの Engine install から byte 一致の lock が出ていた（本host実測: 実 install と、`StateTree`/`GameplayStateTree`/`ModelingToolsEditorMode` を置かない fixture Engine で同じ `ProjectName`/`RunId`/`ProjectDiff` を生成すると lock が `-ceq` = True）。修正後は同じ手順で `plugins` が異なり lock は一致しない。
- 回帰 suite `scripts/Test-UETemplateScaffold.ps1` を追随させた。`TP_ThirdPerson` fixture を実 template の形（3 plugin enable）に直し、`schema_version: 3` と `plugins.<Name>.version/source/enabled_in_project` の assertion へ更新し、**lock の plugin key 集合が生成 `.uproject` の `Plugins` と一致する**ことを group ごとに比較するようにした。負例として、fixture Engine に存在しない `PhantomPlugin` を enable した生成が `Plugin identity check stopped` で止まり、plugin 名と探索pathを出し、**出力 directory を残さない**ことを assert する（変更前の generator では同じ入力が `exit 0` / lock 書き出し / 出力 directory ありで通っていた）。
- `docs/07-architecture.md` に plugin identity 契約表を1つ追加し、`schema_version: 3` と `plugins` の形を1箇所だけ書いた。`:33` の「Engine/plugin version」が何を指すか（Engine build と、生成 project が enable する plugin の版）を明記した。`README.md` / `docs/01-start.md` の「`.uproject` の plugin 設定を確認」を、`.uproject` の `Plugins`・lock の `plugins`・実 `.uplugin` の3点照合へ具体化した。`AGENTS.md` の identity 段落に plugin identity を1段落追加した。
- **移行**: 既存生成物（`Production/<Name>_<runid>/`）は再生成も書き換えもしない。`schema_version: 2` の lock はそのまま残り、`identity` の有無と `schema_version` の値で新旧を判別できる。新契約が要る作品は**新しい RunId で生成**し、`plugins` を旧 lock と比較してから採用する。旧 lock に `plugins` を手で追記しない。`schema_version: 2` の lock を入力にする検査は無い（lock は writer が書き、読む側は recipe を読む）。
- 本host実測（Windows 11 / `pwsh 7.6.9` / Windows PowerShell 5.1.26100.9711 / 実 UE 5.8.4 CL 58902052）: `scripts/Test-UETemplateScaffold.ps1` = 10 group PASS / `exit 0`（`pwsh`）、10 group PASS / `exit 0`（Windows PowerShell 5.1）。実 install から 3 recipe を生成し、`plugins` の key 集合が `.uproject` の `Plugins` と一致（`third-person-game` = 4件、`spectator-explore` = 8件、`vertical-loop` = 2件）。版は `ModelingToolsEditorMode` 0.1 / `StateTree` 0.1 / `GameplayStateTree` 1.0 / `MovieRenderPipeline` 1.3 / `OnlineSubsystem*` 1.0 / `MulticaOnlineStarter` 1.0.1 と、実 `.uplugin` の値に一致した。
- **Unverified Scope**: UE 5.8.4 の起動 / compile / Editor / PIE / MRQ / render / Shipping / packaged build は本変更で一切実行していない。plugin 実在検証は `.uplugin` ファイルの有無と `VersionName` の読取に閉じており、「Editor が実際にその plugin をロードできるか」「`TargetAllowList` が効くか」は観測していない。検証は PowerShell と JSON の層と、本 host の実 install 上の read-only 参照に限る。GitHub Actions `windows-latest` での suite 実行結果は本変更の CI 実行で確認する（本 host の実測ではない）。

## Unreleased — 動画モーキャプ

書式: 各 `## ` 見出しは `## Unreleased — <DOT番号 or 名前> — <識別子>` の形にする。**識別子は必須**で、`YYYY-MM-DD`（main に入った merge commit の日付。`git log -1 --date=short --format=%cd <merge>` か `gh pr list --state merged` の `mergedAt`）または 40 桁 commit SHA のどちらかを書く。日付だけでは「どの変更か」を commit に結べないので、SHA を併記してよい（併記した SHA は `git cat-file -e <sha>^{commit}` で解決できること）。release も tag も作らないので全節が `Unreleased` のまま。各節の本文には、次を 1 項目ずつ残す:

1. 何が変わったか（推測で書かず、差分から読む）
2. 移行が必要か（必要なら何をするか。不要なら「移行不要」と書く）
3. Unverified Scope（実行していない検証を成功と読ませない）

読み取り経路は `README.md` の「入口」表と `AGENTS.md` の「先に読む」。`scripts/Test-UETemplateDocs.ps1` が、route の到達性（C1）と見出し識別子（C2）を検査する。識別子は日付だけを必須にし、SHA は書かれたときだけ解決を検査する。`.github/workflows/verify.yml` の checkout が `fetch-depth: 1` で、古い merge commit の SHA は解決できないため（日付は shallow clone でも常に読める）。

## Unreleased — DOT-3454 — 2026-11-12

- `CHANGELOG.md` は tracked file から一度も参照されておらず（`git grep -c 'CHANGELOG' -- ':!CHANGELOG.md'` = 0 件）、`README.md` の「入口」表にも `AGENTS.md:5` の「先に読む」にも無かった。`docs/07-architecture.md` が要求する「変更理由・移行手順・検品結果を残す」記録の唯一の置き場が読まれない状態だったので、両方から名指すようにした。
- 見出し 5 個（当時）がすべて `Unreleased — <DOT番号 or 名前>` で、40 桁 SHA も ISO 日付も無かったため、「どの版の話か」を機械的に決められなかった。全節へ識別子を付与し、書式をこのファイル冒頭の「書式」段落に固定した。
- 未記録だった merge 済み delivery 5 件（`DOT-3029` / `UE-CI-002` / `DOT-3313` / `DOT-3317` / `DOT-3340`）の節を追加した。既存 5 節の本文は削っていない。
- `scripts/Test-UETemplateDocs.ps1`（新規）で C1（`CHANGELOG.md` が `README.md` の入口表と `AGENTS.md` の「先に読む」から名指されていること）と C2（各 `## ` 見出しが 40 桁 SHA か ISO 日付を持つこと、本文が空でないこと、指定 delivery の節が消えていないこと）を検査する。負例 6 通り（削除 / route 行除去 / 識別子除去 / 解決しない SHA / `AGENTS.md` route 除去 / 節の消失）が path を名指しして落ち、復旧で沈黙することを同じ suite で確認する。`.github/workflows/verify.yml` に `docs-route` job を追加した。

移行: repo 側の文書と test だけ。既存 project・`Production/`・`Out/` の生成物は触らない。識別子の日付は各 merge の日付で、値は書き換えも再生成もしない。

Unverified Scope: 「エージェントが実際に `CHANGELOG.md` を読んで移行判断を誤らなくなるか」は観測していない。本件の主張は「route から到達できない・見出しに識別子が無い・削除しても検査が落ちない」という機械的事実に限る。UE 5.8.4 の起動 / compile / Editor / PIE / MRQ / render は実行していない。本件以降に main へ入った delivery（`DOT-3397` / `DOT-3398` / `DOT-3399` / `DOT-3400` 以降の PR）は本件の範囲外で、節が無いまま。`Test-UETemplateDocs.ps1` の `requiredSections` に個別列挙しているため、新規 delivery を列挙に加えないと「節の消失」は検出できない。

## Unreleased — 動画モーキャプ — 2026-11-12

- `docs/09-video-mocap.md` を追加した。単眼のダンス動画から MediaPipe で体・手・顔の点を取り、VRM の骨の回転 → VRMA → UE（VRM4U）→ MV にする工程、単眼で取れない量の補い方、確認方法、1 本での実測、残る限界、権利の gate をまとめた。
- 図は工程図・棒人間・腰の高さのグラフだけで、元動画・キャラの画像は入れていない。スクリプトは非公開の制作 repo にあり、本 repo には同梱しない。

## Unreleased — DOT-3122

- `docs/PROVENANCE.md` は README の入口表で「実績と未確認点」の正本を名乗りながら、2026-10-31 の 15 ファイル時代で止まっていた。そのため `:18` の「UE生成/build/render/アセット取得scriptは同梱しない」が、同梱済みの `scripts/New-UETemplateScaffold.ps1`（generator）と `scripts/Test-UETemplateScaffold.ps1`、Null/LAN plugin、3 recipe、`docs/07` の 6 層と正面から矛盾していた。`:19` の「納品添付の検証記録を参照」は tracked file に解決せず、`2026-11-02` の実績（UE Editor build）も 1 件も無かった。
- 同梱物の主張を散文からデータへ移した。`docs/PROVENANCE.inventory.json`（`schema_version: 1`、`bundled` / `not_bundled`）が正本で、`docs/PROVENANCE.md` の散文はその写しである。語の一致で判定すると「UE本体は同梱しない」のような**修正後の正しい文**を偽陽性で落とすため、判定対象を構造化データにした。
- 新規 `scripts/Test-UETemplateProvenance.ps1`（`-RepoRoot`、既定は script から `..`）を追加。R1 `not_bundled` が tracked path に一致したら FAIL（虚偽の「無い」）、R2 `bundled` が 1 件も一致しなければ FAIL（宙に浮いた「有る」）、R3 tracked の全 top-level area が未分類なら FAIL（新しい層の追加漏れ）、R4 source document の相対リンクが tracked file に解決しなければ FAIL。出力は 1 行 1 件 `FAIL: <rule>: <detail>`、exit 0 = PASS / 1 = rule 違反 / 2 = guard 自体が動けない（inventory 破損・git 失敗）。`git ls-files -z` を使うので空白・改行を含む path でも壊れない。
- 新規 `scripts/Test-UETemplateProvenance.Tests.ps1`：使い捨て git repo の fixture で負例を固定する。`not_bundled` に `scripts/*`、`bundled` から `docs/*` を落とす、宙に浮いた `docs/09-missing.md`、未分類の新 top-level `tools/`、解決しない相対リンク、空白入り path、未 track の inventory、壊れた JSON の 8 ケースがすべて期待どおり落ちること、checkout を書き換えないことを assert する。
- `docs/PROVENANCE.md` を現在の tree に合わせて書き直した。「script は同梱しない」を撤回し、同梱する層（generator・検品helper・回帰suite・3 recipe・用途部品・Null/LAN starter・CI）と同梱しないもの（UE 本体、build/render 本体、素材実物、生成物）を列挙した。`docs/07-architecture.md` が宣言する層を「tracked での実体」「実装状態」「未検証範囲」で対応づける表を追加し（07 の宣言 8 行を 6 行に集約。三人称ゲームはジャンルrecipe、検品helper は共通基盤の行に含む）、2026-11-02 の UE Editor build（実施者報告、exit 0 / 37 actions / 94.22 秒）を検証履歴に記録した。scope 日付（`docs/PROVENANCE.md` と `docs/PROVENANCE.inventory.json` の `last_reviewed`）は、この PR が tree を最後に確認した日 2026-11-13 に揃えた。`:19` の参照先を、実在する `docs/08-online-foundations.md` の「検証履歴」・`CHANGELOG.md`・各 Issue comment へ差し替えた。
- `.github/workflows/verify.yml` に provenance guard とその回帰 suite の step を追加した。guard を CI に繋がないと、次の層追加で再び陳腐化する。
- `docs/07-architecture.md` の継続改善節から guard を参照し、層・area の追加と同じ commit で inventory を更新する契約を明記した。
- `origin/main` の取り込み時、`docs/09-video-mocap.md`（動画モーキャプ）を共通基盤の実体と検証履歴に取り込んだ。CHANGELOG の `Unreleased` 競合は両項目を並べて解消した（どちらも同じ `Unreleased` 行にすでに並んでいた既存項目の再編）。

実測（本 host、2026-11-13、`pwsh 7.6.9` と Windows PowerShell 5.1 の両方）：修正後 tree は `PASS: R1`〜`R4` で exit 0。guard 追加前の tree（`a9e31bc`）に guard だけを置くと、guard は inventory を要求するため `FAIL: inventory: the inventory file does not exist: ...docs/PROVENANCE.inventory.json` で exit 2 になり、R1 までは到達しない。R1 を働かせるには、当時の主張（`not_bundled` に `scripts/*`）を inventory として seed した同 tree を使う。その seeded tree では `FAIL: R1: not_bundled pattern 'scripts/*' matches tracked path 'scripts/New-UETemplateScaffold.ps1'` を含む R1 行で exit 1。seed は R1 を動かすための測定用の改変であり、「a9e31bc そのものが exit 1 で落ちた」という主張ではない。`scripts/Test-UETemplateProvenance.Tests.ps1` は 10 の負例/正例 assert group と最終の網羅確認を合わせて 11 行 PASS・exit 0、`scripts/Test-UETemplateScaffold.ps1` は 12 assertion group PASS / exit 0（`origin/main` 取り込み後の suite。回帰なし）。`0` 件の `git status --porcelain --untracked-files=all` が実行前後で不変。

移行：既存 project・`Production/`・`Out/` の生成物には触れない。inventory は現行 tree の分類であり、新しい top-level ディレクトリを新設する変更は同じ commit で `bundled`/`not_bundled` を更新する（更新しないと R3 で落ちる）。UE の install/compile/Editor/PIE/MRQ/render は本変更で一切実行していない（Unverified Scope のまま）。

## Unreleased — DOT-3118

- recipe層の合成を**名前の直書きからデータ駆動へ**移した。`scripts/New-UETemplateScaffold.ps1` の `-Recipe` から `ValidateSet` を廃止し、`templates/recipes/<Recipe>/recipe.json` の実在とスキーマ検証で受ける。recipeディレクトリを追加するだけで新層が使え、generatorの編集は不要。存在しない名前は停止し、出力ディレクトリを作らない。
- `if ($Recipe -eq 'spectator-explore')` / `-eq 'third-person-game'` の分岐を削除した。`Play.md` のコピー可否は**recipeディレクトリに`Play.md`が実在するか**で、`Capture.md`は全recipe必須、`Plugins/MulticaOnlineStarter`・`docs/08-online-foundations.md`・`Config/DefaultEngine.ini` のonline設定は**`required_plugins`に`MulticaOnlineStarter`が含まれるか**で決まる。lock・`.uproject`の`Plugins[]`・実体のtreeが同じデータから生成される。
- `recipe.json` のスキーマ検証を追加。`schema_version`（実装は`1`のみ）/ `recipe` / `purpose` / `engine_template` の欠落・型不正・空文字、`required_plugins`の非配列・空要素・重複・未知plugin、`materialize_project`の非bool、`Capture.md`の欠落をすべて**生成前の停止条件**にした。不明を`""`としてlockへ書かない。
- recipe識別子を一本化。lockの`recipe`は**実際に合成したディレクトリ名**とし、`recipe.json`の`recipe`がディレクトリ名と一致しない場合は**停止**する。`recipe.json`側の名前を黙って採用しない。
- `purpose` の契約を実態に合わせた。**合成判断には使わない**（composition・plugin・Play差分は変えない）が、`recipe.json` は `Recipe/recipe.json` へ逐語コピーされ `template-lock.json` にも記録されるため、`purpose` だけを変えるとこの**2ファイルは実際に変わる**。回帰testはファイル集合とその他のbyte一致を比較し、この2ファイルは「変わることが期待値」として別にassertする（従来の断言はこの2ファイルを比較対象から外していたため、差分を隠していた）。
- 未知recipe名の失敗メッセージが「選択肢」として列挙するディレクトリを、`recipe.json` を持つものだけに限った。`templates/recipes/common/` は `SET.md` だけを持ち選択できないのに案内されていた（その名前で実行すると同じ失敗が再現する）。回帰testで `common` が一覧に載らないことと `spectator-explore` / `vertical-loop` が載ることをassertした。
- suiteのcleanup検証を修正した。`%TEMP%` の recipe fixture root の残留assertが、直後の `$cleanupProblems = @(Get-ProductionResidue …)` 代入で**捨てられていた**（temp rootが漏れてもcleanと表示されるdead check）。代入後に移し、両rootの残留を同じ檢查に含めた。
- `scripts/Test-UETemplateScaffold.ps1` に recipe層の assertion group を5つ追加（既存8 → 13 group）。データ追加だけで生成できること／`Play.md`の有無で合成が変わること／`required_plugins`の増減が`Plugins/`・descriptor・lockへ同時に反映されること／`purpose`がcompositionを変えないこと（lockとコピーされた`recipe.json`だけが変わる）／データ不一致（名前不一致・field欠落・未知plugin・`Capture.md`欠落・未知recipe名・`recipe.json`非所持ディレクトリ）が**出力ディレクトリを作らず停止**すること／既存2recipeの`Recipe/`・`recipe`・`purpose`・plugin集合が不変であること。fixtureはrepoの`Production/`ではなく短い一時ディレクトリにcloneする（clone下の`Production/<Name>_<runid>/`はWindowsのpath長を超えるため）。
- `docs/07-architecture.md` に「recipeを追加する手順」を新設（置くファイル、`recipe.json`の必須field、`required_plugins`と`Plugins/`の関係、`purpose`の扱い、lockに載る項目）。`docs/01-start.md`の「選択可能な値はgeneratorの`ValidateSet`」、`README.md`、`docs/08-online-foundations.md`の「game-and-capture recipeにだけコピー」を新契約へ揃えた。

### 測定（本host、UEを起動しない範囲）

`pwsh 7.6.9` と Windows PowerShell 5.1 の両方で `scripts/Test-UETemplateScaffold.ps1` は **13 group PASS / exit 0**（既存8 groupの出力はそのままに recipe層5 group を追加）。変更前 `adfb5ee` に同じ fixture を当てると、R1（recipe追加のみ）は exit 1 / R2（名前ゲート開放）・R3（`purpose`変更）・S1（`required_plugins`縮小）・T1（名前不一致）・T2（field欠落）は **exit 0 のまま食い違う lock と実体を出力**した（本Issueの baseline を再現）。変更後は同じ入力でR1が成功し、R2/S1/T1/T2 は停止、R3 は設計どおりcompositionが同一でlockとコピーされた`Recipe/recipe.json`だけが変わる。

### 移行

- **既存の生成済みprojectは再生成しない。** 生成物の`Recipe/`・`Plugins/`・`template-lock.json`の変更は、次のRunIdで生成した新projectだけに現れる。
- 以前に「game-and-capture」として生成したprojectが`required_plugins`を縮小/拡張したrecipeで作られていた場合は、lockの`plugins`と実ファイルが食い違っている可能性がある。`Plugins/MulticaOnlineStarter`の有無とlockの`plugins`を実物で突き合わせ、必要なら新RunIdで生成し直す。旧lockを手で書き換えない。
- recipeを追加しただけのrepoで既存2recipeの生成結果は変わらない（回帰assertionで固定）。

### Unverified Scope

- UE 5.8.4の起動 / compile / Editor / PIE / 2-client LAN / MRQ / render / Shipping は本変更で一切実行していない。本変更はPowerShell generator・回帰suite・docs層に閉じる。
- 本hostに実UE installは無く、計測は合成Engine fixture（`Engine/Build/Build.version` 5.8.4 / CL 58902052、`Templates/TP_FirstPerson` / `TP_BlankBP` / `TP_ThirdPerson`、engine plugin descriptor 4本）に対する生成の実測である。実UE installに対する生成成功の証明ではない。
- 新recipeの意味づけ（受入条件・撮影手順）はデータを置く人の責任であり、generatorはファイルの実在・整合しか検査しない。

## Unreleased — DOT-3187

- `templates/online/MulticaOnlineStarter` の provider 設定は、engine が読まない名前の carrier に置かれていた。旧 `Config/DefaultEngine.ini` は UE 5.8.4 の plugin config loader が `{PLUGIN}/Config/{TYPE}.ini`（既存 branch を変更する layer）にも `{PLUGIN}/Config/Default<PluginName>.ini`（plugin 自身の branch）にも解決できず、`ConfigCacheIni.cpp:7275` で `DefaultEngine` という branch 名を作った後 `:7294-7301` で Verbose ログだけ残して捨てる。`[OnlineSubsystem] DefaultPlatformService=Null` は宣言だけが残り、`GEngineIni` には届いていなかった。
- 旧 `scripts/Test-UETemplateScaffold.ps1` は生成物の `Plugins/MulticaOnlineStarter/Config/DefaultEngine.ini` の**本文**に `DefaultPlatformService=Null` が含まれることだけを見ており、carrier 名が解決されるかを検査していなかった。そのため carrier 名を `Engine.ini` に変えても `DefaultEngine.ini` のままでも同じく PASS し、6 群 PASS / exit 0 のまま出荷されていた。
- plugin の carrier を廃止し、provider/session 設定の唯一の置き場所を**生成 project の `Config/DefaultEngine.ini`**（`{PROJECT}/Config/Default{TYPE}.ini`、`Misc/ConfigHierarchy.h:68`）に固定した。plugin は `Config/` を同梱しない。
- test の plugin 検査を**本文文字列一致から carrier 名の解決規則**へ置き換えた。既知 branch（`Engine`/`Game`/`Input`/…、`Misc/ConfigCacheIni.h:101-111`）と plugin branch（`Default<PluginName>`）に解決する名前だけを受理し、plugin 配下の ini が 1 本でも未解決名なら停止する。project 側 carrier も `Default{TYPE}.ini` / `{PLATFORM}{TYPE}.ini` の形を検査する。負例（plugin 側 `Config/DefaultEngine.ini`、project 側 `Config/Engine.ini`）を fixture として固定し、解決できる名前（`Config/Engine.ini`・`Config/Default<PluginName>.ini`・`Config/Windows/WindowsEngine.ini`）は受理することを同じ group で assert する。
- `templates/online/MulticaOnlineStarter/README.md` は、編集すべきファイル（生成 project の `Config/DefaultEngine.ini`）と carrier 名の契約、`LoadDefaultSubsystem` が未設定・ロード失敗時に `NULL_SUBSYSTEM` へ fallback すること（`OnlineSubsystemModule.cpp:205-221`）を明示する。`docs/08-online-foundations.md` の実装節と検証履歴も同じ内容へ揃えた。
- `MulticaOnlineStarter` の C++ 挙動、generator のコピー経路・materialize 経路、`templates/recipes/**` は変更していない。

Measured on this host (Windows 10.0.26300, Windows PowerShell 5.1.26100.9711, pwsh 7.6.9): `scripts/Test-UETemplateScaffold.ps1` 9 groups PASS / exit 0。DOT-3187 の carrier 検査を `aa113700b0ce4d2bbe32dbb7bd2bdec91d5531d0` の実 tree（`Plugins/MulticaOnlineStarter/Config/DefaultEngine.ini` のみ）へ当てると `the engine cannot resolve 'DefaultEngine.ini' to a config branch` で落ち、変更後は 0 件。`-dumpiniloads` / `LogConfig` Verbose による実ログ取得、Editor 上での `DefaultPlatformService` 実効値、PIE・2-client LAN・EOS/Steam は未検証（Unverified Scope）。

移行（重要）: **既存の生成済み project は自動変換しない。** 旧 scaffold が出した `Plugins/MulticaOnlineStarter/Config/DefaultEngine.ini` は engine に読まれない（`Test-UETemplateScaffold.ps1` のcarrier 検査を `aa11370` の実 tree へ当てると 1 件で落ちる）。必要な作品は**新しい RunId で再生成**するか、project 自身の `Config/DefaultEngine.ini` に `[OnlineSubsystem] DefaultPlatformService=Null` を書いて採用理由と日付を作品の QA に残す。旧ファイルを `Config/Engine.ini` へ改名して済ませる運用は、plugin modification layer として `Engine` branch に届くかどうかを未完のまま使うため、本 PR では勧めない（実測は `-dumpiniloads` の別 receipt とする）。

## Unreleased — DOT-3186

- `AMulticaOnlineGameMode` の leave 経路が人数を減らしていなかった。UE の `AController::Destroyed` は `GameMode->Logout(this)` を `CleanupPlayerState()` と `UWorld::RemoveController()` **より前**に呼ぶ（engine 5.8.4 同梱 source、`Controller.cpp:595-612`）。したがって `Logout` の時点で離脱する PlayerController は world の player-controller list にまだ入り、`PlayerState` もまだ非 null であり、`GetNumPlayers()` は離脱者を数え続ける。`AMulticaOnlineGameState::SetConnectedPlayerCountFromServer` は同値で早期 return するため、replicated `ConnectedPlayerCount` は join では増えるが **leave では 1 も減らなかった**。
- 修正方針は「離脱者を数えない」ではなく「**残る player を数える**」。`Logout` は `RefreshConnectedPlayerCount(Exiting)` を呼び、`CountConnectedPlayers(ExcludedController)` が world の player-controller list を走査して `Exiting` を**数える前に除外**する。減算ではないので、元々数えていなかった spectator-only の離脱で実 player 数を下回ることはない。述語は engine と同じ 1 本（`PlayerState` が非 null、かつ `MustSpectate()` が false）。`PostLogin` は join 済み controller をそのまま数える。
- 基底は `AGameModeBase` のままで、`AGameMode` への変更（`MatchState`/`NumPlayers` 減算経路を招く）はしていない。deferred 再計算（timer/tick/`PlayerArray` 後追い）も採らない。`Logout` の中で正しい値を 1 回 publish する。
- 回帰は 3 本。`Private/Tests/MulticaConnectedPlayerCountTests.cpp`（`Multica.Online.PlayerCount.Connected`）が join/leave・最後の 1 人が抜ける場合・spectator の離脱・`PlayerState` なしの controller を固定する。`scripts/Test-MulticaOnlinePlayerCountContract.ps1` は plugin の C++ を text として読み、`Logout` が `GetNumPlayers()`/`GetNumSpectators()` に戻っていないこと、`Exiting` を渡していること、減算ではなく除外であること、test が存在することを検査する（UE を起動しない）。`scripts/Test-MulticaOnlinePlayerCountContract.Tests.ps1` はその gate 自体を disposable な copy に旧形（`GetNumPlayers()` / `nullptr` / deferred recount / 減算 / test 削除）を注入して、rule 名つきで落ちることを assert する（gate が空にならないことの固定）。
- `templates/online/MulticaOnlineStarter/README.md:44` と `docs/08-online-foundations.md:24` を実装後の挙動へ合わせ、`MulticaOnlineStarter` を 1.0.1 から **1.0.2** へ上げ、`scripts/Test-UETemplateScaffold.ps1:216` の lock assertion を追随させた（assertion は削除していない）。`scripts/Test-UETemplateScaffold.ps1` には上の gate を 1 group として実行する行を足し（旧形の plugin ではこの group で落ちる）、`.github/workflows/verify.yml` の `scaffold` job には negative suite の step を 1 つ追加した（job 数は 2 のまま）。

移行: 既存の生成 project は再生成しない。`Plugins/MulticaOnlineStarter` を新 1.0.2 の内容へ差し替え（再生成する場合は新しい RunId で行う）と、`template-lock.json` の `plugins.MulticaOnlineStarter` が `1.0.2` になる。plugin 差し替えだけを行った場合、lock の値は古いままなので手で書き換えず、必要なら新 RunId で再生成して差分を確認する。

Unverified Scope: 本変更で UE 5.8.4 の起動 / compile / Editor build / PIE / 2-client Null/LAN / MRQ は **一切実行していない**。`Logout` 時点の engine 呼出順は、本 host の実 install にある engine source（`Controller.cpp:595-612`、`GameModeBase.cpp:179-188`）を read-only で参照したもので、plugin の compile 成否や実 2-client の人数減算を観測したものではない。上記の test も本 host では実行しておらず（UE 非起動のため）、`Multica.Online.PlayerCount.Connected` の合否は未観測。

## Unreleased — DOT-3395

## Unreleased — DOT-3395 — 2026-11-09

- 画像列QA helperは、`FramesDirectory`またはreport親pathにjunction/symlink等のreparse pointが含まれる場合に、実効出力境界を確認できないため検査前に拒否する。reportがjunction経由で画像列へ書き込まれるのを防ぐ回帰fixtureを追加した。
- `docs/05-qa.md`に、report先と検査対象はreparse pointを含まない通常のpathを使う契約を明記した。

## Unreleased — DOT-3295 — 2026-11-09

- `templates/online/MulticaOnlineStarter` had **no module implementation** (`IMPLEMENT_MODULE`). UE 5.8.4 loaded the DLL and then failed the plugin (`ロード後にモジュール 'MulticaOnlineStarter' の初期化に成功しなかったためプラグイン 'MulticaOnlineStarter' のロードに失敗しました`), so neither `Multica.Online.Session.DeferredDestroyCleanup` nor `Multica.Online.SessionIdentity` could register or run. Added `Private/MulticaOnlineStarter.cpp` using `FDefaultGameModuleImpl`.
- `MakeDestroyCleanupOperations` passed `const FDelegateHandle&` to `IOnlineSession::ClearOnDestroySessionCompleteDelegate_Handle`, which takes a non-const `FDelegateHandle&`; UE 5.8.4 rejects that with `error C2664`. The operation surface now takes the handle by value (`TFunction<void(FDelegateHandle)>`) and hands the provider a mutable copy; the test double matches it.
- The deferred-cleanup automation test bound its weak-lambda lifetime marker to `NewObject<UObject>()`. `UObject` is `UCLASS(Abstract)`, so that trips `Ensure condition failed: Class which was marked abstract was trying to be loaded in Outer /Engine/Transient` and fails the test. The marker now uses a concrete `UMulticaOnlineTestLifetimeMarker` declared in `Private/Tests/MulticaOnlineTestLifetimeMarker.h`.

Measured on this host (Windows, UE 5.8.4 CL 58902052, MSVC 14.44): `TP_FirstPersonEditor Win64 Development` `Result: Succeeded` (41 actions). `UnrealEditor-Cmd ... -ExecCmds="Automation RunTests Multica.Online"` → `Test Completed. Result={Success} Name={DeferredDestroyCleanup}` and `Result={Success} Name={SessionIdentity}`, `**** TEST COMPLETE. EXIT CODE: 0 ****`. `scripts/Test-UETemplateScaffold.ps1` 8 groups PASS / exit 0. PIE, two-client Null/LAN, and EOS/Steam were still not exercised.

## Unreleased — DOT-3254 — 2026-11-08

- `scripts/Test-UERenderArtifacts.ps1` の最終group（旧: `$finalCheck -notmatch 'frames-mutated'`）は恒真assertだった。`frames-mutated` はrepo全体にこのassert自身しか存在せず、fixtureにその名前のfileを作る処理も無かったため、fixtureを壊しても12/12 PASS・exit 0で通っていた。恒真assertを削除し、**実比較**に置き換えた。
- suiteが作るfixtureディレクトリは、構築直後に全file名・SHA256をbaselineとして登録する。末尾のgateは17ディレクトリすべてを再snapshotして比較し、追加・削除・内容変更をpathで名指しして落とす。`reports/`だけはsuiteが意図的に書くので比較対象から外し、代わりに「割り当てたreport path数 = 実在する非空`.json`数（意図的に拒否した分を除く）」を照合する。fixture root直下も既知entry以外を不正とする。
- **落ちる側のtest**を追加した（group 12）。使い捨てfixtureを「削除・書き換え・追加」の3通りで壊し、gateが3件ともpath付きで報告すること、復旧後は沈黙することをassertする。gate自体が空assertへ戻ればこのgroupが落ちる。
- suite末尾の「checkout unchanged」が ignored な残骸を見ていなかった。`.gitignore:2` の `Production/*` により `git status --porcelain --untracked-files=all` は `Production/` 配下を一切報告しないため、`Production/` に残ったfixtureやreportは検出されなかった。両suiteで `Production/` の実ディレクトリを直接列挙し、`PLACEHOLDER.md` の欠落と、そのsuite自身の命名（`.render-artifacts-test-*` / `.scaffold-test-*` と scaffold test出力名、過去runのものを含む）に一致する今回run以外のentryを残骸として落とすようにした（suite開始前とcleanup後とで2回確認する）。開発者が生成した `Production/<Name>_<runid>/` や他suiteの実行中entryではsuiteを止めない。
- 失敗時のcleanupも直した。assertで落ちてもfixture削除・残骸確認・checkout比較を必ず実行し、元のassert失敗を先に表示してから再throwする。
- `docs/05-qa.md` の「処理の前後でfixture/画像列のhashが変わらないことを確認する」を、実際に確認している主体（helperではなく回帰suite）と範囲（suiteが作った17のfixtureディレクトリ全体 + `reports/` + `Production/`）へ合わせた。

修正前後の実測（本host、`pwsh 7.6.9`、fixtureを3ディレクトリ壊す同一のmutationを注入）：修正前は `EXIT=0` / `PASS: 12行` で通過。修正後は `EXIT=1` で `ASSERT FAILED: fixture inputs changed during the suite: clean240/000000.png : removed; swap240/MUTATED.txt : added; corrupt/000001.png : content changed; STRAY-ROOT.txt: unexpected entry in the fixture root` とpathを名指しして落ちる。clean tree では 13 group PASS・exit 0（11の既存group + 新gate 2 group）、`scripts/Test-UETemplateScaffold.ps1` は 8 group PASS・exit 0。

移行: 既存projectと`Production/`の生成物には触れない。本変更はhelperを呼ぶ側のtest harnessと文書に閉じる。`Measure-UERenderArtifacts.ps1` の判定ロジック（decode/timeoutの優先順位・総予算）は変更していない。GitHub Actions `windows-latest` 上でのmutation検出は本変更のCI実行で確認する（本hostの実測ではない）。

## Unreleased — DOT-3366 — 2026-11-09

- `spectator-explore` scaffold now writes a stable `MulticaOnlineStarter.SessionProjectIdentifier` derived from `-ProjectName` and records it in `template-lock.json`. Null/LAN search joins only a session advertising that same identifier; missing or malformed settings fail explicitly instead of sharing the engine template name.
- The switch moved from the plugin's `Config/DefaultEngine.ini` to the **generated project's** `Config/DefaultEngine.ini`, together with `[OnlineSubsystem] DefaultPlatformService=Null`. Measured on UE 5.8.4 with `-dumpiniloads`: the engine does look for `<Project>/Plugins/MulticaOnlineStarter/Config/DefaultEngine.ini`, but engine and project branches already exist for that base name and take precedence, so the plugin copy was loaded into an ignored layer — `GConfig->GetString(TEXT("MulticaOnlineStarter"), TEXT("SessionProjectIdentifier"), ..., GEngineIni)` returned nothing and `Multica.Online.SessionIdentity` failed on "the generated plugin config is visible through the active engine config". Keeping the same values in the plugin directory is a silent no-op, so the plugin ships no `Config/` directory for them.
- Follow-up after merging `origin/main` into `verify/dot3366`: the merge resolution put the
  lock-vs-project-config assertion (`different project names produce different lock identifiers`)
  on the same physical line as the preceding assert, separated only by a tab. PowerShell parsed
  that line as a single `Assert-True` call with 6 arguments, and its `[bool]` parameter coerced
  the stray string, so the lock comparison never ran while the suite still reported 8 groups
  PASS / exit 0. The two calls are separate statements again, and a probe confirms the split
  assertion now fails when the lock identifier diverges. No assertion was added or removed.
- Added scaffold assertions for same-project stability across run IDs and distinct identifiers across project names, for the project-config placement, and for the absence of a plugin `Config/DefaultEngine.ini`; plus a UE automation test for matching/mismatching and missing/invalid session identifiers. The engine fixture in `Test-UETemplateScaffold.ps1` now ships `Config/DefaultEngine.ini` like the installed templates do. `MulticaOnlineStarter` advances from 1.0.0 to 1.0.1.

Measured on this host (Windows, UE 5.8.4 CL 58902052, MSVC 14.44): `TP_FirstPersonEditor Win64 Development` `Result: Succeeded` (41 actions). `UnrealEditor-Cmd ... -ExecCmds="Automation RunTests Multica.Online"` → `Test Completed. Result={Success} Name={DeferredDestroyCleanup}` and `Result={Success} Name={SessionIdentity}`, `**** TEST COMPLETE. EXIT CODE: 0 ****`. `scripts/Test-UETemplateScaffold.ps1` 8 groups PASS / exit 0.

Migration: regenerate projects that need project-scoped Null/LAN sessions with the same `-ProjectName` on every client and verify that the generated lock and project config agree. Existing generated projects lack the key and now report an explicit failure until regenerated/configured. This does not establish two-client runtime behavior: PIE, two-client Null/LAN, EOS/Steam, and permitted runtime checks are not exercised here.

## Unreleased — DOT-2997 — 2026-11-05

- エンコード前の画像列検査を追加。`scripts/Measure-UERenderArtifacts.ps1`が期待範囲（start/end-exclusive）と実ファイルの番号集合を照合し、欠番・範囲外・曖昧名・0 byte・decode不能・解像度不一致を検出する。読み取り専用で、既存画像の改名・修復・削除をしない。
- MRQ完了通知/exit、画像列、MP4、目視、音を独立した判定に分けた。通知成功やexit 0を画像列のpassへ、画像列のpassをrender/映像/音の合格へ読み替えない。
- decoderは既存環境の`ffprobe`を任意で使う。PATHに無ければ`-DecoderPath`で既存実体を指定し、無い・失敗・timeoutは`unverified`/`fail`のまま総合passにしない。新規導入はしない。timeoutは既定10秒、deadline超過は成功へ丸めない。
- `scripts/Test-UERenderArtifacts.ps1`で自作PNG fixtureの負例を固定。240枚そろっていても1枚欠番+末尾1枚超過の列をfailにすること、先頭/中間/末尾欠番、241枚目、桁数/拡張子の揺れ、0 byte、切り詰め・payload破損、解像度不一致、decoder不在/失敗/timeoutを確認する。
- 根拠：Epic公式Image Settings（frame offset/handle/frame step/終端排他を設定できる＝枚数だけで期待連番を決めない、2026-11-02参照）とFFmpeg公式（`-frames:v`は出力上限であり元画像列の整合性検査ではない）。いずれも当該hostの実測ではない。

移行: 新しいRunIdの`Out/run_<runid>/evidence/`へ検査reportを新規作成し、既存の作品・`Out`・画像列・MP4を上書きしない。旧runの画像列を対象にする場合は、所有権を照合してから新規出力先へreportだけを書く。UE実機のMRQ/ffprobe・render成功・映像/音/loopの実測は未検証（Unverified）。fixture成功はUE5.8.4動作確認ではない。

## Unreleased — third-person-game recipe — 2026-11-04

- 公式`TP_ThirdPerson`（C++・Combat/Platforming/SideScrolling variant同梱）を起点にする`third-person-game` recipeを追加。
- recipeの`materialize_project: true`で、テンプレート自身の`Config/TemplateDefs.ini`（FoldersToIgnore / FilesToIgnore / FolderRenames / ReplacementsInFiles / SharedContentPacks）を適用し、`<ProjectName>.uproject`・`Source/<ProjectName>`・`<PROJECTNAME>_API`へ実体化。共有content pack（Characters等）も`Content/`へ入れ、`/Script/TP_*`の`[CoreRedirects] +PackageRedirects`とProjectID/ProjectNameを書く。ウィザードとの一致は置換規則の適用範囲に限られ、改名クラスのclass redirectはこの時点では未実装（DOT-3156で追加）。
- 実体化するrecipeではProjectNameをC++識別子に制限。既存2 recipeの出力は変更なし。

移行: 既存projectは再生成しない。三人称の新作だけ`-Recipe third-person-game`で新RunIdから生成し、Editor build・Playは作品側QAで記録する。

## Unreleased — DOT-3041 — 2026-11-05

- project identity契約を1つに固定した。`materialize_project: true`のrecipe（`third-person-game`）は`<Name>.uproject` / `Modules[].Name = <Name>` / `Source/<Name>`、生コピーの2 recipeは`TP_FirstPerson.uproject` / `TP_BlankBP.uproject`のまま。どちらも`.uproject`の`Modules[].Name`と`Source/<Module>/<Module>.Build.cs`が一致していることを契約とする。`EngineAssociation`は`Build.version`から導いて必ず非空。`AGENTS.md:40`の`.uproject`記述、`docs/01-start.md`の「生コピー禁止」記述、starter README、`README.md`、`docs/07-architecture.md`を同じ契約へ揃えた。
- `scripts/New-UETemplateScaffold.ps1`はコピー前に`.uproject`の`Modules[].Name`と`Source/`のmodule directoryを照合し、既知パターンに一致しない場合は**停止**して未一致pathを列挙する。生コピーを黙って出力しない。コピー後にも同じ照合をコピー物同士で行う（materializeするrecipeはmodule rename後に照合）。`EngineAssociation`を明示設定し、project identityを`template-lock.json`の`identity`（`schema_version: 2`）に記録する。
- `scripts/Test-UETemplateScaffold.ps1`のfixtureは実在形式の`Modules`と`Source/**`を持つ。追加assertionはprojectファイル名、`Modules[].Name`、非空`engine_association`、lockの`identity`、および置換不能時にgeneratorが停止する負例。

### 移行（重要）

- **既存の生成済みprojectはrenameしない。** 旧generatorが出した`TP_FirstPerson.uproject` / `TP_BlankBP.uproject`は名前の点では新契約と同じで、違うのは空の`EngineAssociation`とlockのshapeだけ。renameはどちらも直さない。ファイル名だけ変えると`Modules[].Name`は`Source/**/[Module].Build.cs`を指したままになり、改名後のprojectは自分のlockが記録した`identity.project_file`と一致しなくなる。
- 新契約が必要な作品は**新しいRunIdで再生成**し、`template-lock.json`（`schema_version: 2`の`identity`）と作品差分を旧版と比較してから採用する。既存`Production/<Name>_<runid>/`と`Out/`を上書き・再生成しない。
- 旧lock（`schema_version: 1`）はidentityを持たないので、`identity`の有無で新旧を判別する。旧lockを手で書き換えない。
- `EngineAssociation`が空のまま生成済みのprojectは、Editorで開く前に`.uproject`の`EngineAssociation`を手で埋めるか、新RunIdで生成し直す。どちらを取ったかを案件のQAに記録する。
- UE compile / PIE / Editor / MRQ は引き続きUnverified Scope。本変更はgenerator・test・docsの共通基盤に限る。

## Unreleased — DOT-2959 — 2026-11-02

- 共通setを一つだけ使う鑑賞・探索（プレイ＋撮影）と、映像専用縦ループの2 recipeを追加。
- インストール済みUE公式project templateから新規projectを排他的に作るPowerShell generatorと、UE/plugin version・recipe/use・作品差分・template commitのlock記録を追加。
- Null/LAN用のserver-authoritative replication/session starter plugin、公式source付き方式比較、失敗/timeout手順を追加。

移行: template checkoutをcleanにし、新しいRunIdのscaffoldを生成する。`template-lock.json`と作品差分を比較してから手動で採用し、既存の生成project/Production/Outを再生成・上書きしない。EOS/Steamにはprovider固有実装、認証、service利用条件、実測を揃えるまで切替えない。

## Unreleased — DOT-3029 — 2026-11-05

- 生成物の project identity がリポジトリ自身の契約と一致していなかった不具合（PR#2、merge `a7bda3fd8396115d6e91570dba36b81c7bcbabbc`）。`AGENTS.md` は `<Name>.uproject` と書いていたのに generator は template 名の `<EngineTemplate>.uproject` を出し、`EngineAssociation` は空のままで、test fixture が `Modules: []` だったために全件 PASS していた。修正内容は `DOT-3041` の節（同一 PR）にまとめた。本節はその delivery が変更履歴に現れていなかったことの記録。
- 本件で増えた検査は、`Source/` を欠く identity で generator が停止すること、`EngineAssociation` が非空であること、lock の `identity` が実ファイルと一致することの 3 点。どれも以前は assert が無かった。

移行: 本文の `DOT-3041` 節と同じ。既存の生成済み project は rename せず、新契約が必要な作品は新 RunId で再生成する。

Unverified Scope: UE 5.8.4 の compile / PIE / Editor / MRQ は実行していない。fixture は合成 Engine で、実 UE install での生成ではない。

## Unreleased — UE-CI-002 — 2026-11-05

- リポジトリに CI が 1 本も無かった（`.github/workflows` は 404）ため、どの PR も success check を持たず merge gate に到達できなかった。`.github/workflows/verify.yml`（PR#4、merge `857b3264413f8992fda6149e1a2d3e3391c6762e`）を追加し、`windows-latest` で既存の 2 suite を回すようにした。
- `render-artifacts` job は decode=pass の assert に実 decoder が必要なので `choco install ffmpeg` で `ffprobe` を用意し、`scaffold` job は generator が自分の checkout を clone するため `fetch-depth: 1` のまま通ることを確認して入れた。
- 当時の記録では workflow は Actions 上で未実行だった。現在は main への push と各 PR で success を観測できる（本節の追記時点）。

移行: repo の中身は変わらず、PR の merge gate に check が付くだけ。既存の生成 project / `Production/` / `Out/` への影響なし。

Unverified Scope: 本 workflow が担保するのは PowerShell 2 suite の green だけ。UE compile / PIE / Editor / MRQ / render / ffprobe の意味での映像正しさは別判定のまま。

## Unreleased — DOT-3313 — 2026-11-08

- `spectator-explore` の生成物が `Recipe/Play.md` から `docs/08-online-foundations.md` を案内していたのに、生成 project にその文書を同梱していなかった（案内先が生成物内で解決しない）。generator が同梱するようにし、`Play.md` の参照先が解決すること、同梱コピーが repo の原本と一致することを `scripts/Test-UETemplateScaffold.ps1` で assert した（PR#7、merge `752864baf8383405729427595274d7e705538a9e`）。
- この suite が文書の存在を見るのは、この generator がコピーする 1 本だけ。他の `docs/*.md` と `templates/*.md` の存在は検査されていない。

移行: 生成済みの `spectator-explore` project には同梱文書が無い。同じ Name/RunId を上書きせず、新 RunId で生成し直すか、`docs/08-online-foundations.md` を生成物の `docs/` へ手で複製する（どちらを取ったかを案件の QA に記録する）。

Unverified Scope: UE 5.8.4 の起動 / compile / PIE / MRQ / render、二台 LAN の実接続は実行していない。文書同梱と参照解決だけの検査。

## Unreleased — DOT-3317 — 2026-11-08

- `docs/01-start.md` が「First Person C++ を全 recipe の前提」のように読ませていた。recipe ごとの起動経路（`spectator-explore`=`TP_FirstPerson`、`vertical-loop`=`TP_BlankBP`、`third-person-game`=`TP_ThirdPerson`）を表にし、用途・scaffold の identity（`materialize_project` の有無）・必須 plugin を並べ、Project Browser の手動作成を「script が使えない場合の fallback」へ下げた（PR#8、merge `5bd2e5815462a030e418c9a0f8674fef00c01389`）。
- 手動 fallback の生成物は recipe 文書・plugin payload・`template-lock.json` を欠くので、scaffold 生成物と同等と見なさないことを明記した。

移行: 読み方の変更だけで、生成物は変わらない。手動で作った既存 project を scaffold 生成物と同一視していた場合は、recipe / template / UE 版 / 確認した identity を `QA.md` に記録し直す。

Unverified Scope: 文書と recipe JSON / generator `ValidateSet` の静的照合だけ。UE 5.8.4 での生成・Editor build・PIE・LAN は実行していない。

## Unreleased — DOT-3340 — 2026-11-08

- `AGENTS.md` のセッション切断時復旧が、Computer Use 機能だけで画面操作を試みられる書き方になっていた。復旧を「Computer Use 機能」と「対象 host / project への既存の許可済み画面経路」の両方を確認できた場合に限定し、どちらかが欠ける場合は操作を試したと書かず、確認結果・不足・未実施操作と理由・保存版・次の許可済み手順を記録して停止するとした（PR#9、merge `34f2cbb61c8e43901325376ea7c69cb9555f9e32`）。

移行: 運用文書の変更のみ。新規認証・権限設定・代替接続・他 writer の終了は引き続き禁止で、既存 gate は変わらない。

Unverified Scope: 画面経路と Computer Use の両方が使える状況での復旧実操作は実行していない。本件以降の `DOT-3399` が同じ節を再度締め直している。
