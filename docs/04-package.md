# Windows ShippingとWindows主導Mac工程

## Windows

Editor target build成功だけでは配布実行版にならない。Shippingはbuild設定であり公開許可ではない。

1. 最終map/GameMode/inputを保存、asset/依存をCREDITSに固定。旧版の証拠を流用しない。
2. Project Settings → PackagingでBuild Configuration=Shipping、Platforms → Windowsでも当該設定を確認。必要mapをcookへ含める。UAT helpと既存SDKを確認。
3. 以下はパラメータ化した例（このtemplateで未実行）。`$UAT/$Project/$Stage`は検証済み絶対path。stageは当該runの新規出力先で、Source/Content内に作らない。

```powershell
& $UAT BuildCookRun "-project=$Project" -noP4 -platform=Win64 -clientconfig=Shipping -build -cook -stage -pak -archive "-archivedirectory=$Stage" -utf8output
if ($LASTEXITCODE -ne 0) { throw 'BuildCookRun failed' }
```

4. staged exeだけでなく必要Pak/IoStore/依存一式とREADME/CREDITSを梱包。Development/Editor exeを誤納品しない。READMEは`Out/run_<runid>/README.md`として`templates/README.md`から記入し、起動方法と操作表を実機の値にする（雛形の場所・受領証の契約は`docs/06-delivery.md`）。
5. 新規 `extracted-check/` へZIPを展開し、そこからexeを起動。UE/元sourceへの絶対path依存がないか確認。docs/05-qaの操作/実音/性能/5分検証を**この版**で行う。
6. ZIPを閉じてからSHA256を採る（PowerShell `Get-FileHash -Algorithm SHA256 <zip>`）。bytes/内部構成/UE/OS/GPU/ビルド設定/hashをDELIVERYへ。hash後にZIPを編集したら再計測。

## Mac：Windowsから工程を進めるが、完成.appを推定しない

DOT-2936方針はWindows主導。Windowsでソース整理・依存調査・manifest・Mac手順の準備を先行する。Windows単独でC++/Apple SDK/Metalを含む.appの生成成功は未実証。
許可済みMac実行先・UE/Xcode/Metal/空き容量/所有権を照合できて初めて、remote/現地の実build/cook/stage/packageを進める。MacBook online化だけで能力合格にしない。miniへの代行・有料Mac CI・新認証は行わない。

Epic UE5.8公式表（2026-10-31参照）：Xcode最小26.0、推奨26.1.1、26.4は非互換。利用時に当該UE版の公式表を再確認する。
Mac用sourceは保存・lease解放済みcheckpointだけを使い、Config/Content/Source/必要Plugins/uproject/README/CREDITSを権利範囲内でZIP化。ここでのREADMEはprojectのREADMEであり、納品用の`Out/run_<runid>/README.md`（`templates/README.md`）とは別物。Binaries/Intermediate/DDC/Saved出力は除外。**source ZIPはMac実行版ではない**。
実.app完成後はarchitecture/OS/署名・公証状態、Metal上の見た目・操作・5分・音を実測。`ditto`等でsymlink/実行属性を保持し、別フォルダ展開から再起動。新証明書取得・Gatekeeper全体無効化なし。

公式：
- https://dev.epicgames.com/documentation/en-us/unreal-engine/packaging-your-project
- https://dev.epicgames.com/documentation/en-us/unreal-engine/macos-development-requirements-for-unreal-engine

仕様根拠と当該hostの成功証拠は別物。本テンプレートのUAT/Mac実行は未検証。
