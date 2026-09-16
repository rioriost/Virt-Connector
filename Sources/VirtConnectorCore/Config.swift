import Foundation

public enum PowerTrigger: String, Codable, CaseIterable {
    case displayOn = "display_on"
    case displayOff = "display_off"
    case powerOff = "power_off"

    public init?(argument: String) {
        switch argument {
        case "display-on", "display_on", "wake", "on":
            self = .displayOn
        case "display-off", "display_off", "sleep", "off":
            self = .displayOff
        case "power-off", "power_off", "shutdown":
            self = .powerOff
        default:
            return nil
        }
    }

    public var displayName: String {
        switch self {
        case .displayOn:
            return "Display On"
        case .displayOff:
            return "Display Off"
        case .powerOff:
            return "Power Off"
        }
    }
}

public enum DeviceAction: String, Codable, CaseIterable {
    case none
    case on
    case off

    public init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}

public struct TriggerActions: Codable, Equatable {
    public var displayOn: DeviceAction
    public var displayOff: DeviceAction
    public var powerOff: DeviceAction

    public init(
        displayOn: DeviceAction = .on,
        displayOff: DeviceAction = .off,
        powerOff: DeviceAction = .off
    ) {
        self.displayOn = displayOn
        self.displayOff = displayOff
        self.powerOff = powerOff
    }

    public func action(for trigger: PowerTrigger) -> DeviceAction {
        switch trigger {
        case .displayOn:
            return displayOn
        case .displayOff:
            return displayOff
        case .powerOff:
            return powerOff
        }
    }

    public mutating func set(_ action: DeviceAction, for trigger: PowerTrigger) {
        switch trigger {
        case .displayOn:
            displayOn = action
        case .displayOff:
            displayOff = action
        case .powerOff:
            powerOff = action
        }
    }
}

public struct ShortcutDevice: Codable, Equatable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var onShortcut: String
    public var offShortcut: String
    public var actions: TriggerActions

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        onShortcut: String,
        offShortcut: String,
        actions: TriggerActions = TriggerActions()
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.onShortcut = onShortcut
        self.offShortcut = offShortcut
        self.actions = actions
    }

    public func shortcutName(for action: DeviceAction) -> String? {
        switch action {
        case .none:
            return nil
        case .on:
            return onShortcut
        case .off:
            return offShortcut
        }
    }
}

public struct VirtConnectorConfig: Codable, Equatable {
    public var enabled: Bool
    public var devices: [ShortcutDevice]

    public init(
        enabled: Bool = true,
        devices: [ShortcutDevice] = []
    ) {
        self.enabled = enabled
        self.devices = devices
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, devices
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Legacy configurations omitted only the top-level enabled flag.
        enabled = values.contains(.enabled) ? try values.decode(Bool.self, forKey: .enabled) : true
        devices = try values.decode([ShortcutDevice].self, forKey: .devices)
    }

    public static let sampleDevice = ShortcutDevice(
        name: "LED Strip",
        onShortcut: "TurnOnLED",
        offShortcut: "TurnOffLED"
    )
}
