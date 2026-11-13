# アセット取得：実行物と権利を分離

これは2026-10-30の制作hostでの所在記録。新hostで存在とhelpを確認し、pathを推定して実行しない。第三者コードや既存scriptも読む前提で安全性を確認する。

| Tool | 過去の実体 | 運用mapの所在（限定読取のみ） |
|---|---|---|
| fab | `~/tools/fabcli/fab.mjs`、shim `~/bin/fab` / `fab.cmd` | `RoomSeven/.pi/skills/r7-fab-assets/references/fab-cli-map.md` |
| spliceclaw 0.1.0 | `~/.cargo/bin/spliceclaw.exe` | `RoomSeven/.pi/skills/r7-splice-se/references/spliceclaw-map.md` |

RoomSeven内にあるのは主に使い方。素材や認証profileをテンプレートにコピーしない。fab.cmd不調の過去例があるため実体のnode呼出を確認する。

## CDP / Fab

1. 当該hostの既存許可済みChrome専用profileとCDP `127.0.0.1:9223` を確認。普段のChromeが開いているだけでは足りない。
2. 過去の既存起動scriptは `~/.config/spliceclaw/open-splice-login.sh`、profileは `~/.config/spliceclaw/chrome-profile`。存在・内容・所有権を確認し、必要な既存許可がある場合のみ起動する。新profile作成、cookie export、外部CDP公開はしない。
3. `node <fab.mjsの実path> status` → `search <語> --free` → `show <uid>`。FREE一覧ではなく詳細license/price=0を照合。
4. 利用・claim権限と納品権利を確認してから、helpで対応形式を確認し `download <uid> --format fbx --out <自分のArt dir>`。UE専用形式がCLIで取れない場合は失敗を記録、購入や別経路へ勝手に迂回しない。
5. browserを開いたまま維持する指示がある場合は閉じない。共有サービスのlifecycleを自runと混同しない。

## Splice認証同期

過去にはFirefox session_missingが出たが、既存9223 Chrome経由で解消した。

1. 同じhost・ownerの上記既存Chromeを確認。
2. 許可されたtool mapで **`sync-credentials.mjs` の実pathと引数を確認**。記録にはbasenameしかなく、正確なpath/構文は本テンプレートで未確定。見つからない場合はここだけblocked。推定コマンド、別hostの資格情報コピーは禁止。
3. 既存同期手順をローカルで実行し、秘密値を表示せず `spliceclaw auth status --live` がokか確認。
4. `spliceclaw search --help`を確認し `search --live` で候補調査。license済み/未取得/採用を分けてCREDITSへ記録。
5. 未所有downloadの`--confirm`はcredit消費ゲート。対象ID・件数・上限の新しいowner許可なしに実行しない。旧焚き火2credit許可は別作品へ持ち越さない。

preview/searchで消費しなかった過去記録は将来の無料保証ではない。現行helpと取引表示を優先。署名URLやsync結果の秘密はログに残さない。原本URLによる迂回取得を既定化しない。

## templateへ入れないもの

Fab/Splice/Mixamo/NCS/UE同梱素材の原本・派生uasset・cache・ダウンロードZIP。価格0でも再配布可とは限らない。必要素材は各利用者の許可済み経路で取得し、templateには用途を示すtext placeholderだけを置く。CREDITSの記入は権利許諾の代わりではない。

### UE同梱素材（engine template / shared content pack）の条件

UE同梱 contentはrepoへ入れず、生成物の`Content/`にだけ置き、出所をCREDITSへ書く。`materialize_project`のrecipe（`third-person-game`）は`Templates/<template>`と`Templates/TemplateResources/<DetailLevel>/<MountName>`から複製するので、生成物の`Content/`には数百件の`.uasset`/`.umap`が入る（実測: `TP_ThirdPerson` 587 + `Characters` 128 + `Input` 9 + `LevelPrototyping` 29 = 753）。

1. `templates/CREDITS.md`を`Out/run_<runid>/`へ複製し、`Content/`の**先頭ディレクトリごと**に1行書く。template自身のContentは`engine-template`、共有packのmountは`shared-content-pack`で、別行（`同梱形態`は`generated-only`）。
2. mount名とdetail levelは推測しない。`template-lock.json`の`shared_content_packs`（実際に展開したmount名の配列）と`shared_content_pack_detail_levels`（mount → 実展開元level）を正本にして転記する。
3. 書いたら`scripts/Measure-UECreditsInventory.ps1`で監査する（`docs/04-package.md`の「記入と監査」）。project rootと納品dirの両方から実行し、同じ結論になることを確認する。
4. **再配布可否の判断はこの記録の対象外**。Epicのtemplate機構文書はengine同梱contentの再配布条件を述べておらず、これは記載の不在であって許可でも禁止でもない。公開・第三者配布は別gate。
5. `.uasset`/`.umap`をfixtureとしてrepoへ置かない（回帰も自作のplaceholder bytesで行う）。
