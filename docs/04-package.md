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

4. staged exeだけでなく必要Pak/IoStore/依存一式とREADME/CREDITSを梱包。Development/Editor exeを誤納品しない。READMEは`Out/run_<runid>/README.md`として`templates/README.md`から記入し、起動方法と操作表を実機の値にする（雛形の場所・受領証の契約は`docs/06-delivery.md`）。
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
Mac用sourceは保存・lease解放済みcheckpointだけを使い、Config/Content/Source/必要Plugins/uproject/README/CREDITSを権利範囲内でZIP化。Binaries/Intermediate/DDC/Saved出力は除外。**source ZIPはMac実行版ではない**。


Epic UE5.8公式表（2026-10-31参照）：Xcode最小26.0、推奨26.1.1、26.4は非互換。利用時に当該UE版の公式表を再確認する。
Mac用sourceは保存・lease解放済みcheckpointだけを使い、Config/Content/Source/必要Plugins/uproject/README/CREDITSを権利範囲内でZIP化。ここでのREADMEはprojectのREADMEであり、納品用の`Out/run_<runid>/README.md`（`templates/README.md`）とは別物。Binaries/Intermediate/DDC/Saved出力は除外。**source ZIPはMac実行版ではない**。
実.app完成後はarchitecture/OS/署名・公証状態、Metal上の見た目・操作・5分・音を実測。`ditto`等でsymlink/実行属性を保持し、別フォルダ展開から再起動。新証明書取得・Gatekeeper全体無効化なし。

### UE 5.8 の Mac host 要件（独自要約）

Epicの[macOS開発要件](https://dev.epicgames.com/documentation/en-us/unreal-engine/macos-development-requirements-for-unreal-engine)のUE 5.8表から、hostの適格判定に必要な行だけを独自に要約する（表の転載ではない）。参照日は2026-11-05。

| 区分 | 最低 | 推奨 | 出典・参照日 |
|---|---|---|---|
| OS（Engine実行） | macOS Sonoma 14.5 | macOS Sequoia 15 | Epic 同ページ Version History 5.8行（2026-11-05） |
| プロセッサ | Apple Silicon M1/M2（描画機能により異なる） | Apple Silicon M3 | Epic 同ページ（2026-11-05） |
| メモリ | 16 GB | 32 GB | Epic 同ページ（2026-11-05） |
| GPU | Metal 1.2 互換 | — | Epic 同ページ（2026-11-05） |
| Xcode | 26.0 | 26.1.1 | Epic 同ページ（2026-11-05） |
| Xcode（非互換） | 26.4 | — | Epic 同ページ（2026-11-05） |

Epicの同ページは"Recommended Operating System"で`Latest macOS Sequoia 14`、Version Historyで`Sequoia 15`と書き、名前と数字が一致しない。どちらが正本かは決めない。本テンプレートは数字（15）を判定に使い、名前と数字の対応はAppleの対応表で確認する。

Epicの`Xcode 26.4 は Unreal Engine と互換でない`が単一buildを指すのか26.4系全体を指すのかは、公開文から確定できない。本テンプレートは26.4系（26.4.x）を範囲として非互換に扱い、確定できない旨をここに残す。

### Epicの2要件はAppleの対応表で両立しない

Appleの[Xcode 対応表](https://developer.apple.com/support/xcode/)（SDK and system requirements、参照日2026-11-05）では、Xcode 26 / 26.0.1 / 26.1 / 26.1.1 / 26.2 / 26.3 の対応OSは macOS Sequoia 15.6〜macOS Tahoe 26.x、Xcode 26.4.1以降は macOS Tahoe 26.2〜macOS Tahoe 26.xである。Xcode 16系はUEの最低26.0未満のためhost適格判定に使用しない。

この表とEpicの表を突き合わせると、Epicの「最低macOS = Sonoma 14.5」とEpicの「最低Xcode = 26.0」は同じhostでは成立しない（Xcode 26.0はAppleの表でmacOS 15.6以上を要求する）。どちらの表が誤記かは本テンプレートでは判定しない。

そのためhostの適格判定は**両表の交差**で行う。Epicの最低OS・プロセッサ・メモリ・Metalと、Appleの表が当該Xcodeに要求するOSの両方を満たすhostだけを`pass`とする。片方の表だけで`pass`にしない。判定は次の3値で、`pass`に丸めない。

- `fail`：観測値がいずれかの条件を下回る（例：macOS Ventura 13.5、Xcode 26.4系、メモリ16 GB未満、Metal 1.2非対応）
- `unverified`：判定に必要な観測値が無い、または公開表に当該版の記載が無い
- `pass`：全条件を満たす

判定toolは`scripts/Test-UEMacHostRequirements.ps1`（読み取り専用）。hostの事実は呼び出し側が渡し、toolは`sw_vers` / `xcodebuild`を自動実行しない。終了codeは`pass`=0、`fail`=1、`unverified`=2。

```powershell
.\scripts\Test-UEMacHostRequirements.ps1 -MacOSVersion '15.6' -XcodeVersion '26.1.1' -ProcessorFamily 'M3' -MemoryGB 32 -MetalSupported 'yes' -ReportPath 'Out/run_<runid>/evidence/mac-host.json'
```

判定結果は`templates/QA.md`のMac host行へ、観測値・判定・出典参照日とセットで記録する（`docs/05-qa.md`の記録契約）。Mac実機の`.app`生成・UAT・署名・公証は本節の判定とは別項目で、hostの`pass`をMac動作の証明に読み替えない。

公式：
- https://dev.epicgames.com/documentation/en-us/unreal-engine/packaging-your-project
- https://dev.epicgames.com/documentation/en-us/unreal-engine/macos-development-requirements-for-unreal-engine

仕様根拠と当該hostの成功証拠は別物。本テンプレートのUAT/Mac実行は未検証。
