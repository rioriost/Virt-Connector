import Foundation

public struct AgentRequest: Codable {
    public enum Command: String, Codable { case run, shutdown, resume }
    public let command: Command
    public let configPath: String
    public let trigger: PowerTrigger?

    public init(command: Command, configURL: URL, trigger: PowerTrigger? = nil) {
        self.command = command
        configPath = configURL.standardizedFileURL.resolvingSymlinksInPath().path
        self.trigger = trigger
    }
}

public struct AgentReply: Codable {
    public let result: ActionExecutionResult?
    public let error: String?

    public init(result: ActionExecutionResult? = nil, error: String? = nil) {
        self.result = result
        self.error = error
    }
}

public struct AgentCommunicationError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

@objc public protocol AgentRemoteProtocol {
    func send(_ request: Data, reply: @escaping (Data) -> Void)
}

public protocol AgentRequestSending {
    func send(_ request: AgentRequest) throws -> ActionExecutionResult
}

public final class AgentIPCServer: NSObject, NSXPCListenerDelegate, AgentRemoteProtocol {
    private let listener: NSXPCListener
    private let coordinator: PowerEventCoordinator
    private let configPath: String
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NSXPCConnection] = [:]

    public init(
        coordinator: PowerEventCoordinator,
        configURL: URL,
        listener: NSXPCListener = NSXPCListener(machServiceName: LaunchAgentManager.label)
    ) {
        self.coordinator = coordinator
        configPath = configURL.standardizedFileURL.resolvingSymlinksInPath().path
        self.listener = listener
        super.init()
        listener.delegate = self
    }

    public func start() { listener.resume() }

    public func stop() {
        listener.invalidate()
        lock.lock()
        let active = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        active.forEach { $0.invalidate() }
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        connection.exportedInterface = NSXPCInterface(with: AgentRemoteProtocol.self)
        connection.exportedObject = self
        let identifier = ObjectIdentifier(connection)
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.connections.removeValue(forKey: identifier)
            self.lock.unlock()
        }
        lock.lock()
        connections[identifier] = connection
        lock.unlock()
        connection.resume()
        return true
    }

    public func send(_ data: Data, reply: @escaping (Data) -> Void) {
        let complete: PowerEventCoordinator.Completion = { result in
            let response: AgentReply
            switch result {
            case .success(let value): response = AgentReply(result: value)
            case .failure(let error): response = AgentReply(error: error.localizedDescription)
            }
            do {
                reply(try JSONEncoder().encode(response))
            } catch {
                reply(Data(#"{"error":"Could not encode the agent response"}"#.utf8))
            }
        }
        do {
            let request = try JSONDecoder().decode(AgentRequest.self, from: data)
            guard request.configPath == configPath else {
                throw AgentCommunicationError(
                    "The running agent uses a different configuration. Reinstall the agent with the intended configuration path."
                )
            }
            switch request.command {
            case .run:
                guard let trigger = request.trigger else {
                    throw AgentCommunicationError("A run request requires a trigger.")
                }
                coordinator.run(trigger, completion: complete)
            case .shutdown:
                guard request.trigger == nil else {
                    throw AgentCommunicationError("A shutdown request must not include a trigger.")
                }
                coordinator.shutdown(completion: complete)
            case .resume:
                guard request.trigger == nil else {
                    throw AgentCommunicationError("A resume request must not include a trigger.")
                }
                try coordinator.resumeAfterCancelledShutdown()
                complete(.success(ActionExecutionResult()))
            }
        } catch {
            complete(.failure(error))
        }
    }
}

public struct AgentIPCClient: AgentRequestSending {
    private let timeout: TimeInterval
    private let makeConnection: () -> NSXPCConnection

    public init(
        timeout: TimeInterval = 250,
        makeConnection: @escaping () -> NSXPCConnection = {
            NSXPCConnection(machServiceName: LaunchAgentManager.label)
        }
    ) {
        self.timeout = timeout
        self.makeConnection = makeConnection
    }

    public func send(_ request: AgentRequest) throws -> ActionExecutionResult {
        let data = try JSONEncoder().encode(request)
        let connection = makeConnection()
        connection.remoteObjectInterface = NSXPCInterface(with: AgentRemoteProtocol.self)
        let pending = PendingAgentReply()
        connection.interruptionHandler = {
            pending.complete(.failure(AgentCommunicationError("The agent connection was interrupted; the operation may have started. Check the agent before retrying.")))
        }
        connection.invalidationHandler = {
            pending.complete(.failure(AgentCommunicationError("The agent connection was invalidated; the operation may have started. Check the agent before retrying.")))
        }
        connection.resume()
        defer { connection.invalidate() }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            pending.complete(.failure(AgentCommunicationError(
                "Could not contact the agent: \(error.localizedDescription). No standalone retry was attempted."
            )))
        }) as? AgentRemoteProtocol else {
            throw AgentCommunicationError("The agent does not support the command interface.")
        }
        proxy.send(data) { data in
            pending.complete(Result { try JSONDecoder().decode(AgentReply.self, from: data) })
        }
        guard pending.semaphore.wait(timeout: .now() + timeout) == .success else {
            throw AgentCommunicationError("Timed out waiting for the agent. The operation may still be running; no standalone retry was attempted.")
        }
        let response = try pending.value()
        if let error = response.error { throw AgentCommunicationError(error) }
        guard let result = response.result else { throw AgentCommunicationError("The agent returned an empty response.") }
        try result.requireSuccess()
        return result
    }
}

private final class PendingAgentReply {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var response: Result<AgentReply, Error>?

    func complete(_ result: Result<AgentReply, Error>) {
        lock.lock()
        guard response == nil else { lock.unlock(); return }
        response = result
        lock.unlock()
        semaphore.signal()
    }

    func value() throws -> AgentReply {
        lock.lock()
        defer { lock.unlock() }
        guard let response else { throw AgentCommunicationError("The agent did not return a response.") }
        return try response.get()
    }
}
