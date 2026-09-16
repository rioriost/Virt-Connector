import Foundation
import XCTest
@testable import VirtConnectorCore

final class AgentRestoreTests: XCTestCase {
    func testUpgradeRequiresAnExistingEnabledConfiguration() throws {
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let store = ConfigStore(configURL: url)

        XCTAssertFalse(store.shouldRestoreAgent())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        for (json, expected) in [
            (#"{"enabled":true,"devices":[]}"#, true),
            (#"{"enabled":false,"devices":[]}"#, false),
            (#"{"devices":[]}"#, true),
            (#"{"enabled":true}"#, false),
            (#"{"enabled":true,"devices":"invalid"}"#, false),
            (#"{"enabled":true,"devices":[{}]}"#, false),
            (#"{}"#, false),
            (#"{"enabled":null}"#, false),
            (#"{"enabled":"false"}"#, false),
            (#"{"enabled":0}"#, false),
            (#"[]"#, false),
            (#"{"enabled":"#, false)
        ] {
            let data = Data(json.utf8)
            try data.write(to: url)
            XCTAssertEqual(store.shouldRestoreAgent(), expected, json)
            XCTAssertEqual(try Data(contentsOf: url), data, "Upgrade checks must not modify settings")
        }
    }

    func testAgentInstallationUsesExplicitUserDirectories() throws {
        let directory = try makeConfigTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plist = directory.appendingPathComponent("LaunchAgents/test.plist")
        let logs = directory.appendingPathComponent("Logs")
        let config = directory.appendingPathComponent(".config/virt-connector/config.json")
        let manager = LaunchAgentManager(plistURL: plist, logDirectory: logs, configURL: config)
        try manager.install(daemonPath: "/Library/VirtConnector/VirtConnectorAgent.app/Contents/MacOS/virt-connectord")
        let data = try Data(contentsOf: plist)
        let contents = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(contents["StandardOutPath"] as? String, logs.appendingPathComponent("virt-connectord.out.log").path)
        XCTAssertEqual(contents["StandardErrorPath"] as? String, logs.appendingPathComponent("virt-connectord.err.log").path)
        XCTAssertEqual(contents["Label"] as? String, LaunchAgentManager.label)
        let environment = try XCTUnwrap(contents["EnvironmentVariables"] as? [String: String])
        XCTAssertEqual(environment["VIRT_CONNECTOR_CONFIG"], config.path)
        XCTAssertEqual(environment["VIRT_CONNECTOR_LOG_DIR"], logs.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: logs.path))
    }
}
