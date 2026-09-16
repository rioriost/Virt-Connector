import Foundation
import XCTest
@testable import VirtConnectorCore

final class AgentIPCTests: XCTestCase {
    func testAnonymousXPCTransportsCommandsAndRejectsDifferentConfiguration() {
        let config = URL(fileURLWithPath: "/test/config.json")
        let actions = LockedValues<PowerTrigger>()
        let osCalls = LockedValues<Bool>()
        let coordinator = PowerEventCoordinator(
            execute: { actions.append($0); return ActionExecutionResult(attempted: 1) },
            requestShutdown: { osCalls.append(true) }
        )
        let listener = NSXPCListener.anonymous()
        let server = AgentIPCServer(coordinator: coordinator, configURL: config, listener: listener)
        server.start()
        defer { server.stop() }
        let client = AgentIPCClient(timeout: 3, makeConnection: {
            NSXPCConnection(listenerEndpoint: listener.endpoint)
        })
        let finished = expectation(description: "XPC requests")
        DispatchQueue.global().async {
            do {
                XCTAssertEqual(try client.send(AgentRequest(command: .run, configURL: config, trigger: .displayOn)).attempted, 1)
                XCTAssertThrowsError(try client.send(AgentRequest(command: .run, configURL: URL(fileURLWithPath: "/other.json"), trigger: .displayOn)))
                _ = try client.send(AgentRequest(command: .shutdown, configURL: config))
                _ = try client.send(AgentRequest(command: .shutdown, configURL: config))
                XCTAssertThrowsError(try client.send(AgentRequest(command: .run, configURL: config, trigger: .displayOn)))
                _ = try client.send(AgentRequest(command: .resume, configURL: config))
                _ = try client.send(AgentRequest(command: .run, configURL: config, trigger: .displayOff))
            } catch {
                XCTFail(error.localizedDescription)
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(actions.values, [.displayOn, .powerOff, .displayOff])
        XCTAssertEqual(osCalls.values.count, 1)
    }

    func testLoadedAgentFailureNeverFallsBackToStandaloneExecution() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(configURL: directory.appendingPathComponent("config.json"))
        try store.save(VirtConnectorConfig(devices: [VirtConnectorConfig.sampleDevice]))
        let process = RecordingProcessRunner()
        let client = FailingAgentClient()
        let router = AgentCommandRouter(
            configStore: store, executor: ActionExecutor(shortcutRunner: ShortcutRunner(processRunner: process)),
            client: client, isAgentLoaded: { true }, ownershipURL: directory.appendingPathComponent("lock")
        )
        XCTAssertThrowsError(try router.run(.powerOff))
        XCTAssertEqual(client.requests.values.count, 1)
        XCTAssertTrue(process.calls.isEmpty)
    }

    func testXPCResponseTimeoutDoesNotRepeatAnAcceptedOperation() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let calls = LockedValues<PowerTrigger>()
        let actionFinished = expectation(description: "accepted action eventually finished")
        let coordinator = PowerEventCoordinator(execute: { trigger in
            calls.append(trigger)
            entered.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
            actionFinished.fulfill()
            return ActionExecutionResult()
        }, requestShutdown: { XCTFail("not a shutdown request") })
        let listener = NSXPCListener.anonymous()
        let config = URL(fileURLWithPath: "/test/config.json")
        let server = AgentIPCServer(coordinator: coordinator, configURL: config, listener: listener)
        server.start()
        defer { server.stop() }
        let client = AgentIPCClient(timeout: 0.1, makeConnection: {
            NSXPCConnection(listenerEndpoint: listener.endpoint)
        })
        let timedOut = expectation(description: "caller receives timeout")
        DispatchQueue.global().async {
            do {
                _ = try client.send(AgentRequest(command: .run, configURL: config, trigger: .powerOff))
                XCTFail("must time out")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Timed out"))
            }
            timedOut.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        wait(for: [timedOut], timeout: 2)
        release.signal()
        wait(for: [actionFinished], timeout: 2)
        XCTAssertEqual(calls.values, [.powerOff])
    }

    func testInvalidShutdownRequestDoesNotExecuteActions() throws {
        let coordinator = PowerEventCoordinator(
            execute: { _ in XCTFail("must not execute"); return ActionExecutionResult() },
            requestShutdown: { XCTFail("must not shut down") }
        )
        let config = URL(fileURLWithPath: "/test/config.json")
        let server = AgentIPCServer(coordinator: coordinator, configURL: config, listener: .anonymous())
        let request = AgentRequest(command: .shutdown, configURL: config, trigger: .displayOn)
        let rejected = expectation(description: "invalid request")
        server.send(try JSONEncoder().encode(request)) { data in
            do {
                let response = try JSONDecoder().decode(AgentReply.self, from: data)
                XCTAssertNotNil(response.error)
                XCTAssertNil(response.result)
            } catch {
                XCTFail(error.localizedDescription)
            }
            rejected.fulfill()
        }
        wait(for: [rejected], timeout: 2)
    }

    func testOwnershipLockPreventsConcurrentStandaloneExecution() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("ownership.lock")
        let owner = AgentOwnershipLock(url: lockURL)
        XCTAssertTrue(try owner.acquire())
        let contender = AgentOwnershipLock(url: lockURL)
        XCTAssertFalse(try contender.acquire())
        let client = FailingAgentClient()
        let router = AgentCommandRouter(
            configStore: ConfigStore(configURL: directory.appendingPathComponent("absent.json")),
            client: client, isAgentLoaded: { false }, ownershipURL: lockURL
        )
        XCTAssertThrowsError(try router.shutdown())
        XCTAssertEqual(client.requests.values.count, 1)
        withExtendedLifetime(owner) {}
    }
}

private final class FailingAgentClient: AgentRequestSending {
    let requests = LockedValues<AgentRequest>()
    func send(_ request: AgentRequest) throws -> ActionExecutionResult {
        requests.append(request)
        throw AgentCommunicationError("simulated connection timeout")
    }
}
