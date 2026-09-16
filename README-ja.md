# VirtConnector

## 概要

VirtConnectorは、macOSのディスプレイスリープ/復帰と、ユーザーが明示的に実行するシステム終了操作をShortcutsに連動させるツールです。

Apple HomeやMatterデバイスを直接制御するのではなく、制御対象はShortcuts側で選択します。VirtConnectorはmacOS側の常駐監視、LaunchAgent登録、イベントごとのShortcuts実行を担当します。

## Quick Start

署名済みpkgはApple Silicon（arm64）、macOS 13以降、起動中のボリュームへのインストールに対応します。

### 1. Homebrew Caskでインストール

```sh
brew tap rioriost/cask https://github.com/rioriost/homebrew-cask
brew install --cask rioriost/cask/virt-connector
```

ローカル検証用Caskを使う場合は、開発環境で以下を実行します。

```sh
HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask rioriost/cask/virt-connector-local
```

### 2. Shortcutsを作成

macOSのショートカット.appで、制御したいHome/Matterデバイス用のShortcutを2つ作成します。

- `TurnOnLED`: 例として`LED Strip`をオンにする
- `TurnOffLED`: 例として`LED Strip`をオフにする

作成後、ターミナルから手動実行できることを確認します。

```sh
shortcuts run TurnOnLED
shortcuts run TurnOffLED
```

### 3. VirtConnectorを設定

```sh
virt-connector setup --device "LED Strip" --on TurnOnLED --off TurnOffLED
```

これで以下が行われます。

- `~/.config/virt-connector/config.json` を作成または更新
- `~/Library/LaunchAgents/st.rio.virt-connectord.plist` を作成
- `VirtConnectorAgent`をユーザーLaunchAgentとして起動
- メニューバーにVirtConnectorの電源アイコンを表示

以後、ディスプレイのスリープ/復帰に応じて`TurnOffLED`/`TurnOnLED`が実行されます。

システム終了前にLEDの消灯動作を実行したい場合は、Appleメニューではなく、VirtConnectorのメニューバーアイコンから「システム終了...」を選びます。設定済みの`power_off`動作が成功した場合だけmacOSのシステム終了を要求します。Shortcutの成功とは別に、実際の機器状態を検証するものではありません。

## 構成

- `virt-connector`
  - 設定、デバイス管理、LaunchAgent管理、手動テスト、システム終了を行うCLIです。
- `VirtConnectorAgent.app`
  - `virt-connectord`を含む常駐エージェントです。
  - ユーザーLaunchAgentとしてAquaセッションで起動します。
  - メニューバーアイコンと「システム終了...」メニューを提供します。
- `virt-connectord`
  - `VirtConnectorAgent.app/Contents/MacOS/virt-connectord`に含まれる実行ファイルです。
  - `/usr/local/bin/virt-connectord`はこの実行ファイルへのsymlinkです。

`virt-connectord`は非SandboxのユーザーLaunchAgentとして動作します。ディスプレイのスリープ/復帰はAppKitの`NSWorkspace`通知で検出し、継続的な`pmset`ポーリングは行いません。

## 監視イベント

- `display_on`
  - `NSWorkspace.screensDidWakeNotification`または`NSWorkspace.didWakeNotification`を受け取ったとき。
- `display_off`
  - `NSWorkspace.screensDidSleepNotification`または`NSWorkspace.willSleepNotification`を受け取ったとき。
- `power_off`
  - VirtConnectorのメニューバー項目「システム終了...」または`virt-connector shutdown`で明示的にシステム終了を開始したとき。
  - Appleメニューの「システム終了...」は`NSWorkspace.willPowerOffNotification`でbest-effortに扱える場合がありますが、Shortcutsがすでに終了処理に入っている場合は失敗することがあります。
  - Homebrew upgrade、`launchctl bootout`、`SIGTERM`などのLaunchAgent停止イベントは`power_off`として扱いません。

各デバイスはイベントごとに`on`、`off`、`none`を設定できます。

エージェント稼働中は、表示イベント・CLIの手動操作・終了要求を同じ実行管理に集約します。終了準備を開始すると未着手の表示操作を取り消し、新たな手動操作を拒否します。同じ終了要求に伴う通知で電源オフ動作を繰り返しません。エージェント未登録時のCLI単独実行は、ユーザー単位のロックで他のエージェント・CLIとの同時実行を防ぎます。

デフォルトでは、最初に作成されるデバイスは以下の動作になります。

- `display_on`: `on`
- `display_off`: `off`
- `power_off`: `off`

## インストールされるファイル

Homebrew Caskでインストールされるpkgは、主に以下を配置します。

```text
/Library/VirtConnector/bin/virt-connector
/Library/VirtConnector/VirtConnectorAgent.app
/Library/VirtConnector/VirtConnectorAgent.app/Contents/MacOS/virt-connectord
/usr/local/bin/virt-connector -> /Library/VirtConnector/bin/virt-connector
/usr/local/bin/virt-connectord -> /Library/VirtConnector/VirtConnectorAgent.app/Contents/MacOS/virt-connectord
```

pkgのインストールだけではLaunchAgentは登録・起動しません。ユーザーが明示的に以下を実行したときだけ常駐設定が作成されます。

```sh
virt-connector setup
```

以後のHomebrew Cask upgradeでは、既存configがあり監視が有効な場合だけLaunchAgentを自動で再登録します。configがない初回インストールでは自動起動しません。

署名済みpkgのインストーラースクリプトから、ログイン中のユーザーとして`virt-connector restore-agent`を実行します。Homebrewの隔離環境外で常駐登録を行い、設定なし・無効・不正な設定では何も変更しません。登録に失敗してもインストール済みファイルを保持し、再試行方法を警告に表示します。

`sudo virt-connector setup`は使わないでください。LaunchAgentはログイン中のユーザーに対して登録する必要があるため、rootで実行すると正しいAquaセッションに登録できません。CLIは`sudo`実行を拒否します。

## Shortcuts

VirtConnectorは、デバイス制御をすべてShortcutsに委譲します。

例として`LED Strip`を制御する場合、ショートカット.appで以下を作成します。

- `TurnOnLED`
  - Homeの`LED Strip`をオンにする。
- `TurnOffLED`
  - Homeの`LED Strip`をオフにする。

Shortcut名は任意です。`setup`や`device add`で指定した名前が使われます。

Shortcut一覧は以下で確認できます。

```sh
virt-connector shortcuts
```

## セットアップ

デフォルト設定では、`LED Strip`というデバイスを作成し、`TurnOnLED`と`TurnOffLED`を使います。

```sh
virt-connector setup
```

デバイス名とShortcut名を明示する場合:

```sh
virt-connector setup --device "LED Strip" --on TurnOnLED --off TurnOffLED
```

設定ファイル:

```text
~/.config/virt-connector/config.json
```

LaunchAgent plist:

```text
~/Library/LaunchAgents/st.rio.virt-connectord.plist
```

ログ:

```text
~/Library/Logs/virt-connectord.log
~/Library/Logs/virt-connectord.out.log
~/Library/Logs/virt-connectord.err.log
```

テストや開発時は、以下の環境変数で保存先を変更できます。

```sh
export VIRT_CONNECTOR_CONFIG=/tmp/virt-connector/config.json
export VIRT_CONNECTOR_LOG_DIR=/tmp/virt-connector/logs
export VIRT_CONNECTOR_LAUNCH_AGENTS_DIR=/tmp/virt-connector/LaunchAgents
```

登録時に解決した設定・ログの保存先はplistに記録されます。稼働中のエージェントとCLIの設定パスが違う場合、手動操作はエラーになります。意図した保存先でエージェントを再登録してください。これらの変数は、同じユーザーの別エージェントを作るものではありません。

既存の設定が読めない場合や不正な場合はエラーとし、空の設定で上書きしません。設定ファイルの初期作成は初期化を行うコマンドだけが行います。旧設定の`enabled`省略はtrueとして扱いますが、有効な`devices`配列が必要です。

## デバイス設定

デバイス一覧:

```sh
virt-connector devices
```

デバイス追加:

```sh
virt-connector device add "LED Strip" \
  --on TurnOnLED \
  --off TurnOffLED \
  --display-on on \
  --display-off off \
  --power-off off
```

イベントごとの動作変更:

```sh
virt-connector device set "LED Strip" \
  --display-on on \
  --display-off off \
  --power-off off
```

有効な動作:

- `on`
  - そのデバイスの`--on` Shortcutを実行します。
- `off`
  - そのデバイスの`--off` Shortcutを実行します。
- `none`
  - そのイベントでは何もしません。

デバイス削除:

```sh
virt-connector device remove "LED Strip"
```

全体の自動連動を停止:

```sh
virt-connector disable
```

再開:

```sh
virt-connector enable
```

`enable`は必要に応じてエージェントの登録・起動も行うため、無効状態でupgradeした後でも監視を再開できます。`status`は設定の有効・無効とLaunchAgentの登録・ロード状態を分けて表示します。

## 手動テスト

macOSイベントを待たずに、設定済みの動作を手動実行できます。

```sh
virt-connector run display-on
virt-connector run display-off
virt-connector run power-off
```

状態確認:

```sh
virt-connector status
```

## システム終了

macOSへの終了要求より前に`power_off`動作を完了させたい場合は、以下のどちらかを使います。

- メニューバーのVirtConnectorアイコンから「システム終了...」を選ぶ
- CLIで`virt-connector shutdown`を実行する

CLIの場合:

```sh
virt-connector shutdown
```

このコマンドは、必要な`power_off`動作がすべて成功した場合だけ、System Events経由でmacOSのシステム終了を要求します。失敗したデバイス・Shortcutと理由を表示し、CLIは非0の終了コードを返します。エージェント稼働中はCLIもエージェント経由で実行し、競合するShortcutを起動しません。接続失敗や応答タイムアウト時に、CLI単独で自動再実行することもありません。

Appleメニューからの終了は引き続きbest-effortです。Shortcutsがすでに使えない場合があり、機器操作に失敗してもVirtConnectorから外部の終了要求を取り消すことはできません。

VirtConnectorの操作完了後、別のアプリケーションによってmacOSの終了がキャンセルされた場合は、メニューの「終了キャンセル後に監視を再開...」または以下を使います。

```sh
virt-connector resume
```

必ずmacOSの終了をキャンセル済みの場合だけ実行してください。イベント受付を再開する操作であり、OSの終了要求を取り消したり、無効な設定を有効化したりするものではありません。VirtConnector自体の終了要求に失敗した場合は、自動的に通常のイベント受付へ戻ります。

Shortcutの実行期限は1プロセス30秒、イベント全体の動作は120秒です。タイムアウトは成功ではなく失敗として扱います。

メニューバーの表示言語は、macOSの`AppleLanguages`、つまり`Locale.preferredLanguages`に従って日本語/英語を切り替えます。

## LaunchAgent管理

LaunchAgentを再登録:

```sh
virt-connector restart-agent
```

LaunchAgentを削除:

```sh
virt-connector uninstall-agent
```

明示的にdaemon実行ファイルを指定して登録:

```sh
virt-connector install-agent --daemon /path/to/virt-connectord
```

通常のCaskインストールでは、`setup`が`/Library/VirtConnector/VirtConnectorAgent.app/Contents/MacOS/virt-connectord`を自動検出します。

## Homebrew Cask配布

公開配布物は、署名・notarize・staple済みのpkgを想定しています。

```text
VirtConnector-<version>-signed.pkg
```

Cask定義:

```text
Casks/virt-connector.rb
```

CaskのURLはGitHub Releasesを前提にしています。

```text
https://github.com/rioriost/Virt-Connector/releases/download/v#{version}/VirtConnector-#{version}-signed.pkg
```

Caskは`rioriost/homebrew-cask` tapで公開します。

## パッケージ作成

ローカル検証用のunsigned pkg:

```sh
scripts/build-pkg.sh --unsigned
```

署名付きpkgを作るには、login keychainに以下の証明書が必要です。

- `Developer ID Application`
- `Developer ID Installer`

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
DEVELOPER_ID_INSTALLER="Developer ID Installer: Your Name (TEAMID)" \
scripts/build-pkg.sh
```

notarytoolの認証情報を保存:

```sh
APPLE_ID=you@example.com \
APPLE_TEAM_ID=TEAMID \
APPLE_APP_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx \
scripts/notarytool-store-credentials.sh virt-connector-notary
```

notarizeしてstaple:

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
DEVELOPER_ID_INSTALLER="Developer ID Installer: Your Name (TEAMID)" \
NOTARYTOOL_PROFILE=virt-connector-notary \
scripts/build-pkg.sh --notarize
```

最終pkgのSHA256をCaskに反映:

```sh
scripts/update-cask.sh dist/VirtConnector-0.1.6-signed.pkg
```

ビルドとCask更新はリポジトリの`VERSION`ファイルを共有します。Cask更新前にpkgの識別子・バージョンを確認し、不一致の場合は変更を拒否します。必ずnotarize・staple後の最終成果物から更新してください。

## Homebrew Formula

`Formula/virt-connector.rb`は、明示的な`--HEAD`を必要とする開発用定義です。安定版Formulaは提供しません。正式なパッケージ配布にはCaskを、ローカル開発には以下のSwiftビルド手順を使ってください。

通常利用者向けの配布経路はCaskです。Caskはpkg経由で`VirtConnectorAgent.app`を配置でき、メニューバー項目やnotarizationを含むmacOSアプリ配布に向いています。

## ビルド

```sh
swift build
swift build -c release
```

回帰テストは一時設定とOS操作の代替実装を使い、Macのシステム終了や実機の操作を行いません。

```sh
swift test
python3 -B -m unittest scripts/test-postinstall.py scripts/test-packaging.py
```

## ライセンス

MIT. See `LICENSE`.
