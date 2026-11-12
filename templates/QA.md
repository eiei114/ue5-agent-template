# QA記録（新規run用。未記入はUnverified）

この表の行が受入項目の正本であり、`docs/05-qa.md`末尾の「合否・版/hash・実施者・日時・証拠・未確認をセットにする」は行が揃っていることを前提にする。行を削って「確認していない項目」を消すことはできない。

各行頭の`[QA-...]`は機械検査用の行IDで、`scripts/Test-UETemplateScaffold.ps1`が要求行の存在・重複・4択の値・online行の条件を検査する。行の削除やIDの付け替えはtestで落ちるため、受入項目を変えるときはtestと`docs/05-qa.md`も同じ変更で更新する。

値は`pass` / `fail` / `unverified` / `non-goal`の4択。未記入は`unverified`のまま残す。`non-goal`は仕様上の非対象にだけ書き、未実施・未検証を`non-goal`へ丸めない。

online/LAN行（`QA-NET-01`〜`QA-NET-09`）は`spectator-explore` recipeを使うrunだけが対象。それ以外のrecipeのrunは`non-goal`を記録する。`spectator-explore`のrunでも実接続を実施していなければ`unverified`のままとし、`non-goal`へ書き換えない。`templates/online/MulticaOnlineStarter/README.md`の2-client手順は、該当行が`pass`でも`non-goal`でもない間は未受入である。

Issue/run/日時/担当：
source commitまたはsnapshot SHA：
host/OS/UE/SDK/GPU/RAM/disk：
指定model/effort / 保存値 / 実session / 応答 / quota観測範囲：
writer/lease nonce・取得/解放receipt：

| 項目 | pass/fail/unverified/non-goal | 対象版/hash・実測・証拠 |
|---|---|---|
| [QA-BUILD-01] 新規project生成・Editor build | unverified | 生成したproject名・Editor buildのtargetと結果 |
| [QA-MAP-01] 初期map/camera・黒frameなし | unverified | 起動直後のmapとcamera、黒frameの有無 |
| [QA-PLAY-01] 起動map・Pawn・開始姿勢 | unverified | 起動したmap名・採用Pawn・開始時の姿勢。意図したmapで開始したことを確認 |
| [QA-PLAY-02] 座位/立位（仕様時） | unverified | 仕様に座位/立位がある場合のみ。仕様に無ければ`non-goal` |
| [QA-PLAY-03] 視点/移動/zoom/collision/reset/help/終了 | unverified | 項目別に記録 |
| [QA-PERF-01] 最新版5分Play・性能 | unverified | 解像度/品質/frame timeの平均/スパイク/観測方法と測定時間 |
| [QA-AUDIO-01] ゲーム実音の聴取 | unverified | |
| [QA-IMG-01] エンコード前の画像列検査 | unverified | `evidence/frames-check.json`。start/end(exclusive)/命名/期待解像度、欠番・範囲外・曖昧名・0 byte・decode・解像度の各判定 |
| [QA-MRQ-01] MRQ完了通知・exit code | unverified | 通知本文/exit。画像列検査とは別欄に記録 |
| [QA-MRQ-02] MRQ/ffprobe実測 | unverified | 幅/高さ/fps/frame数/秒数/codec/音声 |
| [QA-VISUAL-01] 先頭/中間/末尾目視・全編再生 | unverified | |
| [QA-VISUAL-02] 映像と音のloop継ぎ目 | unverified | |
| [QA-SHIP-01] Shipping成功・ZIP別展開起動/操作 | unverified | |
| [QA-MAC-01] Mac.app/architecture/署名/公証 | unverified | 必要な場合のみ |
| [QA-RIGHTS-01] CREDITS/権利・同一版manifest・SHA | unverified | |
| [QA-NET-01] hostがsessionを作成（`spectator-explore`使用時のみ対象。他は`non-goal`） | unverified | session名・map・listen状態・provider=Null。作成失敗も記録 |
| [QA-NET-02] 2人目clientがjoin（`spectator-explore`使用時のみ対象。他は`non-goal`） | unverified | join結果・join完了までの時間・client数 |
| [QA-NET-03] scoreのreplication（`spectator-explore`使用時のみ対象。他は`non-goal`） | unverified | server側と各client側の値。RPC送信元と受信時刻 |
| [QA-NET-04] player countのreplication（`spectator-explore`使用時のみ対象。他は`non-goal`） | unverified | 参加/離脱時に各clientが観測した人数 |
| [QA-NET-05] client leave（`spectator-explore`使用時のみ対象。他は`non-goal`） | unverified | `LeaveSession`後のhost側人数と離脱client状態 |
| [QA-NET-06] reconnect（`spectator-explore`使用時のみ対象。他は`non-goal`） | unverified | 再接続の成否・所要時間・同じsession identifierで再joinできたか |
| [QA-NET-07] failed search（`spectator-explore`使用時のみ対象。他は`non-goal`） | unverified | 0件検索・識別子不一致・拒否の通知内容。空検索を成功と扱わない |
| [QA-NET-08] timeoutの発生（`spectator-explore`使用時のみ対象。他は`non-goal`） | unverified | watchdog（60秒上限）超過の操作・通知・時刻。timeoutを接続成功と扱わない |
| [QA-NET-09] timeout後の後始末（`spectator-explore`使用時のみ対象。他は`non-goal`） | unverified | 遅延成功したcreate/joinのcleanup結果と、cleanup待ちの間operationを拒否した範囲。発生記録とは別行 |

## 画像列・通知・MP4・目視・音の独立判定

1項目のpassを他項目へ読み替えない。特に次を守る。

- 通知成功/exit 0があっても、画像列の負例（欠番・余分なframe・0 byte・decode不能・解像度不一致）をpassにしない。
- 画像列がpassでも、render成功・全編目視・音・loopを合格にしない。
- MP4のframe数だけでは、元画像列の欠番・余分を排除できない。
- 音声streamの存在は聴取ではない。
- 解像度や範囲を入力しなかった項目は`unverified`と書き、空欄のままpassにしない。

検査対象の画像列・run専用出力先・実施SHA・tool版を記録する。旧runの同数frame混入はこの検査だけでは判定できないため、run所有権の照合結果を別途残す。

## online/LANの独立判定

`QA-NET-*`の行も互いの代用にしない。host作成のpassはjoin・replication・leave・reconnectのpassではない。`QA-NET-08`（timeoutの発生）と`QA-NET-09`（timeout後の後始末）は別の主張で、片方のpassでもう片方を埋めない。Editor compileの成功、`scripts/Test-UETemplateScaffold.ps1`のPASS、pluginの自動test PASSは2-client接続の実測ではない。`docs/08-online-foundations.md`の「2-client接続probeはUnverified」という記録を、この表の行があるだけで変更しない。

残作業/次担当/再開条件：
run所有process終了・他人のprocess非干渉：
