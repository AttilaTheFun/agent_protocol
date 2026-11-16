import Foundation
import GRPCCore
import Synchronization

/// The agent's token (Job.token, which its runner hands over in
/// AGENT_TOKEN): shown on each call the wrapper makes for the agent, to its
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

    /// AGENT_TOKEN unset in the wrapper's own process, once WrapperOptions
    /// has read it, so no child the wrapper starts (the harness, git, a
    /// tool) inherits it, whatever environment it is started with.
    ///
    /// This doesn't hide it from the harness. On Linux, unsetenv changes
    /// only the C library's copy of the environment: /proc/<wrapper>/environ
    /// is the block the kernel was given at exec, and still shows the token
    /// (checked in visor-agent 0.58). The harness runs as the same user, so
    /// it can read that, and the wrapper's memory, if it looks. The token
    /// is not handed to the harness; it is not a secret from it.
    public static func removeFromEnvironment() {
        unsetenv("AGENT_TOKEN")
    }

    /// The metadata a call carries: the token, or nothing.
    public var metadata: Metadata {
        let token = value
        var metadata = Metadata()
        if !token.isEmpty { metadata.addString("Bearer \(token)", forKey: Self.metadataKey) }
        return metadata
    }
}
