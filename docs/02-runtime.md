# Pi起動：保存値と実効値を分ける

## 過去案件限定の確定記録

DOT-2929とDOT-2935ではownerが例外指定したWindows Pi＋`@pi-plugins/claude-cli` 0.3.0を使用した。**新案件のClaude利用許可ではない**。今回のテンプレート作成にもこのモデルを新規起動しない。

```json
{
  "model": "claude-cli/claude-opus-5-5",
  "thinking_level": "xhigh",
  "custom_args": ["--no-extensions", "--no-session", "-e", "npm:@pi-plugins/claude-cli"]
}
```

期待argv：`--model claude-cli/claude-opus-5-5 --thinking xhigh --no-extensions --no-session -e npm:@pi-plugins/claude-cli`。
`--thinking`はMultica管理引数なのでcustom_argsへ保存不可。正式thinking_level欄を使用する。Windows global defaultThinkingLevel=maxを改変して取り繕わない。
実sessionでは `PI_PROVIDER=claude-cli / PI_MODEL=claude-opus-5-5 / PI_REASONING_LEVEL=xhigh / PI_CLAUDE_CLI_ALLOW_USAGE_CREDITS=0` を当該許可項目だけで確認した。

## 新規案件

現行ownerルールと実hostの認証済みcatalogから選ぶ。通常は既存Piの非Anthropic routeを使用し、未対応ならfallbackを勝手に行わない。
指定/保存値/argv/実session metadata/実応答/usageを別欄に記録。実効effort不明は未確認。古いtool結果中の警告文字列を現在の起動警告として誤検出しない。
authファイル、全環境変数、全process argv、全ログをdumpしない。新規認証・モデル課金・追加smokeは別許可。

## 実効値の観測

保存したeffortは、そのeffortで走った証拠ではない。Pi harnessは、modelが対応しないlevelを要求されると別levelへ置換し、保存するのは要求値、実行に使うのは置換後の値である（`@earendil-works/pi-ai` 1.5.0 / `pi-coding-agent` 1.5.0の同梱コードの静的な読取りによる）。

**観測する（モデルを呼ばない1コマンド）。** Piのbashツールはshellへ `PI_PROVIDER` / `PI_MODEL` / `PI_REASONING_LEVEL`（置換後の実効値）を注入する。当該Pi sessionのshellで次を1回実行し、出力を`templates/QA.md`の実効effort欄へ書く。

```text
node scripts/Get-PiEffectiveEffort.mjs --observe
```

出力は上記3変数だけ。`PI_SESSION_ID` / `PI_SESSION_FILE`は出さない。記録に残すかは任意で、残さなくてよい。Pi sessionの外では3変数が無く、`UNVERIFIED`（exit 2）になる。その場合は保存値を実効値欄へ転記せず、`不明`と書く。

**保存値と実効値が違えば、実効値を正本として記録する。** 保存値（`settings.json`の`defaultThinkingLevel`や起動時の指定）は「何を頼んだか」の記録であり、「何で走ったか」は実効値だけが言う。

**対応外levelは、より高いlevelへ置換されることがある。** 置換は下方向だけではない。要求levelがmodelの対応外なら、まず上方向へ最初の対応levelを探し、無ければ下方向へ探す。例: `max`に対応しないmodel（`anthropic/claude-opus-4-5`等）で`max`を要求すると`high`で走る（下方向）。`medium`を持たないmodel（`deepseek/deepseek-flash`等、対応は`off` / `low` / `high` / `max`）で`medium`を要求すると`high`で走る（上方向）。課金・所要時間は要求より増える方向になりうる。`reasoning`でないmodelは`off`だけになる。

**事前に確かめる（読み取り専用）。** 要求levelが実際にどう置換されるかは、実行前にcatalogだけで判定できる。

```text
node scripts/Get-PiEffectiveEffort.mjs --model <provider>/<id> --level <level>
```

exit 0は一致、1は置換される（出力の`effective=`が実効値）、2は`UNVERIFIED`（catalogが見つからない・読めない・modelが無い）。`UNVERIFIED`は合格ではない。catalogは`--catalog-dir`または環境変数`PI_AI_CATALOG_DIR`で指定でき、無指定ならグローバルinstallの`@earendil-works/pi-ai/dist/providers/data`を探す。API呼出し・認証・課金・`settings.json`の読取りは一切しない。判定規則は上記版の写しなので、版が変わったら実効値の観測（上のコマンド）を優先する。

検査: `node scripts/Test-PiEffectiveEffort.mjs`（fixture catalogだけを使い、置換の判定・`UNVERIFIED`の経路・この節と`templates/QA.md`の欄の存在を確かめる）。

