import Foundation

public enum CoordinationError: LocalizedError {
    case shutdownInProgress
    case noPendingShutdown
    case agentStopping

    public var errorDescription: String? {
        switch self {
        case .shutdownInProgress:
            return "Shutdown is in progress; device actions cannot be started."
        case .noPendingShutdown:
            return "There is no completed shutdown request to resume from."
        case .agentStopping:
            return "The agent is stopping; no additional device actions will be started."
        }
    }
}

public final class PowerEventCoordinator {
    public typealias Completion = (Result<ActionExecutionResult, Error>) -> Void

    private enum State {
        case running, preparing, requestingShutdown, shutdownRequested, stopping
    }

    private let queue = DispatchQueue(label: "st.rio.virt-connectord.actions", qos: .userInitiated)
    private let lock = NSLock()
    private let execute: (PowerTrigger) throws -> ActionExecutionResult
    private let requestOSShutdown: () throws -> Void
    private let log: (String) -> Void
    private let stateChanged: () -> Void
    private var state = State.running
    private var shutdownResult: ActionExecutionResult?
    private var completions: [Completion] = []
    private var terminationWaiters: [() -> Void] = []
    private var lastDisplayEvent: (PowerTrigger, TimeInterval)?

    public init(
        execute: @escaping (PowerTrigger) throws -> ActionExecutionResult,
        requestShutdown: @escaping () throws -> Void,
        log: @escaping (String) -> Void = { _ in },
        stateChanged: @escaping () -> Void = {}
    ) {
        self.execute = execute
        self.requestOSShutdown = requestShutdown
        self.log = log
        self.stateChanged = stateChanged
    }

    public var canResume: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .shutdownRequested
    }

    public var isShutdownPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state != .running
    }

    public func handleDisplayEvent(_ trigger: PowerTrigger, reason: String) {
        precondition(trigger != .powerOff)
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        guard state == .running else {
            lock.unlock()
            log("Skipping \(trigger.rawValue) during shutdown")
            return
        }
        if let lastDisplayEvent, lastDisplayEvent.0 == trigger, now - lastDisplayEvent.1 < 2 {
            lock.unlock()
            log("Skipping duplicate \(trigger.rawValue) from \(reason)")
            return
        }
        lastDisplayEvent = (trigger, now)
        lock.unlock()
        run(trigger) { [log] result in
            if case .failure(let error) = result {
                log("Event \(trigger.rawValue) from \(reason) failed: \(error.localizedDescription)")
            }
        }
    }

    public func run(_ trigger: PowerTrigger, completion: @escaping Completion) {
        queue.async {
            self.lock.lock()
            let permitted = self.state == .running
            self.lock.unlock()
            guard permitted else {
                completion(.failure(CoordinationError.shutdownInProgress))
                return
            }
            completion(Result {
                let result = try self.execute(trigger)
                try result.requireSuccess()
                return result
            })
        }
    }

    public func shutdown(requestSystemShutdown: Bool = true, completion: @escaping Completion) {
        lock.lock()
        switch state {
        case .stopping:
            lock.unlock()
            completion(.failure(CoordinationError.agentStopping))
            return
        case .running:
            state = .preparing
            completions.append(completion)
            lock.unlock()
        case .preparing, .requestingShutdown:
            completions.append(completion)
            lock.unlock()
            return
        case .shutdownRequested:
            guard let result = shutdownResult else {
                lock.unlock()
                completion(.failure(AgentCommunicationError("The completed shutdown result is unavailable.")))
                return
            }
            lock.unlock()
            completion(.success(result))
            return
        }

        stateChanged()
        queue.async {
            do {
                self.lock.lock()
                let stopping = self.state == .stopping
                self.lock.unlock()
                guard !stopping else { throw CoordinationError.agentStopping }
                let result = try self.execute(.powerOff)
                try result.requireSuccess()
                self.lock.lock()
                guard self.state != .stopping else {
                    self.lock.unlock()
                    throw CoordinationError.agentStopping
                }
                self.shutdownResult = result
                self.state = .requestingShutdown
                let waiters = self.terminationWaiters
                self.terminationWaiters = []
                self.lock.unlock()
                // loginwindow must not wait for the osascript that requested termination.
                waiters.forEach { $0() }
                if requestSystemShutdown {
                    try self.requestOSShutdown()
                }
                self.finishShutdown(.success(result))
            } catch {
                self.finishShutdown(.failure(error))
            }
        }
    }

    public func whenReadyToTerminate(_ completion: @escaping () -> Void) {
        lock.lock()
        if state == .preparing {
            terminationWaiters.append(completion)
            lock.unlock()
        } else {
            lock.unlock()
            completion()
        }
    }

    public func stop(completion: @escaping () -> Void) {
        lock.lock()
        state = .stopping
        lock.unlock()
        stateChanged()
        queue.async { completion() }
    }

    public func resumeAfterCancelledShutdown() throws {
        lock.lock()
        guard state == .shutdownRequested else {
            let error: CoordinationError = state == .running ? .noPendingShutdown : .shutdownInProgress
            lock.unlock()
            throw error
        }
        state = .running
        shutdownResult = nil
        lastDisplayEvent = nil
        lock.unlock()
        log("Resumed monitoring after a canceled system shutdown")
        stateChanged()
    }

    private func finishShutdown(_ result: Result<ActionExecutionResult, Error>) {
        lock.lock()
        let callbacks = completions
        completions = []
        let waiters = terminationWaiters
        terminationWaiters = []
        if state != .stopping {
            switch result {
            case .success:
                state = .shutdownRequested
            case .failure:
                state = .running
                shutdownResult = nil
                lastDisplayEvent = nil
            }
        }
        lock.unlock()
        if case .failure(let error) = result {
            log("Shutdown failed: \(error.localizedDescription)")
        }
        stateChanged()
        waiters.forEach { $0() }
        callbacks.forEach { $0(result) }
    }
}
