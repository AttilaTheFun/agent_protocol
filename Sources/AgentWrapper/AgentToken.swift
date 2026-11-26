import Foundation
import GRPCCore
import Synchronization

/// The agent's token (Job.token, which its runner hands over on
/// AGENT_TOKEN_FD or in AGENT_TOKEN_FILE; TokenHandover): shown on each call the wrapper makes for the agent, to its
/// driver and its dispatcher, as metadata `authorization: Bearer <token>`.
/// The driver may send a fresh one before it expires (DriverMessage.token):
/// it is shown from then on. Empty: nothing is shown.
public final class AgentToken: Sendable {
    /// The metadata's key.
    public static let metadataKey = "authorization"

    private let held: Mutex<String>

    public init(_ token: String = "") {
        held = Mutex(token)
    }

    public var value: String {
        held.withLock { $0 }
    }

    /// A fresh token, from the driver: an empty one is ignored.
    public func replace(with fresh: String) {
        guard !fresh.isEmpty else { return }
        held.withLock { $0 = fresh }
    }

    /// The handover's variables (AGENT_TOKEN_FD, AGENT_TOKEN_FILE and the
    /// deprecated AGENT_TOKEN) unset in the wrapper's own process, once
    /// WrapperOptions has read them, so no child the wrapper starts (the
    /// harness, git, a tool) inherits them, whatever environment it is
    /// started with.
    ///
    /// Unsetting hides nothing from a process that reads the wrapper's
    /// environment as it began (/proc/<wrapper>/environ, `ps -E`): only a
    /// handover outside the environment does (TokenHandover), with, on
    /// Linux, the process undumpable.
    public static func removeFromEnvironment() {
        for variable in TokenHandover.variables { unsetenv(variable) }
    }

    /// The metadata a call carries: the token, or nothing.
    public var metadata: Metadata {
        let token = value
        var metadata = Metadata()
        if !token.isEmpty { metadata.addString("Bearer \(token)", forKey: Self.metadataKey) }
        return metadata
    }
}
