// What answers the queries a DNSServer takes: agent-proxy's forwarder (which
// conforms in agent-proxy), or agent-network's resolver in a container
// (fake addresses for names it relays, the rest asked of agent-proxy).

/// Answers DNS queries.
public protocol DNSAnswering: Sendable {
    /// The answer to `query`, under its id; nil to drop it.
    func answer(_ query: DNSMessage) async -> DNSMessage?
}
