# 着手・新規生成・単一writer

## Preflightの完了条件

`templates/QA.md`に日時、Issue/run、hostname/OS、UE実version、GPU/VRAM、disk/RAM、既存toolchain、モデル指定/実効値、利用枠の観測範囲を記録。不明を0や無料と扱わない。
**checkoutと生成先の絶対パス長もPreflightの完了条件**。template repoのclone先と`Production/<ProjectName>_<runid>/`の絶対パス長を実測してQAへ書く（例: `C:\gh\ue5-agent-template` = 24文字）。generatorは生成前に予算検査を行い、既定260文字を超える計画なら停止する（下記[パス長の予算](#パス長の予算)）。UE buildの`Intermediate/`・`*.obj`はgeneratorの出力ではないため検査対象外で、build前に同じ予算を別途確認する。
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

### パス長の予算

`New-UETemplateScaffold.ps1`は、排他的mkdirの**前**に、これから書くtreeの最長絶対パスを計算して予算と比較する。既定は`-MaxPathLength 260`。

- 検査対象は (a) コピーするengine template配下（materializeするrecipeは変換後のpath）、(b) 共有content pack、(c) 同梱の`MulticaOnlineStarter` plugin一式、(d) generator自身が書く`Recipe/`・`docs/08-online-foundations.md`・`template-lock.json`。
- 超過時は**何も作らずに停止**する。エラーには最長pathの実値・相対path・超過分・現在のclone root長・収まるclone root長の目安・短くする具体案を含む。`Production/<ProjectName>_<runid>/`は作られない。
- 成功時は標準出力に`Path budget: longest planned path <N> characters, <M> characters of headroom under the <B>-character budget (<relative path>).`の1行を出し、QAへそのまま記録できる。
- 260の根拠は、このrepoが2026-11-01のEditor buildで**実際に260文字path制限へ当たり、checkoutを一時Q: driveへ割り当てた**記録（[docs/08-online-foundations.md](08-online-foundations.md)の実績表）と、Microsoft公式の`MAX_PATH`=260。Epic公式のBuild Configurationに`WindowsPlatform`の`MaxRootPathLength`/`MaxNestedPathLength`（"ensure paths are portable between machines"）があることも根拠の一部だが、**既定値と失敗時の挙動は公式資料から取得していない**。したがってこの予算は「Epicが260を要求している」という主張ではなく、repo自身が踏んだ閾値を既定にした宣言的な予算である。
- 予算を超える深さで作業する必要がある場合は`-MaxPathLength`を明示的に上げ、**なぜ上げたかと実測した最長pathをQAに残す**。既定を黙って緩めない。
- この検査は**generatorが書く範囲だけ**を見る。UE build以降に生える`Intermediate/Build/**`、`*.generated.h`、`Plugins/*/Intermediate/**/*.obj`はより深いため、build前にclone先と予算を別途確認する。実測は本repoの範囲外（Unverified）。

clone先の推奨は`C:\gh\ue5-agent-template`のような短いpath。実測（2026-11-12、`spectator-explore`／`EmberWatch` + 36文字のrun ID）では、clone root 85文字（生成先144文字）で最長260文字、clone root 86文字（145文字）で最長261文字となり、86文字以上では新しい予算検査が停止する。同じ入力で旧generatorはclone root 86文字でも成功扱いで261文字のtreeを書いた。

### 手動fallback：Project Browserを使う場合

scaffold scriptが使えない場合に限り、recipe表のEngine templateを選ぶ（`spectator-explore`=`TP_FirstPerson`、`vertical-loop`=`TP_BlankBP`、`third-person-game`=`TP_ThirdPerson`）。Recipeの用途に合わせた選択であり、First Person C++やgameplayは一律必須ではない。Starter Contentは不要なら無効にする。

Project BrowserはUE側のtemplate materialize規則でprojectを作るため、特に`vertical-loop`/`spectator-explore`では、scaffoldの`materialize_project: false`（template名を維持）と同じ出力にならない。手動生成物をscaffold生成物と同等と見なしたり、`.uproject`だけをrenameしたりしない。`.uproject`・`Modules[].Name`・`Source/**/[Module].Build.cs`が一致すること、`EngineAssociation`が非空であることを確認する。generatorが付与するrecipe文書・plugin payload・`template-lock.json`はProject Browserでは生成されないため、手動でlockを捏造・編集せず、選択recipe/template・UE版・確認したidentityを`QA.md`に記録する。必須pluginが利用可能でない、またはrecipeの記録物が必要な場合はscaffold生成物と同等と扱わず、通常経路が使えるまで停止する。RoomSevenをコピー元にしない。

### 生成後の制作確認

1. Editor targetをbuildし、新規projectだけを開く。必要な場合にPython Editor Script Plugin / Editor Scripting Utilities / Movie Render Queueを有効にし、自分のEditorだけ再起動する。
2. `/Game/<Name>/Maps/L_<Name>`を保存。Project SettingsでEditor Startup MapとGame Default Mapを指定し、package対象mapに含める。GameModeとPawn、camera、collision、入力設定は、Playが用途に含まれるrecipeで照合する。
3. 撮影smokeなら原作の床・cube・point light・camera・2秒sequenceのみ。ゲームsmokeなら歩ける小mapのみ。Fab/Splice不要で成立させる。

## leaseプロトコル（実装要件。スクリプト未同梱）

- 新project dirの排他的mkdirと、`LEASE.json` の排他的createを使う（PowerShell通常のNew-Item -Forceで代替しない）。
- leaseにはrun ID、issue ID、host、project realpath、取得日時、nonce、writer phase、当該runのPIDだけを保存。
- create競合なら停止。他runのactive有無とsource fingerprintが不明なら停止。時刻経過だけで奪わない。
- 再開は前leaseの解放receipt・保存済み版・active writerなしを照合し新nonceを取得。
- 解放前に実fileのrun/nonceを照合。自process終了・保存後、run別のLEASE_RELEASED記録へ移す。他人のleaseを消さない。
- crashの残leaseは手動照合対象。CLI/API上のrun終了だけではUE終了を推定しない。

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
