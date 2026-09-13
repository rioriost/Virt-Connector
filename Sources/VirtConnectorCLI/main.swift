import Foundation
import VirtConnectorCore

@main
struct VirtConnectorCLI {
    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch CLIError.usage(let message) {
            if !message.isEmpty {
                fputs("error: \(message)\n\n", stderr)
            }
            printUsage()
            exit(2)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            throw CLIError.usage("")
        }

        if getuid() == 0 && !["help", "-h", "--help"].contains(command) {
            throw CLIError.usage("do not run virt-connector with sudo; setup installs a LaunchAgent for the logged-in user")
        }

        let rest = Array(arguments.dropFirst())
        switch command {
        case "help", "-h", "--help":
            printUsage()
        case "setup":
            try setup(rest)
        case "status":
            try status()
        case "enable":
            try setEnabled(true)
        case "disable":
            try setEnabled(false)
        case "install-agent":
            try installAgent(rest)
        case "restore-agent":
            try restoreAgent()
        case "uninstall-agent":
            try LaunchAgentManager().uninstall()
            print("Uninstalled LaunchAgent \(LaunchAgentManager.label).")
        case "restart-agent":
            try LaunchAgentManager().bootstrap()
            print("Restarted LaunchAgent \(LaunchAgentManager.label).")
        case "devices":
            try listDevices()
        case "device":
            try device(rest)
        case "shortcuts":
            try listShortcuts()
        case "run":
            try runTrigger(rest)
        case "shutdown":
            try shutdown()
        default:
            throw CLIError.usage("unknown command: \(command)")
        }
    }

    private static func setup(_ arguments: [String]) throws {
        let options = Options(arguments)
        let store = ConfigStore()
        var config = store.loadOrDefault()

        if config.devices.isEmpty {
            config.devices.append(
                ShortcutDevice(
                    name: options.value(for: "--device") ?? "LED Strip",
                    onShortcut: options.value(for: "--on") ?? "TurnOnLED",
                    offShortcut: options.value(for: "--off") ?? "TurnOffLED"
                )
            )
        }

        config.enabled = true
        try store.save(config)
        try installAgent(arguments)

        print("Configured \(store.configURL.path)")
        print("Installed and started LaunchAgent \(LaunchAgentManager.label).")
    }

    private static func status() throws {
        let store = ConfigStore()
        let config = store.loadOrDefault()

        print("Config: \(store.configURL.path)")
        print("Monitoring: \(config.enabled ? "enabled" : "disabled")")
        print("Devices: \(config.devices.count)")

        for device in config.devices {
            printDevice(device)
        }

        print("")
        print("LaunchAgent:")
        print(try LaunchAgentManager().printStatus())
    }

    private static func setEnabled(_ enabled: Bool) throws {
        let store = ConfigStore()
        var config = store.loadOrDefault()
        config.enabled = enabled
        try store.save(config)
        print("Monitoring \(enabled ? "enabled" : "disabled").")
    }

    private static func installAgent(_ arguments: [String]) throws {
        let options = Options(arguments)
        let daemonPath = try options.value(for: "--daemon") ?? defaultDaemonPath()
        let manager = LaunchAgentManager()
        try manager.install(daemonPath: daemonPath)
        try manager.bootstrap()
        print("LaunchAgent plist: \(manager.installedPlistPath)")
        print("Daemon: \(daemonPath)")
    }

    private static func listDevices() throws {
        let config = ConfigStore().loadOrDefault()
        if config.devices.isEmpty {
            print("No devices configured.")
            return
        }

        for device in config.devices {
            printDevice(device)
        }
    }

    private static func restoreAgent() throws {
        // Homebrew flight steps use a temporary HOME. Resolve the account's home
        // explicitly so upgrades continue to use the user's existing configuration.
        guard let home = FileManager.default.homeDirectory(forUser: NSUserName()) else {
            throw CLIError.usage("could not find the current user's home directory")
        }
        let store = ConfigStore(configURL: home.appendingPathComponent(".config/virt-connector/config.json"))
        guard store.shouldRestoreAgent() else { return }

        let manager = LaunchAgentManager(
            plistURL: home.appendingPathComponent("Library/LaunchAgents/\(LaunchAgentManager.label).plist"),
            logDirectory: home.appendingPathComponent("Library/Logs")
        )
        try manager.install(daemonPath: "/Library/VirtConnector/VirtConnectorAgent.app/Contents/MacOS/virt-connectord")
        try manager.bootstrap()
        print("Restored LaunchAgent \(LaunchAgentManager.label).")
    }

    private static func device(_ arguments: [String]) throws {
        guard let subcommand = arguments.first else {
            throw CLIError.usage("device requires add, remove, or set")
        }

        let rest = Array(arguments.dropFirst())
        switch subcommand {
        case "add":
            try addDevice(rest)
        case "remove":
            try removeDevice(rest)
        case "set":
            try setDevice(rest)
        default:
            throw CLIError.usage("unknown device subcommand: \(subcommand)")
        }
    }

    private static func addDevice(_ arguments: [String]) throws {
        guard let name = arguments.first, !name.hasPrefix("--") else {
            throw CLIError.usage("device add requires a name")
        }

        let options = Options(Array(arguments.dropFirst()))
        guard let onShortcut = options.value(for: "--on") else {
            throw CLIError.usage("device add requires --on SHORTCUT")
        }
        guard let offShortcut = options.value(for: "--off") else {
            throw CLIError.usage("device add requires --off SHORTCUT")
        }

        let store = ConfigStore()
        var config = store.loadOrDefault()
        var actions = TriggerActions()
        try applyActionOptions(options, to: &actions)

        let device = ShortcutDevice(
            name: name,
            onShortcut: onShortcut,
            offShortcut: offShortcut,
            actions: actions
        )
        config.devices.append(device)
        try store.save(config)
        print("Added device \(name).")
    }

    private static func removeDevice(_ arguments: [String]) throws {
        guard let selector = arguments.first else {
            throw CLIError.usage("device remove requires a name or UUID")
        }

        let store = ConfigStore()
        var config = store.loadOrDefault()
        let before = config.devices.count
        config.devices.removeAll { matches($0, selector: selector) }
        guard config.devices.count != before else {
            throw CLIError.usage("device not found: \(selector)")
        }

        try store.save(config)
        print("Removed device \(selector).")
    }

    private static func setDevice(_ arguments: [String]) throws {
        guard let selector = arguments.first else {
            throw CLIError.usage("device set requires a name or UUID")
        }

        let options = Options(Array(arguments.dropFirst()))
        let store = ConfigStore()
        var config = store.loadOrDefault()

        guard let index = config.devices.firstIndex(where: { matches($0, selector: selector) }) else {
            throw CLIError.usage("device not found: \(selector)")
        }

        if let name = options.value(for: "--name") {
            config.devices[index].name = name
        }
        if let enabled = options.value(for: "--enabled") {
            config.devices[index].enabled = try parseBool(enabled)
        }
        if let onShortcut = options.value(for: "--on") {
            config.devices[index].onShortcut = onShortcut
        }
        if let offShortcut = options.value(for: "--off") {
            config.devices[index].offShortcut = offShortcut
        }
        try applyActionOptions(options, to: &config.devices[index].actions)

        try store.save(config)
        print("Updated device \(config.devices[index].name).")
    }

    private static func listShortcuts() throws {
        for shortcut in try ShortcutRunner().listShortcuts() {
            print(shortcut)
        }
    }

    private static func runTrigger(_ arguments: [String]) throws {
        guard let triggerArgument = arguments.first, let trigger = PowerTrigger(argument: triggerArgument) else {
            throw CLIError.usage("run requires display-on, display-off, or power-off")
        }

        let config = ConfigStore().loadOrDefault()
        let result = ActionExecutor().execute(trigger: trigger, config: config)
        print("Executed \(trigger.rawValue): attempted=\(result.attempted) failed=\(result.failed)")
    }

    private static func shutdown() throws {
        let result = try ShutdownPerformer().perform()
        print("Executed power_off: attempted=\(result.attempted) failed=\(result.failed)")
    }

    private static func applyActionOptions(_ options: Options, to actions: inout TriggerActions) throws {
        for (option, trigger) in [
            ("--display-on", PowerTrigger.displayOn),
            ("--display-off", PowerTrigger.displayOff),
            ("--power-off", PowerTrigger.powerOff)
        ] {
            if let value = options.value(for: option) {
                guard let action = DeviceAction(argument: value) else {
                    throw CLIError.usage("\(option) must be on, off, or none")
                }
                actions.set(action, for: trigger)
            }
        }
    }

    private static func printDevice(_ device: ShortcutDevice) {
        print("- \(device.name) [\(device.enabled ? "enabled" : "disabled")] id=\(device.id.uuidString)")
        print("  shortcuts: on='\(device.onShortcut)' off='\(device.offShortcut)'")
        print("  actions: display_on=\(device.actions.displayOn.rawValue) display_off=\(device.actions.displayOff.rawValue) power_off=\(device.actions.powerOff.rawValue)")
    }

    private static func matches(_ device: ShortcutDevice, selector: String) -> Bool {
        device.name == selector || device.id.uuidString == selector
    }

    private static func parseBool(_ value: String) throws -> Bool {
        switch value.lowercased() {
        case "true", "yes", "1", "enabled", "on":
            return true
        case "false", "no", "0", "disabled", "off":
            return false
        default:
            throw CLIError.usage("boolean value must be true or false")
        }
    }

    private static func defaultDaemonPath() throws -> String {
        if let path = ProcessInfo.processInfo.environment["VIRT_CONNECTORD_PATH"], !path.isEmpty {
            return path
        }

        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let bundledAgent = "/Library/VirtConnector/VirtConnectorAgent.app/Contents/MacOS/virt-connectord"
        if FileManager.default.isExecutableFile(atPath: bundledAgent) {
            return bundledAgent
        }

        let sibling = executableURL.deletingLastPathComponent().appendingPathComponent("virt-connectord").path
        if FileManager.default.isExecutableFile(atPath: sibling) {
            return sibling
        }

        for candidate in ["/opt/homebrew/bin/virt-connectord", "/usr/local/bin/virt-connectord"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        throw CLIError.usage("could not find virt-connectord; pass --daemon PATH")
    }

    private static func printUsage() {
        print(
            """
            Usage:
              virt-connector setup [--device NAME --on SHORTCUT --off SHORTCUT]
              virt-connector status
              virt-connector enable | disable
              virt-connector install-agent [--daemon PATH]
              virt-connector restore-agent
              virt-connector uninstall-agent
              virt-connector restart-agent
              virt-connector shortcuts
              virt-connector devices
              virt-connector device add NAME --on SHORTCUT --off SHORTCUT [--display-on on|off|none] [--display-off on|off|none] [--power-off on|off|none]
              virt-connector device set NAME_OR_UUID [--name NAME] [--enabled true|false] [--on SHORTCUT] [--off SHORTCUT] [--display-on on|off|none] [--display-off on|off|none] [--power-off on|off|none]
              virt-connector device remove NAME_OR_UUID
              virt-connector run display-on|display-off|power-off
              virt-connector shutdown
            """
        )
    }
}

private struct Options {
    private let values: [String: String]

    init(_ arguments: [String]) {
        var values: [String: String] = [:]
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--"), index + 1 < arguments.count {
                values[argument] = arguments[index + 1]
                index += 2
            } else {
                index += 1
            }
        }

        self.values = values
    }

    func value(for option: String) -> String? {
        values[option]
    }
}

private enum CLIError: LocalizedError {
    case usage(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message):
            return message
        }
    }
}
