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
