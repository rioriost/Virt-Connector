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
        if !["setup", "install-agent", "device", "run"].contains(command), !rest.isEmpty {
            throw CLIError.usage("\(command) does not accept arguments or options")
        }
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
            try LaunchAgentManager().ensureRunning(daemonPath: try defaultDaemonPath())
            print("Restarted LaunchAgent \(LaunchAgentManager.label).")
        case "devices":
            try listDevices()
        case "device":
            try device(rest)
        case "shortcuts":
            try listShortcuts()
        case "run":
            guard rest.count == 1, !rest[0].hasPrefix("-") else {
                throw CLIError.usage("run requires exactly one trigger: display-on, display-off, or power-off")
            }
            try runTrigger(rest)
        case "shutdown":
            try shutdown()
        case "resume":
            try AgentCommandRouter().resume()
            print("Monitoring resumed.")
        default:
            throw CLIError.usage("unknown command: \(command)")
        }
    }

    private static func setup(_ arguments: [String]) throws {
        let options = try Options(arguments, allowed: ["--device", "--on", "--off", "--daemon"])
        let daemonPath = try options.value(for: "--daemon") ?? defaultDaemonPath()
        let store = ConfigStore()
        var config = try store.loadOrDefault()

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
        let manager = LaunchAgentManager(configURL: store.configURL)
        try manager.install(daemonPath: daemonPath)
        try manager.bootstrap()

        print("Configured \(store.configURL.path)")
        print("Installed and started LaunchAgent \(LaunchAgentManager.label).")
    }

    private static func status() throws {
        let store = ConfigStore()
        let config = try store.load()
        let manager = LaunchAgentManager(configURL: store.configURL)

        print("Config: \(store.configURL.path)")
        print("Monitoring configuration: \(config.enabled ? "enabled" : "disabled")")
        print("LaunchAgent plist: \(manager.isInstalled ? "installed" : "not installed")")
        let loaded = try manager.isLoaded()
        print("LaunchAgent service: \(loaded ? "loaded" : "not loaded")")
        let running = loaded ? try manager.isRunning() : false
        print("LaunchAgent process: \(running ? "running" : "not running")")
        if config.enabled && !running {
            print("Monitoring is not active; run virt-connector enable to start the LaunchAgent.")
        }
        print("Devices: \(config.devices.count)")

        for device in config.devices {
            printDevice(device)
        }

        print("")
        print("LaunchAgent:")
        print(try manager.printStatus())
    }

    private static func setEnabled(_ enabled: Bool) throws {
        let store = ConfigStore()
        var config = try store.load()
        config.enabled = enabled
        try store.save(config)
        if enabled {
            do {
                try LaunchAgentManager(configURL: store.configURL).ensureRunning(daemonPath: try defaultDaemonPath())
            } catch {
                throw CLIError.operation(
                    "Configuration is enabled, but the LaunchAgent could not be started: \(error.localizedDescription) "
                    + "Monitoring may be inactive; fix the error and retry enable, or use install-agent --daemon PATH."
                )
            }
            print("Monitoring enabled; LaunchAgent process is running.")
        } else {
            print("Monitoring disabled in configuration; the LaunchAgent may remain loaded but will skip device actions.")
        }
    }

    private static func installAgent(_ arguments: [String]) throws {
        let options = try Options(arguments, allowed: ["--daemon"])
        let daemonPath = try options.value(for: "--daemon") ?? defaultDaemonPath()
        let manager = LaunchAgentManager()
        try manager.install(daemonPath: daemonPath)
        try manager.bootstrap()
        print("LaunchAgent plist: \(manager.installedPlistPath)")
        print("Daemon: \(daemonPath)")
    }

    private static func listDevices() throws {
        let config = try ConfigStore().load()
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
            logDirectory: home.appendingPathComponent("Library/Logs"),
            configURL: store.configURL
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
        guard let name = arguments.first, !name.hasPrefix("-"), !name.isEmpty else {
            throw CLIError.usage("device add requires a name")
        }

        let options = try Options(
            Array(arguments.dropFirst()),
            allowed: ["--on", "--off", "--display-on", "--display-off", "--power-off"]
        )
        guard let onShortcut = options.value(for: "--on") else {
            throw CLIError.usage("device add requires --on SHORTCUT")
        }
        guard let offShortcut = options.value(for: "--off") else {
            throw CLIError.usage("device add requires --off SHORTCUT")
        }

        var actions = TriggerActions()
        try applyActionOptions(options, to: &actions)
        let store = ConfigStore()
        var config = try store.loadOrDefault()

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
        guard arguments.count == 1, let selector = arguments.first,
              !selector.hasPrefix("-"), !selector.isEmpty else {
            throw CLIError.usage("device remove requires exactly one name or UUID")
        }

        let store = ConfigStore()
        var config = try store.load()
        let before = config.devices.count
        config.devices.removeAll { matches($0, selector: selector) }
        guard config.devices.count != before else {
            throw CLIError.usage("device not found: \(selector)")
        }

        try store.save(config)
        print("Removed device \(selector).")
    }

    private static func setDevice(_ arguments: [String]) throws {
        guard let selector = arguments.first, !selector.hasPrefix("-"), !selector.isEmpty else {
            throw CLIError.usage("device set requires a name or UUID")
        }

        let options = try Options(
            Array(arguments.dropFirst()),
            allowed: ["--name", "--enabled", "--on", "--off", "--display-on", "--display-off", "--power-off"]
        )
        guard arguments.count > 1 else {
            throw CLIError.usage("device set requires at least one option")
        }
        let enabled = try options.value(for: "--enabled").map(parseBool)
        var actions = TriggerActions()
        try applyActionOptions(options, to: &actions)
        let store = ConfigStore()
        var config = try store.load()

        guard let index = config.devices.firstIndex(where: { matches($0, selector: selector) }) else {
            throw CLIError.usage("device not found: \(selector)")
        }

        if let name = options.value(for: "--name") {
            config.devices[index].name = name
        }
        if let enabled {
            config.devices[index].enabled = enabled
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

        let result = try AgentCommandRouter().run(trigger)
        try result.requireSuccess()
        print("Executed \(trigger.rawValue): attempted=\(result.attempted) failed=\(result.failed)")
    }

    private static func shutdown() throws {
        let result = try AgentCommandRouter().shutdown()
        try result.requireSuccess()
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
              virt-connector setup [--device NAME --on SHORTCUT --off SHORTCUT] [--daemon PATH]
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
              virt-connector resume

            setup and device add may create a missing configuration. Other configuration
            commands require a readable, valid configuration; failures never replace it.
            enable starts the managed LaunchAgent and verifies a stable running PID.
            enable and restart-agent refresh its plist while preserving the registered daemon path.
            disable changes configuration only; a loaded agent skips device actions.
            resume clears a loaded agent's completed/cancelled shutdown state.
            """
        )
    }
}

private struct Options {
    private let values: [String: String]

    init(_ arguments: [String], allowed: Set<String>) throws {
        var values: [String: String] = [:]
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            guard allowed.contains(argument) else {
                throw CLIError.usage("unknown option or unexpected argument: \(argument)")
            }
            guard values[argument] == nil else {
                throw CLIError.usage("duplicate option: \(argument)")
            }
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-"),
                  !arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError.usage("\(argument) requires a value")
            }
            values[argument] = arguments[index + 1]
            index += 2
        }

        self.values = values
    }

    func value(for option: String) -> String? {
        values[option]
    }
}

private enum CLIError: LocalizedError {
    case usage(String)
    case operation(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message), .operation(let message):
            return message
        }
    }
}
