# CREDITS（記入は利用許諾の代わりではない）

作品の `Content/` を持つ納品は、その asset 群の**出所**をこの表へ書く。未記入は Unverified であり、「素材を使用していない」という主張ではない。engine 同梱 content を同梱した作品は 1 行で済ませない。

## 記入契約（監査器が読む値）

- `出所区分 (origin)` は次の1つだけを書く: `engine-template`（Engine 同梱の公式 project template から複製）/ `shared-content-pack`（Engine 同梱の `Templates/TemplateResources` 共有 content pack から複製）/ `third-party`（Fab・Splice 等から取得）/ `original`（自作）。未記入は `未記入` と書き、空欄にしない。
- `同梱形態 (bundle)` は次の1つだけを書く: `repo-bundled`（template repo へ実体を同梱）/ `generated-only`（生成物の `Content/` にのみ存在し、repo へは入れない）。
- `素材名/ID` と `project内path` には、`Content/` 配下の**先頭ディレクトリ名**（例 `ThirdPerson` / `Characters` / `Input` / `LevelPrototyping`）を必ず含める。`scripts/Measure-UECreditsInventory.ps1` はこの名前で asset 群と照合する。`Content/` 直下に asset がある場合は、その group 名は `(content-root)` になる。
- Engine 同梱 content は、template 自身の `Content/` と共有 content pack の mount ごとに**別の行**で書く。複数の mount を 1 行にまとめない。
- 0 asset の作品（例 `vertical-loop`）だけが placeholder 行 1 行で済む。

| 素材名/ID | 出所区分 (origin) | 同梱形態 (bundle) | 作者 | 出典URL（署名なし） | license/確認日 | price/credit・承認参照 | 取得/採用/未使用 | 改変 | 配布範囲/表記義務 | project内path |
|---|---|---|---|---|---|---|---|---|---|---|
| 未記入（実素材なし・placeholderのみ） | 未記入 | 未記入 | 未記入 | 未記入 | 未記入 | 0（placeholderのみ） | 未記入 | 未記入 | 実素材の再配布を許可しない | 未記入 |

Fab/Mixamo/Splice等は価格0や既存所有でも素材単体再配布可とは限らない。UE同梱素材も適用条件を確認。NCS等の帰属表示は採用曲の現行条件と指定文言を確認。
候補と採用を混同しない。templateへ実物を含めない。第三者向け再配布/公開の判断は別gate。
Engine 同梱 content の再配布条件は Epic の template 機構文書に記載が無い（記載の不在であって許可でも禁止でもない）。記入は権利判断ではなく、出所の記録である。

## 記入例（`third-person-game` 相当。実物は入れず、生成物だけが持つ）

`Content/` の先頭ディレクトリごとに 1 行。`template-lock.json` の `shared_content_packs` が mount 名の正本になる。この例は code fence 内に置いてある（監査器は fence の中を記録として読まない）。

```markdown
| 素材名/ID | 出所区分 (origin) | 同梱形態 (bundle) | 作者 | 出典URL（署名なし） | license/確認日 | price/credit・承認参照 | 取得/採用/未使用 | 改変 | 配布範囲/表記義務 | project内path |
|---|---|---|---|---|---|---|---|---|---|---|
| TP_ThirdPerson template content | engine-template | generated-only | Epic Games | 未記入 | 未記入 | 0 | 採用 | なし | 再配布条件は未確認 | Content/ThirdPerson, Content/Variant_Combat, Content/Variant_Platforming, Content/Variant_SideScrolling, Content/__ExternalActors__, Content/__ExternalObjects__ |
| Characters pack（`TemplateResources/High/Characters`） | shared-content-pack | generated-only | Epic Games | 未記入 | 未記入 | 0 | 採用 | なし | 再配布条件は未確認 | Content/Characters |
| Input pack（`TemplateResources/High/Input`） | shared-content-pack | generated-only | Epic Games | 未記入 | 未記入 | 0 | 採用 | なし | 再配布条件は未確認 | Content/Input |
| LevelPrototyping pack（`TemplateResources/High/LevelPrototyping`） | shared-content-pack | generated-only | Epic Games | 未記入 | 未記入 | 0 | 採用 | なし | 再配布条件は未確認 | Content/LevelPrototyping |
```

`__ExternalActors__` / `__ExternalObjects__`（world partition の外部化 actor）は template 由来の行に含める。監査器はこれらも `Content/` の先頭ディレクトリとして1グループずつ数えるため、行に書かないと FAIL する（上の記入例はどちらも書いてある。例をそのまま複製しても通る）。

## 監査

```powershell
powershell -NoProfile -File scripts\Measure-UECreditsInventory.ps1 -Target Production\<Name>_<runid>
powershell -NoProfile -File scripts\Measure-UECreditsInventory.ps1 -Target Production\<Name>_<runid>\Out\run_<runid>
```

project root（`Content/` がある階層）でも納品 dir（`Out/run_<runid>/`）でも同じ結論になる。exit 0 = 通過 / 1 = 検出 / 2 = 入力不備。

- `Content/` の asset が 1 件以上あり、出所を述べた行が 1 件も無い → FAIL
- `Content/` の各先頭ディレクトリ名が、出所を述べた行に現れない → FAIL（group 名を名指しで報告）
- `Content/` が無い（0 asset）→ placeholder 1 行で PASS
- `Content/` または `CREDITS.md` が 2 つ以上解決できる、または `CREDITS.md` が 1 つも無い → exit 2（推測しない）
- 記録として読むのは code fence の外の表だけ。記入例・古い表を残す場合は fence で囲む（内側は記録として読まれない）

旧 9 列の表（`出所区分` 列が無い）は読み取れるが、engine 同梱 content を説明できないため FAIL。既存作品の CREDITS は書き換えを強制しないが、監査は通らない（Unverified のまま）。
