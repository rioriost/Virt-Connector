import Foundation
import XCTest
@testable import VirtConnectorCore

func makeConfigTestDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(".build/config-tests/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

final class ConfigStoreTests: XCTestCase {
    func testMissingConfigurationRequiresExplicitDefaultsAndDoesNotWrite() throws {
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let store = ConfigStore(configURL: url)
        XCTAssertThrowsError(try store.load()) { error in
            guard case ConfigStoreError.fileNotFound(let path) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, url)
        }
        XCTAssertEqual(try store.loadOrDefault(), VirtConnectorConfig())
        XCTAssertFalse(store.shouldRestoreAgent())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let created = try store.ensureDefaultConfig()
        XCTAssertEqual(created.devices, [VirtConnectorConfig.sampleDevice])
        XCTAssertEqual(try store.load(), created)
    }

    func testInvalidConfigurationsNeverDefaultOrRewrite() throws {
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let store = ConfigStore(configURL: url)
        for json in [
            "{", "[]", "{}", #"{"enabled":true}"#,
            #"{"devices":null}"#, #"{"devices":"invalid"}"#,
            #"{"enabled":null,"devices":[]}"#, #"{"enabled":"true","devices":[]}"#,
            #"{"devices":[{}]}"#
        ] {
            let data = Data(json.utf8)
            try data.write(to: url)
            XCTAssertThrowsError(try store.load(), json)
            XCTAssertThrowsError(try store.loadOrDefault(), json) { error in
                XCTAssertTrue(error.localizedDescription.contains(url.path))
            }
            XCTAssertThrowsError(try store.ensureDefaultConfig(), json)
            XCTAssertFalse(store.shouldRestoreAgent(), json)
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testUnreadableFileNeverDefaultsOrRewrites() throws {
        guard getuid() != 0 else { throw XCTSkip("Root can read mode-000 files") }
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let data = Data(#"{"enabled":true,"devices":[]}"#.utf8)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        let store = ConfigStore(configURL: url)
        XCTAssertThrowsError(try store.loadOrDefault())
        XCTAssertThrowsError(try store.ensureDefaultConfig())
        XCTAssertFalse(store.shouldRestoreAgent())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testDirectoryIsNotTreatedAsMissingConfiguration() throws {
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(configURL: directory)
        XCTAssertThrowsError(try store.loadOrDefault())
        XCTAssertThrowsError(try store.ensureDefaultConfig())
        XCTAssertFalse(store.shouldRestoreAgent())
    }

    func testLegacyEnabledDefaultUsesFullRuntimeDecoderWithoutWrites() throws {
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let device = ShortcutDevice(
            name: "Legacy", enabled: false, onShortcut: "On", offShortcut: "Off",
            actions: TriggerActions(displayOn: .none, displayOff: .on, powerOff: .off)
        )
        let encoded = try JSONEncoder().encode(VirtConnectorConfig(devices: [device]))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "enabled")
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url)
        let store = ConfigStore(configURL: url)
        XCTAssertEqual(try store.load(), VirtConnectorConfig(enabled: true, devices: [device]))
        XCTAssertTrue(store.shouldRestoreAgent())
        XCTAssertEqual(try Data(contentsOf: url), data)

        var invalidDevice = try XCTUnwrap((object["devices"] as? [[String: Any]])?.first)
        invalidDevice.removeValue(forKey: "actions")
        object["devices"] = [invalidDevice]
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertFalse(store.shouldRestoreAgent())
    }

    func testExistingDisabledEmptyConfigurationIsPreserved() throws {
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(configURL: directory.appendingPathComponent("config.json"))
        let config = VirtConnectorConfig(enabled: false)
        try store.save(config)
        XCTAssertEqual(try store.ensureDefaultConfig(), config)
        XCTAssertEqual(try store.loadOrDefault(), config)
        XCTAssertFalse(store.shouldRestoreAgent())
    }
}
