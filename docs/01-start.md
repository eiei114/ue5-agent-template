# 着手・新規生成・単一writer

## Preflightの完了条件

`templates/QA.md`に日時、Issue/run、hostname/OS、UE実version、GPU/VRAM、disk/RAM、既存toolchain、モデル指定/実効値、利用枠の観測範囲を記録。不明を0や無料と扱わない。
Multicaのissue runs / runtime activity（先に各--help）と現地UE/renderプロセス・project leaseを確認。onlineはbuild可能の証拠ではない。
Windows offlineなら新規buildをqueueして成功扱いしない。MacBookは許可済みApple工程の候補、miniは軽い計画・文書確認のみ。

## 新規UE projectを作る（許可Windowsのみ）

通常はrecipeを選び、既存の`scripts/New-UETemplateScaffold.ps1`で生成する。Project Browserの手動作成は、scriptが使えない場合のfallbackであり、scaffoldと同じ生成物・identity規則になるとは限らない。First Person C++を全recipe共通の前提にしない。

### 通常経路：recipeを選んでscaffoldする

| Recipe | Engine template | 用途 | scaffoldのidentity | 必須plugin |
|---|---|---|---|---|
| `spectator-explore` | `TP_FirstPerson` | ゲーム＋撮影（探索・鑑賞） | `materialize_project`指定なし（false）。templateをコピーし、`.uproject`名とmodule名は`TP_FirstPerson`のまま | `MovieRenderPipeline`、`OnlineSubsystem`、`OnlineSubsystemNull`、`OnlineSubsystemUtils`、`MulticaOnlineStarter` |
| `vertical-loop` | `TP_BlankBP` | 撮影専用（capture-only）。gameplayを必須にしない | `materialize_project`指定なし（false）。templateをコピーし、`.uproject`名とmodule名は`TP_BlankBP`のまま | `MovieRenderPipeline` |
| `third-person-game` | `TP_ThirdPerson` | ゲーム＋撮影（三人称） | `materialize_project: true`。template規則を適用し、`.uproject`名・`Source`・moduleを`ProjectName`へ置換 | `MovieRenderPipeline` |

recipeの正本は各 [`recipe.json`](../templates/recipes/)、選択可能な値はgeneratorの`ValidateSet`。`third-person-game`は`ProjectName`をC++識別子（英字始まり、英数字と`_`のみ）にする。scaffoldの引数例：

```powershell
.\scripts\New-UETemplateScaffold.ps1 `
  -Recipe vertical-loop `
  -ProjectName AuraLoop `
  -RunId 11111111-1111-4111-8111-111111111111 `
  -EngineRoot 'C:\Program Files\Epic Games\UE_5.8'
```

例の`RunId`は形式を示す値なので、実行時には新しい一意のrun IDへ置き換える。

`-Recipe`には上表のいずれかを指定する。実行前に既存UEのversion/path、当該templateと必要なtoolchainを確認し、`Production/<ProjectName>_<runid>/`が未使用であることを確かめる。生成後は`template-lock.json`の`identity`と`.uproject`のplugin設定を照合してからEditorで開く。generatorはidentityの照合に失敗したら停止し、既存projectを上書きしない。実際のmap/Sequence/作品Contentは生成しない。

### 手動fallback：Project Browserを使う場合

scaffold scriptが使えない場合に限り、recipe表のEngine templateを選ぶ（`spectator-explore`=`TP_FirstPerson`、`vertical-loop`=`TP_BlankBP`、`third-person-game`=`TP_ThirdPerson`）。Recipeの用途に合わせた選択であり、First Person C++やgameplayは一律必須ではない。Starter Contentは不要なら無効にする。

Project BrowserはUE側のtemplate materialize規則でprojectを作るため、特に`vertical-loop`/`spectator-explore`では、scaffoldの`materialize_project: false`（template名を維持）と同じ出力にならない。手動生成物をscaffold生成物と同等と見なしたり、`.uproject`だけをrenameしたりしない。`.uproject`・`Modules[].Name`・`Source/**/[Module].Build.cs`が一致すること、`EngineAssociation`が非空であることを確認する。generatorが付与するrecipe文書・plugin payload・`template-lock.json`はProject Browserでは生成されないため、手動でlockを捏造・編集せず、選択recipe/template・UE版・確認したidentityを`QA.md`に記録する。必須pluginが利用可能でない、またはrecipeの記録物が必要な場合はscaffold生成物と同等と扱わず、通常経路が使えるまで停止する。RoomSevenをコピー元にしない。

### 生成後の制作確認

1. Editor targetをbuildし、新規projectだけを開く。必要な場合にPython Editor Script Plugin / Editor Scripting Utilities / Movie Render Queueを有効にし、自分のEditorだけ再起動する。
2. `/Game/<Name>/Maps/L_<Name>`を保存。Project SettingsでEditor Startup MapとGame Default Mapを指定し、package対象mapに含める。GameModeとPawn、camera、collision、入力設定は、Playが用途に含まれるrecipeで照合する。
3. 撮影smokeなら原作の床・cube・point light・camera・2秒sequenceのみ。ゲームsmokeなら歩ける小mapのみ。Fab/Splice不要で成立させる。

## leaseプロトコル（排他createは未同梱。子孫の帰属・回収は同梱script）

- 新project dirの排他的mkdirと、`LEASE.json` の排他的createを使う（PowerShell通常のNew-Item -Forceで代替しない）。
- leaseにはrun ID、issue ID、host、project realpath、取得日時、nonce、writer phase、当該runのPID`writer_pid`を保存する。この`writer_pid`は**残す**（互換のため消さない）。
- 同じleaseへ、run開始時に観測したプロセスsnapshotへの参照`process_snapshot`を追加する。参照は`path`（snapshot JSONの実path）、`sha256`、`captured_at_utc`、`writer_process_id`、`writer_creation_utc_ticks`、`root_process_ids`、`boundary_ancestor_process_ids`、`process_count`を持つ。snapshot本体は`path`が指す `Out/run_<runid>/evidence/process-snapshot.json` に置き、run別に1本だけ作る。
- leaseの`schema_version`は本節の列挙と一致させる。上記以外のfieldを勝手に足さない。追加するときは本節の列挙も同じ変更で更新する（DOT-3042の「列挙に厳密一致」制約を壊さない）。
- create競合なら停止。他runのactive有無とsource fingerprintが不明なら停止。時刻経過だけで奪わない。
- 再開は前leaseの解放receipt・保存済み版・active writerなしを照合し新nonceを取得。
- 解放前に実fileのrun/nonceを照合。自process終了・保存後、run別のLEASE_RELEASED記録へ移す。他人のleaseを消さない。
- crashの残leaseは手動照合対象。CLI/API上のrun終了だけではUE終了を推定しない。**`writer_pid`が死んでいることは、そのrunの子孫が終了した証明にならない**（PID生存だけを見てfreeと報告すると、子孫がprojectを掴んだまま次のrunが失敗する）。判定は下記の3値で行う。

### run所有プロセスの範囲

「自分のrun所有process」は**プロセスの名前ではなく、runが起動した木**で定義する。

所有に**含む**:

1. このrunのwriter自身（`writer_pid`とその`creation_utc_ticks`が一致するprocess）。
2. そのwriterが直接・間接に起動した子孫。build / Editor / cook / render / UBT（`UnrealBuildTool`） / `ShaderCompileWorker` / `UnrealPak` / `CrashReportClient` など、実行ファイル名を問わずsnapshotの親子鎖でwriterへ到達できるもの。深さは問わない。
3. run開始後にwriterが追加で起動したprocess。**同じrunのsnapshotに記録されているものだけ**を所有とみなす。記録の無いprocessは所有と断定せず、`unknown`として報告する（停止しない）。

所有に**含まない**（停止対象から明示的に除外する）:

1. writerの親（Multica runtime / Pi adapter / shell / 端末）。snapshotの`boundary_ancestor_process_ids`として記録し、runはこれを停止しない。run終了時の道連れはruntime側の責任で、このテンプレートは関与しない。
2. 共有Chrome（`chrome`等、`PreserveProcessNames`で維持する名前）。`AGENTS.md`の「共有Chromeは維持指示と所有権に従う」を優先する。
3. 他runのleaseがactiveなprocess（そのleaseのsnapshotから導いた木）。
4. `Production/<Name>_<runid>/` の外で動く、runが起動していない常駐tool（エディタ、ブラウザ、Slack等）。

**所有の範囲を名前で判定しない。** `AGENTS.md`の名前指定kill禁止を維持し、停止は常に `(process_id, creation_utc_ticks)` の同一性で行う。

### snapshot・回収・判定のscript

| script | 役割 | UE起動 |
|---|---|---|
| `scripts/Start-UETemplateRunProcessSnapshot.ps1` | run開始時にwriterとプロセス表を1回観測し、`process-snapshot.json`を作り、`-LeasePath`指定時は lease に`process_snapshot`を追記する（既存fieldは不変を照合、変われば停止） | しない |
| `scripts/Stop-UETemplateRunProcesses.ps1` | `-WhatIf`相当のdry-runで**停止対象一覧を先に出力・保存**し、`-Execute`で一覧のidentityだけを停止する。`-Execute`は同じsnapshotのdry-run planが無ければ**拒否**する | しない |
| `scripts/Test-UETemplateLease.ps1` | leaseを`free` / `held` / `unknown`の3値で判定する。`unknown`は`free`へ丸めない | しない |

- 回帰は`scripts/Test-UETemplateProcessOwnership.ps1`。自作fixture（writer→子→孫）で負例を固定し、UEを使わない。
- 帰属不明（snapshotに無いprocess、`creation_utc_ticks`が読めないprocess、writerのidentity不一致、snapshotのhash/run/writer不一致）は**停止しない**。dry-run・実行後の検証とも`unknown`を返し、`free`と言わない。
- PIDを再利用した別process（`creation_utc_ticks`がsnapshotと不一致）は停止対象から外す。
- 回収結果は`templates/QA.md`の当該行へ、停止対象件数・停止件数・残存件数・残存の帰属不明件数・判定の5つで記録する。空欄のまま納品しない。

### 制約（job objectに依存しない）

job objectは回収の唯一の根拠にしない。Microsoftの仕様（[Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects)、2026-11-05参照）では、jobに属したprocessの子は既定でjobへ継承されるが、**`Win32_Process.Create`経由で作られた子は継承されない**。したがってjob単独では木を閉じられない。本テンプレートの帰属は**snapshotの親子鎖**で行い、job objectの採用は必須条件にしない。

## 最小smokeの証拠

clone commit → preflight → lease → project生成 → Editor build → Playで床/cube/camera表示 → MRQ 2秒 → ffprobeと目視 → optional Shipping → 解放。
各工程はpass/fail/unverified、exit code、実ファイルhashで記録する。文書リンク点検だけをUE smokeと呼ばない。

## 切断からの復旧・続行（既存制作にも適用）

1. CLI/APIに切断やofflineが出ても即終了しない。時刻・対象host/project/run・最後の保存版と工程を確認し、active/queued・lease・現地processを可能な経路で照合する。不明なら書込みや再起動より先に画面を観察する。
2. 利用可能なコンピュータユーズで、既存の許可済みリモート接続先または対象hostの画面を取得する。接続先名を確認し、接続中・ログオン画面・切断エラー・Editor継続中等を区別。観測していないボタン・PID・接続先を推測しない。
3. 表示済みの通常の再接続操作、ウィンドウ再選択、対象アプリへのフォーカス復帰を行う。操作ごとに画面を再取得し、復帰したことを確認する。security警告回避・新権限・新認証等は既存gateを越えない。
4. 同じwriterが動いていれば引き継ぎを待たずその既存工程を尊重し、別UE/buildを起動しない。既存writer終了・保存版・leaseの安全な解放を確認できた場合のみ、既存の再開規約で継続する。古いleaseを時刻だけで削除しない。
5. 未保存復旧ダイアログは対象と保存済み版を照合し、原本を破棄・上書きせず回復内容を確認する。保存版と編集中状態の差が不明なら破壊操作を避け、具体的な不足を残す。
6. 復帰後は該当工程を小さく検証（Editor表示/Play、build結果、MRQ出力等）して制作を続行。黒画面やprocess生存だけを合格としない。元runが終了済みなら背景に作業を置かず、Multicaの既存所有権・実行経路を通す。
7. 解消できなければ、画面/エラー・操作と結果・保存版/lease・続行できない具体的理由・次の実行者/操作をQAへ記録する。画面経路が無い場合もその照合結果を残す。「セッション切断＝報告待ち」には戻さない。新しい証拠なしで同操作を反復しない。

この文書は復旧方針であり、自動再接続scriptや監視jobの実装ではない。画面接続や実機復旧は案件ごとに検証する。
