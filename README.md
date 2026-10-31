# UE5 Agent Production Template

AIが短い映像または小さな鑑賞シーンを安全に作るための**文書・運用テンプレート**。
最初に [AGENTS.md](AGENTS.md)、次に [着手手順](docs/01-start.md) を読む。

## 現在の範囲

- UE5.8系の既存制作から手順を抽出。UE本体、Epic同梱C++/Content、Room Seven、Fab、Splice、Mixamo、NCSの素材実物は含まない。
- `.uproject`、既成マップ、実装済みゲーム、インストーラではない。許可Windowsで既存UEのFirst Person C++ウィザードから新規生成する。
- 文書内のコマンド例は実行先のpath/helpと照合してから使用する。本テンプレートからのUE build/render smokeは未実施。過去の制作成功と区別する。
- 追加インストール・課金・公開・Git pushは自動化しない。

## 入口

| 項目 | 読むもの |
|---|---|
| 新規制作・lease・ホスト | docs/01-start.md |
| Pi起動とeffort | docs/02-runtime.md |
| Fab/Splice | docs/03-assets.md |
| Windows Shipping / Mac工程 | docs/04-package.md |
| MP4 / 視覚・音声・Play検品 | docs/05-qa.md |
| 納品・Git公開 | docs/06-delivery.md |
| 実績と未確認点 | docs/PROVENANCE.md |

`templates/` の記録を新規制作の `Out/run_<runid>/` へ複製して記入する。
`Production/` は生成先の空プレースホルダ。通常Gitには制作物を入れない。

## bundleから開始（GitHub配置前の引渡し）

```text
git clone ue5-agent-template.bundle ue5-agent-template
cd ue5-agent-template
git status --short
```

GitHub URL・private/public・pushの許可は別に確定する。未作成URLを納品実績にしない。
