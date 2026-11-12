# 制作エージェント契約

## 先に読む

README → docs/01-start → 対象工程のdocs。現行Issue・owner指示・ホストの既存AGENTSも読み、矛盾を隠さない。文書は権限付与ではない。

## 最短ループ

1. Issueの納品種別（映像/実行版/ソース）と非目標、既存writerを確認。
2. online Windows Pi優先。OS/GPU/空き容量/既存UE/SDK/モデル・effort/利用枠/active runsを現地照合。Mac miniでbuild/render/downloadしない。
3. run台帳 `Production/.runs/run_<runid>/` を排他的mkdirし、preflight（`templates/QA.md`を複製した`preflight.md`）と`LEASE.json`（CreateNew相当）をその中へ書く。**生成先 `Production/<Name>_<runid>/` はlease工程で作らない**（ここを先に作ると手順4の生成が停止する）。生成先が未使用であることだけを確認する。
4. 最初は追加素材なしの立方体・床・光・カメラ。小さいpreview→目視→調整→本番。UEテンプレートは当該hostの正規既存インストールから生成。
5. 映像はフレーム・全編・継ぎ目・音を検査。実行版はShipping梱包後、別フォルダ展開から起動・操作・5分測定。
6. CREDITS / QA / manifest / SHAを**同じ最終版**へ固定して納品。見た目未検品や旧版ZIPは完成でない。
7. 自分のrun所有processを同期回収し、自分のleaseだけ解放。共有Chromeは維持指示と所有権に従い触らない。

## セッション切断時も復旧・続行する

制作中にセッション（エージェント／リモート接続等）が切断されても、切断だけで停止・報告待ちにせず、まず既存の許可済み経路で状態と続行可否を照合する。画面復旧は、**Computer Use機能が利用可能で、対象host/projectへの既存の許可済み画面経路を確認できる場合に限る**。いずれかを利用できない場合は接続先や機能を推測せず、画面操作を試みたと記載しない。新規認証・権限設定・代替接続を作らず、照合結果と具体的な不足、観察できた範囲、未実施操作と理由、保存版、次の既存の許可済み手順を記録して復旧操作を停止する。具体的な復旧手順の正本は `docs/01-start.md`。切断自体はprocess終了の証明にならない。現在進行中のUE5制作にも適用する。

- まず対象host・project・run・単一writer leaseと、既存build/render/Editorの生存・保存状態を照合。接続断をprocess終了とみなさず、別writerや同じbuildを重複起動しない。
- Computer Use機能と既存の許可済み画面経路の両方を確認できる場合に限り、その経路で画面を取得し、切断表示を観察して再接続、対象アプリの再選択・フォーカス復帰などを実操作する。操作後は新しい画面を確認し、同じ保存版の工程から続行する。具体的な手順は `docs/01-start.md` を参照する。どちらかを利用できない／確認できない場合は、画面操作や代替接続を試さず、確認結果と不足を記録して復旧操作を停止する。
- 費用・権限・認証・公開・破壊の既存gateは維持。復旧の名目で購入、新規認証、security設定変更、他writerの終了やlease強奪をしない。使用不能なhostの代わりにMac miniで重い工程を実行しない。
- Computer Use機能/画面経路の不在・host電源断・権限不足等が残る場合は「切断した」だけでなく、機能・経路の確認結果、観察できた範囲、実施した操作（なければ未実施とその理由）、保存版、残る具体的不足と次の許可済み復旧手順を記録。試行済みと復旧成功を区別し、無限retryや重複runを作らない。

## 禁止・ゲート

- RoomSevenの稼働writer/Content/素材/Audio/downloadsに接触・複製しない。運用知識は本書に抽出済み。必要な既存tool mapの限定読取はそのhostで許可がある場合だけ。
- 新Claude/Anthropic割当は既定禁止。docs/02-runtimeのOpus例は過去案件固有の許可記録であり、汎用テンプレートの既定モデルにしない。
- 購入、credit消費、追加API billing、新認証・資格情報移送、GitHub作成/push/public/SNS/配布はそれぞれの現行許可を確認。既存案件の2credit許可を再利用しない。
- secrets、cookie、token、署名URL、auth.json、環境変数全体、生transcriptを読取/出力/commitしない。
- 既存writerへ割込まない。名前指定kill、leaseの時刻だけでの強制解除、他人のdirty差分のstash/restore/削除は禁止。
- run終了後に残すbuild/renderは不可。完了・安全停止を当該turn内で回収。
- `completed` は成果完成でない。未検証はUnverified、owner受入前はDoneにしない。

## フォルダ

```text
Production/
  .runs/run_<runid>/        # 生成前の台帳。Git外。生成先projectの外にある
    preflight.md           # templates/QA.md の複製。生成後はproject内のQA.mdへ移す
    LEASE.json             # active所有者のみ。CreateNew相当。Git外
  <Name>_<runid>/          # generatorが排他的mkdirする生成先。手順3で先に作らない
    <ProjectFile>.uproject / Config/ / Content/ / Source/ [Plugins/]   # materialize_projectなら<Name>、それ以外は<EngineTemplate>
    Art/                 # 許可済み取得物。Gitテンプレートへ入れない
    Tools/               # 当該project用。秘密なし
    Out/run_<runid>/
      preview/ frames/ final/ staging/ extracted-check/ evidence/
      QA.md CREDITS.md DELIVERY.json SHA256SUMS.txt
```

preflightとleaseの記録先は`Production/.runs/run_<runid>/`のみ。生成先`Production/<Name>_<runid>/`の内側（`Out/`・`LEASE.json`）に先行して書くと、generatorの排他的mkdirが既存扱いで停止する。生成後にpreflightの内容は`Out/run_<runid>/QA.md`へ移し、leaseの解放記録も台帳dirに残す。

project identityの契約は1つだけ。`scripts/New-UETemplateScaffold.ps1`はインストール済みUE公式templateから生成し、**projectファイル名・`Modules[].Name`・`Source/<Module>`は常に互いに一致**していなければならない。`EngineAssociation`は`Engine/Build/Build.version`から導いた値（例`5.8`）を必ず書き込む。

- `materialize_project: true`のrecipe（`third-person-game`）は、template自身の`Config/TemplateDefs.ini`をUEウィザードと同じ規則で適用するため、`<Name>.uproject` / `Source/<Name>` / `Modules[].Name = <Name>`になる。
- それ以外のrecipe（`spectator-explore` / `vertical-loop`）は生コピーするため、template名（`TP_FirstPerson` / `TP_BlankBP`）がそのまま残る。ここで`.uproject`だけrenameすると`Source/**/*.Build.cs`と食い違う。

generatorはコピー前にdescriptorと`Source/`を照合し、既知パターンに一致しなければ**推測で続行せず停止**して未一致pathを列挙する。コピー後にもコピー物同士で同じ照合を行い、食い違えばdescriptorを書き換えずに停止する。生成後に`.uproject`を手でrenameしない。identityは`template-lock.json`の`identity`（`project_file` / `project_modules` / `engine_association`、`schema_version: 2`）に記録され、そこで確認できる。

旧版は上書きしない。Out/_v1のような旧運用よりrun別の分離を推奨。Outに置いただけで納品とは呼ばない。
