# VirtConnector

## 概要

VirtConnectorは、macOSのディスプレイスリープ/復帰と、ユーザーが明示的に実行するシステム終了操作をShortcutsに連動させるツールです。

Apple HomeやMatterデバイスを直接制御するのではなく、制御対象はShortcuts側で選択します。VirtConnectorはmacOS側の常駐監視、LaunchAgent登録、イベントごとのShortcuts実行を担当します。

## Quick Start

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

システム終了時に確実にLEDをオフにしたい場合は、Appleメニューの「システム終了...」ではなく、VirtConnectorのメニューバーアイコンから「システム終了...」を選びます。このメニューは、設定済みの`power_off`動作を実行してからmacOSのシステム終了を要求します。

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

安定して`power_off`動作を実行したい場合は、以下のどちらかを使います。

- メニューバーのVirtConnectorアイコンから「システム終了...」を選ぶ
- CLIで`virt-connector shutdown`を実行する

CLIの場合:

```sh
virt-connector shutdown
```

このコマンドは、設定済みの`power_off`動作を実行してから、System Events経由でmacOSのシステム終了を要求します。

Appleメニューの「システム終了...」から開始された終了処理もbest-effortで検知を試みますが、macOSの終了フェーズではShortcuts実行がすでに失敗することがあります。そのため、確実な消灯が必要な場合はVirtConnectorのメニューまたは`virt-connector shutdown`を使ってください。

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
VERSION=0.1.2 scripts/update-cask.sh dist/VirtConnector-0.1.2-signed.pkg
```

## Homebrew Formula

`Formula/virt-connector.rb`は、HomebrewでソースビルドするためのFormulaです。

通常利用者向けの配布経路はCaskです。Caskはpkg経由で`VirtConnectorAgent.app`を配置でき、メニューバー項目やnotarizationを含むmacOSアプリ配布に向いています。

## ビルド

```sh
swift build
swift build -c release
```

## ライセンス

MIT. See `LICENSE`.
