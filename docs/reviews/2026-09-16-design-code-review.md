# 設計・コードレビューと修正プラン

- レビュー日: 2026-09-16
- レビューモデル: GPT-6 Astra (`gpt-6-astra`)
- 対象: `fa13591`、バージョン 0.1.5
- 範囲: Swiftの全ターゲット、既存テスト、インストーラースクリプト、配布スクリプト、Cask/Formula、READMEとリリース文書。
- 本書は修正前のレビュー記録。レビュー段階ではコード変更・サービス操作・実機のShortcuts実行・システム終了・パッケージのインストールは行っていない。その後の修正は[0.1.6](../releases/0.1.6.md)を参照。

## 総合評価

CLI、Core、AppKitエージェントという責務分割は妥当であり、全面的な再設計は不要。Home/Matterの制御をShortcutsに委譲し、macOSイベントをポーリングではなく通知で受ける構成も維持してよい。

一方、正常系をつなぐ実装に対して、異常系と複数の操作経路を統制する設計が不足している。特に「設定が読めなかった」「子プロセスが終わらない」「終了前の操作が失敗した」「別経路の操作が同時に走った」を、成功・未設定・通常イベントと区別する必要がある。

**P1が4件、P2が7件、P3が1件。P1を先に修正することを推奨する。** 現状では、READMEの「確実な消灯」の説明に見合う失敗時の制御がない。修正後も、Shortcutの成功と実際の機器状態の保証は区別して説明する必要がある。

- P1: 設定喪失、処理停止、終了前操作の信頼性に直接影響する。
- P2: 特定の設定・操作・配布環境で機能が成立しない。
- P3: 開発・リリース作業の誤操作を誘発する。

## 指摘事項

### R1 / P1: stdout・stderrを読み始める前に子プロセス終了を待つため、デッドロックする

**箇所:** [ProcessRunner.swift:39–43](../../Sources/VirtConnectorCore/ProcessRunner.swift#L39)

`waitUntilExit()`の後で両パイプを読む。子プロセスがパイプ容量を超える出力を行うと、子は書き込み待ち、親は子の終了待ちとなり、双方が進まない。共有ランナーなので、Shortcut実行・一覧取得・launchctlなどに影響する。通常の対話待ちや終了しない子プロセスに対する期限もない。

**根拠:** 実際のCoreソースを使った隔離プローブで、少量出力は完了した一方、stdoutだけ、stderrだけにそれぞれ1 MiBを出力する子プロセスは、どちらも3秒の監視期限まで完了しなかった。監視側でプローブとその子プロセスだけを終了した。

**修正:** stdoutとstderrを実行中に並行して読み取り、終了と読み取り完了を両方待つ。実行期限・キャンセル・終了回収を設計し、タイムアウトを明示的なエラーとして返す。片方ずつ同期的に読むだけでは解消しない。

### R2 / P1: 設定読み込みエラーを空の設定に置き換え、更新コマンドで元の設定を失う

**箇所:** [ConfigStore.swift:41–47](../../Sources/VirtConnectorCore/ConfigStore.swift#L41)、[CLI/main.swift:107–112](../../Sources/VirtConnectorCLI/main.swift#L107)。`setup`・`device add`などにも同じ経路がある。

`loadOrDefault()`が不存在・アクセスエラー・JSON破損・スキーマ不一致をすべて握りつぶす。更新コマンドは、その空の設定を元ファイルへ保存する。読み取り専用のコマンドやdaemonでは、異常が「有効・デバイス0件」に見える。

**根拠:** 隔離した設定に、デバイス情報はあるが必須フィールドが不足するJSONを置いて実際のCLIで`disable`を実行すると、終了コード0で`{"enabled":false,"devices":[]}`相当へ上書きされた。

**修正:** 不存在と読み込み失敗を区別する。初期作成が許されるコマンドだけが明示的に初期値を作る。既存ファイルを読めない場合、更新は中止してファイルを保持する。daemonは読み込み失敗を記録し、そのイベントの操作を実行しない。

### R3 / P1: Shortcut失敗を終了処理の失敗として扱わず、そのままmacOSを終了させる

**箇所:** [ActionExecutor.swift:37–46](../../Sources/VirtConnectorCore/ActionExecutor.swift#L37)、[ShutdownPerformer.swift:22–27](../../Sources/VirtConnectorCore/ShutdownPerformer.swift#L22)、[CLI/main.swift:256–268](../../Sources/VirtConnectorCLI/main.swift#L256)

`ActionExecutor`は失敗を数えるだけで、`ShutdownPerformer`は`failed`を確認せずに終了を要求する。メニューのエラーダイアログにも到達しない。CLIの`run`も`failed > 0`で終了コード0となり、既定のexecutorにはloggerがないため、個々の失敗理由が表示されない。

**根拠:** `ProcessRunner`だけを「Shortcutは失敗、OS操作は実行せず記録」に置き換え、実際のCoreとCLIを実行した。`shutdown`は`failed=1`にもかかわらず終了要求を記録し、終了コード0だった。`run power-off`も終了コード0、stderrは空だった。

**修正:** 実行結果にデバイスごとの失敗内容を保持する。明示的な終了では、必要な操作が失敗したらデフォルトで終了要求を中止する。失敗を無視して終了する機能が必要なら、明示的な再確認・オプションとして分ける。CLIの操作失敗は非0終了と理由表示にする。

### R4 / P1: 表示イベントとシステム終了が別経路で動き、順序逆転とpower_offの重複が起き得る

**箇所:** [Daemon/main.swift:148–153](../../Sources/VirtConnectorDaemon/main.swift#L148)、[同:205–249](../../Sources/VirtConnectorDaemon/main.swift#L205)、[CLI/main.swift:266–268](../../Sources/VirtConnectorCLI/main.swift#L266)

表示イベントは`actionQueue`、メニュー終了はglobal queue、OS終了通知はメインスレッドで直接実行する。メニュー終了は`powerOffHandled`を更新しない。

このため、進行中の`display_on`が`power_off`と並行して走り、消灯後に点灯操作が完了する順序が可能。メニューで`power_off`を実行した後も、終了通知または`applicationShouldTerminate`で再実行する経路が残る。CLIの終了はさらに別プロセスであり、daemon側のフラグだけでは調停できない。Shortcutは任意の操作なので、重複実行を無害とは仮定できない。

**根拠:** 各呼び出し経路とフラグ更新箇所の静的追跡。実機の終了通知順序に依存する症状の再現は行っていない。

**修正:** 表示操作・明示的終了・OS終了通知を単一の実行調停に集約する。終了開始後は未着手の表示イベントを抑止し、進行中の処理を完了または安全にキャンセルしてから`power_off`を実行する。同じ終了要求の通知による再実行を抑える。CLIからの終了も、daemon稼働時は同じ調停経路に渡す。

### R5 / P2: upgrade時の設定判定と実行時のデコーダーが、異なる設定形式を受理する

**箇所:** [ConfigStore.swift:51–56](../../Sources/VirtConnectorCore/ConfigStore.swift#L51)、[同:80–91](../../Sources/VirtConnectorCore/ConfigStore.swift#L80)、[Config.swift:117–128](../../Sources/VirtConnectorCore/Config.swift#L117)

復元判定は`enabled`しか読まず、キー欠落をtrueにする。一方、実行時の`VirtConnectorConfig`は合成された`Decodable`を使い、`enabled`と`devices`を必須として読む。Swiftのinitializerのデフォルト引数は、合成デコーダーの欠落キー処理には適用されない。

そのため、リリース文書で互換性を説明している「enabledを省略した旧設定」は復元対象になるが、daemonでは読めない。`devices`の型が壊れている設定も復元対象になる。

**根拠:** `{}`、`{"enabled":true}`、`{"enabled":true,"devices":"invalid"}`、`{"devices":[]}`はすべて`shouldRestoreAgent() == true`、実行時の`load()`は失敗した。

**修正:** 旧形式の互換処理を含む共通のデコード・検証経路を使う。受理する旧形式を明示し、必須データが不正な設定は復元対象にしない。upgrade時には設定ファイルを書き換えない契約も維持する。

### R6 / P2: 設定・ログの環境変数がLaunchAgentに引き継がれない

**箇所:** [LaunchAgentManager.swift:59–64](../../Sources/VirtConnectorCore/LaunchAgentManager.swift#L59)、[ConfigStore.swift:10–28](../../Sources/VirtConnectorCore/ConfigStore.swift#L10)

READMEで案内している`VIRT_CONNECTOR_CONFIG`と`VIRT_CONNECTOR_LOG_DIR`を設定しても、生成plistの`EnvironmentVariables`は`PATH`だけ。launchdから起動するdaemonが、登録したシェルの環境をそのまま継承する保証はない。

結果として、CLIは開発用設定を書いたのにdaemonは通常の設定を読む、標準出力ログと`FileLog`の保存先が分かれる、といった不整合になる。通常の設定に実機向けShortcutがある場合は特に注意が必要。

**根拠:** 隔離した保存先を指定してplistだけを生成し、両変数が含まれないことを確認した。サービスは起動していない。

**修正:** 登録時に解決した設定ファイル・ログ保存先を、必要な項目だけ明示的にdaemonへ渡す。環境全体をコピーしない。`restore-agent`が実アカウントの保存先を使う既存方針との整合も取る。

### R7 / P2: 無効状態でCask upgradeした後、enableだけでは監視が再開しない

**箇所:** [CLI/main.swift:107–113](../../Sources/VirtConnectorCLI/main.swift#L107)、[同:144](../../Sources/VirtConnectorCLI/main.swift#L144)、[Casks/virt-connector.rb:14–20](../../Casks/virt-connector.rb#L14)

upgradeで既存サービスがunloadされ、設定がdisabledなら復元されない。これは意図した動作だが、その後の`enable`はJSONをtrueへ変更するだけで、サービスを登録・起動しない。「Monitoring enabled.」と表示されても監視プロセスが存在しない状態になる。

**根拠:** upgradeのunload/復元条件と`enable`の呼び出し経路を静的追跡。プロセス操作の記録用代替実装でも、`enable`がlaunchctlを呼ばないことを確認した。実際のupgradeは行っていない。

**修正:** 設定上の有効・無効とサービスの登録・稼働状態を分けて扱う。明示的な`enable`で必要な登録・起動を行うか、未起動をエラーとして具体的な復旧操作を示す。READMEの「再開」という契約に合わせるなら前者を推奨する。

### R8 / P2: CLIが不足した値や未知のオプションを無視して、更新成功を返す

**箇所:** [CLI/main.swift:355–376](../../Sources/VirtConnectorCLI/main.swift#L355)

`Options`は末尾の値なしオプションや未知のキーを検証しない。次のオプション自体を値として消費することもある。電源操作の設定が意図どおり変更されなかったことを、利用者が認識できない。

**根拠:** 実際のCLIで`device set Review --enabled`および`device set Review --display-of none`を実行すると、設定は変わらないのに終了コード0で`Updated device Review.`と表示された。

**修正:** コマンドごとに許可するオプション、値の有無、位置引数数を検証し、不正な入力は保存前にusage errorとする。既存の小さなパーサーを修正すればよく、このためだけの外部依存追加は必須ではない。

### R9 / P2: arm64専用の配布物に対して、CaskがIntel Macを除外していない

**箇所:** [Casks/virt-connector.rb:2–12](../../Casks/virt-connector.rb#L2)、[build-pkg.sh:82–89](../../scripts/build-pkg.sh#L82)

Caskの制約はmacOS Ventura以降だけだが、0.1.5の[リリース文書](../releases/0.1.5.md)と[ビルド記録](../releases/0.1.5-validation.md)はarm64を明記している。ビルドスクリプトもuniversal binaryやCPU別配布物を生成しない。Intel Macでインストール対象となっても実行できない。

**修正:** 現行配布を維持するならCaskとREADMEでApple Silicon限定を明示する。Intelを正式対応に含めるならuniversalまたはCPU別成果物に切り替え、成果物の実際のarchitectureと配布定義を照合する。

### R10 / P2: 別ボリュームへのpkgインストールが起動中ボリュームのsymlinkを変更する

**箇所:** [postinstall:5–16](../../packaging/pkg-scripts/postinstall#L5)

`$3`のインストール先ボリュームを考慮するのはLaunchAgent復元だけ。その前の`mkdir`と`ln -sf`は常に起動中ボリュームの`/usr/local/bin`へ書く。別ボリュームへインストールしても、そちらにはコマンドのリンクが作られず、稼働環境側のリンクを変更してしまう。

**根拠:** スクリプト内のリンク作成先だけを一時ディレクトリへ置換し、別ボリュームを表す`$3`で実行。起動中ボリュームを模した側にリンクが作られ、指定先には作られなかった。

**修正:** 別ボリュームを非対応とするなら、ファイル操作前に明示的に拒否する。対応するなら、リンクの作成場所を対象ボリュームに解決し、対象OSから見たリンク先を設定する。LaunchAgent復元は起動中ボリュームだけに限定する。

### R11 / P2: Formulaの安定版インストール定義が未完成

**箇所:** [Formula/virt-connector.rb:4–5](../../Formula/virt-connector.rb#L4)

安定版のURLは0.1.0で、checksumが`PUT_SHA256_HERE`のまま。READMEはソースビルド用Formulaとして紹介しているが、この安定版定義は利用可能な配布定義になっていない。`--HEAD`の指定は別経路であり、安定版の問題を解消しない。

**修正:** Formulaをサポートするなら、対応バージョン・実際のアーカイブchecksum・ビルド手順を確定する。Caskだけを正式経路にするなら、Formulaの扱いを明確にし、利用可能であるかのようなREADMEの案内を修正する。

### R12 / P3: Cask更新スクリプトの既定バージョンがビルドと一致しない

**箇所:** [update-cask.sh:6–7](../../scripts/update-cask.sh#L6)、[build-pkg.sh:7](../../scripts/build-pkg.sh#L7)

ビルドの既定値は0.1.5、Cask更新側は0.1.2。`VERSION`を省略して0.1.5のpkgパスだけを渡すと、0.1.2のURLに0.1.5のchecksumを組み合わせたCaskを作る。READMEの例も0.1.2に留まる。

**修正:** バージョンの取得元を統一するか、更新時にバージョンの明示を必須にする。ファイル名だけを信用せず、pkgメタデータ・指定バージョンとの不一致を更新前に拒否する。

## 推奨する修正プラン

### 1. 設定の保全と入力契約を修正する — R2、R5、R8

**変更内容**

- `ConfigStore`に、不存在・不正・正常を区別できる読み込み契約を設ける。
- 旧形式を含むデコード・検証を共通化し、復元可否も同じ結果から判定する。
- CLIの各コマンドで、初期作成を許すか、既存設定を必須とするかを明示する。
- 不正な設定・オプションに対する保存を禁止し、パスと原因を含むエラーを表示する。

**完了条件**

- 破損JSON・型不一致・読み取り不能時の更新で、元ファイルの内容が変わらない。
- 正式にサポートする旧設定は、復元判定とdaemonで同じデバイス・動作に解釈される。
- 未設定の初回setup、disabled、空デバイス、`none`の意図した動作を維持する。
- 値なし・未知のオプションは終了コード2となり、設定を保存しない。

### 2. 外部プロセスの実行契約を修正する — R1

この作業は1と独立して進められる。

**変更内容**

- 両出力を並行して排出し、終了状態と出力収集を取りこぼさず回収する。
- 期限・キャンセル・終了後の後始末を共通実装にする。収集量にも上限方針を持つ。
- `ProcessRunning`相当の小さな差し替え境界を設け、OS操作を発生させずに利用側を検証可能にする。
- launchctl、Shortcuts、osascriptで必要な期限と、タイムアウト時の扱いを明示する。

**完了条件**

- stdoutのみ、stderrのみ、両方同時に各1 MiBを出すケースがデッドロックせず、期待する出力を回収できる。
- 終了しない子に対するテスト用1秒の期限が機能し、後始末の猶予を含め3秒以内に呼び出し側へ制御が戻る。
- 対象プロセスだけを停止し、孤児プロセス・未回収プロセス・開いたハンドルを残さない方針を確認する。
- 起動失敗、非0終了、タイムアウトが別のエラーとして伝わる。

### 3. 終了処理を単一の調停経路へまとめる — R3、R4

1と2の完了後に実施する。

**変更内容**

- Core側に、小さなイベント調停・終了状態管理を切り出す。AppKit側は通知とUIを担当する。
- 通常稼働、終了準備、終了要求済み、失敗・キャンセル後の復帰を区別する。
- 終了準備以降の表示イベントを抑止し、進行中の操作と終了前操作の順序を保証する。
- デバイス別の結果を返し、終了前操作に失敗したらOS終了を要求しない。
- メニューとOS通知の重複を抑える。CLIの`shutdown`もdaemon稼働時は同じ調停へ渡す。
- CLIの手動`run`が終了前操作と競合しない経路・拒否条件も定義する。
- daemon未起動時の直接実行と、接続エラー・応答待ちを区別する。応答タイムアウトを理由に直接実行へ切り替えて二重実行しない。
- OSによる終了要求の受理と実際の終了完了を区別し、後続アプリが終了をキャンセルした場合の復帰方針も決める。

**完了条件**

- 遅い`display_on`の途中で終了を要求しても、`power_off`完了後に点灯操作が残らない。
- メニュー要求、CLI要求、OS通知、AppKit終了コールバックが重なっても、同じ終了要求の`power_off`が重複しない。
- 1台でも必要なShortcutに失敗した場合、OS終了要求は0回。CLIは非0終了、メニューは失敗理由と再試行手段を示す。
- 通常のSIGTERM・bootout・upgrade停止を`power_off`へ変換しない既存方針を維持する。
- UIスレッドを子プロセスの同期待ちで止めない。

### 4. 設定パスとLaunchAgentのライフサイクルを整合させる — R6、R7

**変更内容**

- 設定とログの解決済みパスをCLI・plist・daemonで統一する。
- `enable`、`disable`、登録、削除、upgrade後の各状態遷移を明確にする。
- `status`で設定の有効状態だけでなく、サービスの登録・稼働状態を区別して表示する。
- bootstrap/bootout失敗を明示し、起動確認なしに「再開した」と表示しない。

**完了条件**

- 独自保存先で登録したdaemonが、通常のユーザー設定を読まず、指定先だけを使う。
- enabled/disabledそれぞれのupgrade後に、仕様どおりの登録・稼働状態になる。
- disabled状態のupgrade後でも、`enable`によって実際に監視が再開する。
- 初回インストール・不正設定のupgradeで勝手に監視を開始しない。

### 5. 配布条件とリリース手順を修正する — R9〜R12

**変更内容**

- Apple Silicon限定かIntel対応かを配布仕様として確定し、Cask・成果物・READMEを一致させる。
- pkgの対象ボリューム方針を確定し、ファイル操作と復元条件を合わせる。
- Formulaのサポート範囲を決め、未完成の定義を配布経路として案内しない。
- バージョン・成果物・checksumを一組として扱い、不整合時はCask更新を拒否する。
- READMEの日英両方に、終了前操作の失敗方針、保存先、再開方法、対応環境を反映する。

**完了条件**

- Caskの対応CPU条件とMach-Oのarchitectureが一致する。
- 別ボリューム向け処理が起動中ボリュームを変更しない。
- 公開するインストール経路にplaceholder checksumがない。
- 指定バージョンとpkgが異なる場合、Caskが変更されず明示的に失敗する。

## 設計上の方針とレビューの限界

大きなフレームワークの導入、Shortcuts依存の排除、全面的なSwift Concurrency移行は、この修正の前提にしない。必要なのは、失敗を扱う明確な型、外部プロセスを差し替える小さな境界、イベントと終了処理を統制する一つの所有者である。

既存の回帰テストは復元判定・plist・postinstallに集中している。今後は、上記の完了条件をCoreとCLIの自動テストに固定する。設定ディレクトリとOS操作を隔離し、テストが実ユーザーのLaunchAgentや機器に影響しないことを前提とする。

今回の再現は一時設定、出力専用の子プロセス、OS操作を記録する代替実装で行った。AppKitの実機通知順序、実際のシステム終了・キャンセル、権限付きupgrade、Intel Mac上の実行は実施していない。これらの指摘はコード経路・配布定義・既存ビルド記録を根拠としており、最終的な受け入れには専用環境での確認を含める。
