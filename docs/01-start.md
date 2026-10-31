# 着手・新規生成・単一writer

## Preflightの完了条件

`templates/QA.md`に日時、Issue/run、hostname/OS、UE実version、GPU/VRAM、disk/RAM、既存toolchain、モデル指定/実効値、利用枠の観測範囲を記録。不明を0や無料と扱わない。
Multicaのissue runs / runtime activity（先に各--help）と現地UE/renderプロセス・project leaseを確認。onlineはbuild可能の証拠ではない。
Windows offlineなら新規buildをqueueして成功扱いしない。MacBookは許可済みApple工程の候補、miniは軽い計画・文書確認のみ。

## 新規UE projectを作る（許可Windowsのみ）

1. 正規既存UEのversion/pathとFirst Person C++テンプレートの存在、C++ toolchainを確認。過去実績はUE5.8.4の `Templates/TP_FirstPerson` 系、Variant_Horror系譜。
2. 一意なproject parentを原子的作成する。例 `Production/Smoke_<full-runid>/`。UEウィザードが非空dirを拒否する場合は、その配下の新規project dirへ生成し、実際の構造を記録（上書きしない）。
3. UE Project BrowserでGames → First Person → C++、当該版で利用できるvariantを選び、Starter Contentは不要なら無効。project名は空白・記号なしにする。
4. 既存UE同梱templateの生コピーは推奨しない。Source/Target/module名等の置換漏れを避けるためウィザードを優先。RoomSevenをコピー元にしない。
5. Editor targetをbuildし、新規projectだけを開く。必要な場合にPython Editor Script Plugin / Editor Scripting Utilities / Movie Render Queueを有効にし、自分のEditorだけ再起動する。
6. `/Game/<Name>/Maps/L_<Name>` を保存。Project SettingsでEditor Startup MapとGame Default Mapを指定。Package対象mapに含める。GameModeとPawn、camera、collision、入力設定をPlayで照合。
7. 映像smokeなら原作の床・cube・point light・camera・2秒sequenceのみ。実行版なら歩ける小mapのみ。Fab/Splice不要で成立させる。

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
