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
