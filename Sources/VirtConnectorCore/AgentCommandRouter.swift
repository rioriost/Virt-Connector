import Foundation

public struct AgentCommandRouter {
    private let configStore: ConfigStore
    private let executor: ActionExecutor
    private let shutdownPerformer: ShutdownPerformer
    private let client: any AgentRequestSending
    private let isAgentLoaded: () throws -> Bool
    private let ownershipURL: URL

    public init(
        configStore: ConfigStore = ConfigStore(),
        executor: ActionExecutor = ActionExecutor(),
        shutdownPerformer: ShutdownPerformer? = nil,
        client: any AgentRequestSending = AgentIPCClient(),
        isAgentLoaded: @escaping () throws -> Bool = { try LaunchAgentManager().isLoaded() },
        ownershipURL: URL = AgentOwnershipLock.defaultURL
    ) {
        self.configStore = configStore
        self.executor = executor
        self.shutdownPerformer = shutdownPerformer ?? ShutdownPerformer(configStore: configStore, actionExecutor: executor)
        self.client = client
        self.isAgentLoaded = isAgentLoaded
        self.ownershipURL = ownershipURL
    }

    public func run(_ trigger: PowerTrigger) throws -> ActionExecutionResult {
        try route(.run, trigger: trigger) {
            let config = try configStore.load()
            let result = executor.execute(trigger: trigger, config: config)
            try result.requireSuccess()
            return result
        }
    }

    public func shutdown() throws -> ActionExecutionResult {
        try route(.shutdown) { try shutdownPerformer.perform() }
    }

    public func resume() throws {
        guard try isAgentLoaded() else {
            throw AgentCommunicationError("The agent is not loaded. Run 'virt-connector enable' to start monitoring.")
        }
        _ = try client.send(AgentRequest(command: .resume, configURL: configStore.configURL))
    }

    private func route(
        _ command: AgentRequest.Command,
        trigger: PowerTrigger? = nil,
        standalone: () throws -> ActionExecutionResult
    ) throws -> ActionExecutionResult {
        let request = AgentRequest(command: command, configURL: configStore.configURL, trigger: trigger)
        if try isAgentLoaded() {
            return try client.send(request)
        }
        let ownership = AgentOwnershipLock(url: ownershipURL)
        guard try ownership.acquire() else {
            return try client.send(request)
        }
        return try withExtendedLifetime(ownership) { try standalone() }
    }
}
