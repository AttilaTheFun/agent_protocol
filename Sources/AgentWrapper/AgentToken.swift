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

    /// The metadata a call carries: the token, or nothing.
    public var metadata: Metadata {
        let token = value
        var metadata = Metadata()
        if !token.isEmpty { metadata.addString("Bearer \(token)", forKey: Self.metadataKey) }
        return metadata
    }
}
