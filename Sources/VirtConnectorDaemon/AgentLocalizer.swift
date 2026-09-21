import Foundation

struct AgentLocalizer {
    private let languageCode: String

    init(preferredLanguages: [String] = Locale.preferredLanguages) {
        languageCode = preferredLanguages.first?.lowercased() ?? "en"
    }

    var shutdownMenuTitle: String {
        isJapanese ? "システム終了…" : "Shut Down…"
    }

    var shutdownDialogTitle: String {
        isJapanese ? "このMacをシステム終了しますか？" : "Shut Down This Mac?"
    }

    var shutdownDialogMessage: String {
        if isJapanese {
            return "設定済みの電源オフ動作に成功した後、macOSのシステム終了を要求します。動作に失敗した場合は終了を中止します。"
        }
        return "VirtConnector requests macOS shutdown only after configured power-off actions succeed. Failed actions cancel this request."
    }

    var shutdownButtonTitle: String {
        isJapanese ? "システム終了" : "Shut Down"
    }

    var cancelButtonTitle: String {
        isJapanese ? "キャンセル" : "Cancel"
    }

    var shutdownFailedTitle: String {
        isJapanese ? "システム終了に失敗しました" : "Shutdown Failed"
    }

    var resumeMenuTitle: String {
        isJapanese ? "監視を再開…" : "Resume Monitoring…"
    }

    var resumeButtonTitle: String {
        isJapanese ? "監視を再開" : "Resume Monitoring"
    }

    var resumeDialogTitle: String {
        isJapanese ? "システム終了をキャンセルしましたか？" : "Did You Cancel System Shutdown?"
    }

    var resumeFailedTitle: String {
        isJapanese ? "監視を再開できませんでした" : "Couldn’t Resume Monitoring"
    }

    func statusTitle(_ state: AgentMenuState) -> String {
        switch state {
        case .monitoring(let count):
            if count == 0 { return isJapanese ? "有効なデバイスがありません" : "No Enabled Devices" }
            return isJapanese ? "ディスプレイのスリープ／復帰を監視中" : "Monitoring Display Sleep and Wake"
        case .disabled:
            return isJapanese ? "自動連動はオフです" : "Automation Is Off"
        case .configurationUnavailable:
            return isJapanese ? "設定を読み込めません" : "Configuration Unavailable"
        case .preparingShutdown:
            return isJapanese ? "システム終了を準備中…" : "Preparing to Shut Down…"
        case .shutdownRequested:
            return isJapanese ? "システム終了を要求済み" : "System Shutdown Requested"
        }
    }

    func statusDetail(_ state: AgentMenuState) -> String {
        switch state {
        case .monitoring(let count):
            if count == 0 { return isJapanese ? "CLIでデバイスを追加・有効化してください" : "Add or enable a device using the CLI" }
            return isJapanese ? "有効なデバイス：\(count)台" : "\(count) enabled \(count == 1 ? "device" : "devices")"
        case .disabled:
            return isJapanese ? "CLIで自動連動を有効にできます" : "Enable automation using the CLI"
        case .configurationUnavailable:
            return isJapanese ? "CLIで設定を確認してください" : "Check your configuration using the CLI"
        case .preparingShutdown:
            return isJapanese ? "電源オフ動作と終了要求を処理しています" : "Processing power-off actions and shutdown"
        case .shutdownRequested:
            return isJapanese ? "終了をキャンセルした場合は監視を再開できます" : "Resume monitoring if you canceled shutdown"
        }
    }

    var resumeMessage: String {
        if isJapanese {
            return "macOSの終了をキャンセル済みの場合だけ再開してください。この操作自体はmacOSの終了要求を取り消しません。"
        }
        return "Resume only after canceling macOS shutdown. This action does not cancel the operating system's shutdown request."
    }

    private var isJapanese: Bool {
        languageCode == "ja" || languageCode.hasPrefix("ja-") || languageCode.hasPrefix("ja_")
    }
}
