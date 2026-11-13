# Windows ShippingとWindows主導Mac工程

## Windows

Editor target build成功だけでは配布実行版にならない。Shippingはbuild設定であり公開許可ではない。

1. 最終map/GameMode/inputを保存、asset/依存をCREDITSに固定。旧版の証拠を流用しない。CREDITSは`Content/`の**出所**を先頭ディレクトリ単位で説明する義務を持つ（engine同梱template由来と共有content pack由来を別行で書く）。記入契約と監査は`templates/CREDITS.md`。`docs/07-architecture.md:30`が要求するtemplate側の項目（`template_commit` / `recipe` / `engine_version` / `engine_changelist` / `shared_content_packs`）は`templates/DELIVERY.json`の追加fieldと`template-lock.json`へ書く。
2. Project Settings → PackagingでBuild Configuration=Shipping、Platforms → Windowsでも当該設定を確認。必要mapをcookへ含める。UAT helpと既存SDKを確認。
3. 以下はパラメータ化した例（このtemplateで未実行）。`$UAT/$Project/$Stage`は検証済み絶対path。stageは当該runの新規出力先で、Source/Content内に作らない。

```powershell
& $UAT BuildCookRun "-project=$Project" -noP4 -platform=Win64 -clientconfig=Shipping -build -cook -stage -pak -archive "-archivedirectory=$Stage" -utf8output
if ($LASTEXITCODE -ne 0) { throw 'BuildCookRun failed' }
```

4. staged exeだけでなく必要Pak/IoStore/依存一式とREADME/CREDITSを梱包。Development/Editor exeを誤納品しない。
5. 新規 `extracted-check/` へZIPを展開し、そこからexeを起動。UE/元sourceへの絶対path依存がないか確認。docs/05-qaの操作/実音/性能/5分検証を**この版**で行う。
6. ZIPを閉じてからSHA256を採る（PowerShell `Get-FileHash -Algorithm SHA256 <zip>`）。bytes/内部構成/UE/OS/GPU/ビルド設定/hashをDELIVERYへ。hash後にZIPを編集したら再計測。

## 記入と監査（UE不要・Windows PowerShell）

`templates/CREDITS.md`を`Out/run_<runid>/CREDITS.md`へ複製し、`Content/`の先頭ディレクトリごとに出所を1行ずつ書く。書いたら次を実行する。

```powershell
powershell -NoProfile -File scripts\Measure-UECreditsInventory.ps1 -Target Production\<Name>_<runid>
powershell -NoProfile -File scripts\Measure-UECreditsInventory.ps1 -Target Production\<Name>_<runid>\Out\run_<runid>
```

- exit 0 = 通過 / 1 = 検出 / 2 = 入力不備（`CREDITS.md`不在、`Content/`か`CREDITS.md`が2つ以上解決できる）
- `Content/`のassetが1件以上あり出所を述べた行が無い、または`Content/`の先頭ディレクトリ名が出所行に現れない → FAIL
- `Content/`が無い作品（`vertical-loop`）はplaceholder 1行でPASS
- project rootと納品dirのどちらを渡しても同一の結論になる（同じ組を解決するため）。片方だけで実行した記録は監査の証拠にしない

回帰は`scripts/Test-UECreditsInventory.ps1`（fixtureは自作のplaceholder bytes。engine同梱`.uasset`/`.umap`をrepoへ置かない）。

## Mac：Windowsから工程を進めるが、完成.appを推定しない

DOT-2936方針はWindows主導。Windowsでソース整理・依存調査・manifest・Mac手順の準備を先行する。Windows単独でC++/Apple SDK/Metalを含む.appの生成成功は未実証。
許可済みMac実行先・UE/Xcode/Metal/空き容量/所有権を照合できて初めて、remote/現地の実build/cook/stage/packageを進める。MacBook online化だけで能力合格にしない。miniへの代行・有料Mac CI・新認証は行わない。

Epic UE5.8公式表（2026-10-31参照）：Xcode最小26.0、推奨26.1.1、26.4は非互換。利用時に当該UE版の公式表を再確認する。
Mac用sourceは保存・lease解放済みcheckpointだけを使い、Config/Content/Source/必要Plugins/uproject/README/CREDITSを権利範囲内でZIP化。Binaries/Intermediate/DDC/Saved出力は除外。**source ZIPはMac実行版ではない**。
実.app完成後はarchitecture/OS/署名・公証状態、Metal上の見た目・操作・5分・音を実測。`ditto`等でsymlink/実行属性を保持し、別フォルダ展開から再起動。新証明書取得・Gatekeeper全体無効化なし。

公式：
- https://dev.epicgames.com/documentation/en-us/unreal-engine/packaging-your-project
- https://dev.epicgames.com/documentation/en-us/unreal-engine/macos-development-requirements-for-unreal-engine

仕様根拠と当該hostの成功証拠は別物。本テンプレートのUAT/Mac実行は未検証。
