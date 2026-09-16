import Foundation

public enum ConfigStoreError: LocalizedError {
    case fileNotFound(URL)
    case loadFailed(URL, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "Configuration not found at \(url.path); run setup or device add first."
        case let .loadFailed(url, error):
            return "Could not load configuration at \(url.path): \(error.localizedDescription)"
        }
    }
}

public final class ConfigStore {
    public let configURL: URL

    public init(configURL: URL = ConfigStore.defaultConfigURL()) {
        self.configURL = configURL.standardizedFileURL
    }

    public static func defaultConfigURL() -> URL {
        if let path = ProcessInfo.processInfo.environment["VIRT_CONNECTOR_CONFIG"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("virt-connector", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    public static func logsDirectoryURL() -> URL {
        if let path = ProcessInfo.processInfo.environment["VIRT_CONNECTOR_LOG_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
    }

    public static func launchAgentsDirectoryURL() -> URL {
        if let path = ProcessInfo.processInfo.environment["VIRT_CONNECTOR_LAUNCH_AGENTS_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
    }

    public func load() throws -> VirtConnectorConfig {
        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            let nsError = error as NSError
            if (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError)
                || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT)) {
                throw ConfigStoreError.fileNotFound(configURL)
            }
            throw ConfigStoreError.loadFailed(configURL, underlying: error)
        }
        do {
            return try JSONDecoder().decode(VirtConnectorConfig.self, from: data)
        } catch {
            throw ConfigStoreError.loadFailed(configURL, underlying: error)
        }
    }

    /// Only initial-creation commands may opt into defaults for a missing file.
    public func loadOrDefault() throws -> VirtConnectorConfig {
        do {
            return try load()
        } catch ConfigStoreError.fileNotFound {
            return VirtConnectorConfig()
        }
    }

    /// Upgrade hooks must not create a configuration or enable disabled monitoring.
    public func shouldRestoreAgent() -> Bool {
        (try? load().enabled) ?? false
    }

    public func save(_ config: VirtConnectorConfig) throws {
        let directory = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: configURL, options: [.atomic])
    }

    public func ensureDefaultConfig() throws -> VirtConnectorConfig {
        do {
            return try load()
        } catch ConfigStoreError.fileNotFound {
            let config = VirtConnectorConfig(devices: [VirtConnectorConfig.sampleDevice])
            try save(config)
            return config
        }
    }
}
