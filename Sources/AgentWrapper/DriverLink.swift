import AgentProtocol
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

/// The wrapper's line to its driver (AGENT_DRIVER_URL): dialled out, kept
/// open, dialled again after a drop, until the agent ends. On each
/// connection it says who it is, then everything the agent has said and is
/// doing, then what changes; and it takes what the driver sends (messages,
/// an interrupt, a stop, a hand-back, a fresh token). Each connection shows
/// the agent's token as it is then (AgentToken). With a relay, the agent's
/// MCP server's messages and its approvals go up too, and their answers
/// come down to it.
///
/// A hand-back (DriverMessage.hand_back) ends the agent as a stop does,
/// then, once its harness has ended, sends its conversation up from
/// `claudeFolder` (ConversationReturn, AgentDriver.ReturnConversation)
/// before its end is told. A return that fails (a driver that doesn't
/// implement it, the network) is logged, and the agent ends anyway.
public struct DriverLink: Sendable {
    /// What the wrapper understands (WrapperHello.protocol): 2, the
    /// hand-back too.
    public static let protocolVersion: Int32 = 2

    public let host: String
    public let port: Int
    let url: String
    let core: AgentCore
    let hostName: String
    let token: AgentToken
    let relay: MCPRelay?
    let claudeFolder: URL
    let log: @Sendable (String) -> Void

    /// Nil for an address that isn't `http://host:port`.
    public init?(url: String, core: AgentCore, hostName: String, token: AgentToken = AgentToken(), relay: MCPRelay? = nil,
                 claudeFolder: URL = ResumePreparation.claudeFolder(), log: @escaping @Sendable (String) -> Void = { _ in }) {
        guard let components = URLComponents(string: url), components.scheme == "http", let host = components.host, !host.isEmpty
        else { return nil }
        self.host = host
        port = components.port ?? 80
        self.url = url
        self.core = core
        self.hostName = hostName
        self.token = token
        self.relay = relay
        self.claudeFolder = claudeFolder
        self.log = log
    }

    /// Connected, and again after each drop (1 s, doubling to 30 s
    /// between tries), until the agent ends.
    public func run() async {
        var pause: Duration = .seconds(1)
        while !Task.isCancelled {
            let ended = await core.attach().ended
            if ended != nil { return }
            do {
                try await connectOnce()
                pause = .seconds(1)
            } catch {
                log("driver \(host):\(port): \(error)")
            }
            if await core.attach().ended != nil { return }
            try? await Task.sleep(for: pause)
            pause = min(pause * 2, .seconds(30))
        }
    }

    private func connectOnce() async throws {
        let transport = try HTTP2ClientTransport.Posix(target: .dns(host: host, port: port), transportSecurity: .plaintext)
        let core = self.core
        let hello = await helloMessage()
        let log = self.log
        let token = self.token
        let relay = self.relay
        let link = self
        try await withGRPCClient(transport: transport) { client in
            let driver = AgentProtocol_V1_AgentDriver.Client(wrapping: client)
            try await driver.connect(metadata: token.metadata, requestProducer: { writer in
                let (rows, state, sessionID, ended, changes) = await core.attach()
                var first = hello
                first.sessionID = sessionID
                try await writer.write(.with { $0.hello = first })
                if !rows.isEmpty { try await writer.write(.with { $0.entries = .with { $0.entries = rows } }) }
                try await writer.write(.with { $0.state = state })
                if let ended {
                    try await writer.write(.with { $0.ended = ended })
                    return
                }
                // What changes, and the relay's messages, in one line.
                let (outgoing, sending) = AsyncStream<AgentProtocol_V1_WrapperMessage>.makeStream()
                let telling = Task {
                    for await change in changes {
                        switch change {
                        case .entry(let row): sending.yield(.with { $0.entries = .with { $0.entries = [row] } })
                        case .state(let state): sending.yield(.with { $0.state = state })
                        case .sessionID(let id): sending.yield(.with { $0.sessionID = id })
                        case .ended(let why): sending.yield(.with { $0.ended = why })
                        }
                    }
                    sending.finish()
                }
                let relaying = Task {
                    guard let relay else { return }
                    for await message in await relay.driverConnected() { sending.yield(message) }
                }
                defer {
                    telling.cancel()
                    relaying.cancel()
                }
                for await message in outgoing { try await writer.write(message) }
            }, onResponse: { response in
                for try await message in response.messages {
                    switch message.message {
                    case .send(let send): await core.send(id: send.id.isEmpty ? UUID().uuidString.lowercased() : send.id, text: send.text)
                    case .stop: await core.stop()
                    case .handBack: await core.handBack { session in await link.returnConversation(sessionID: session) }
                    case .interrupt: await core.interrupt()
                    case .model(let change): log("driver: changing the model to \(change.model) isn't supported yet")
                    case .token(let fresh): token.replace(with: fresh)
                    case .mcp(let answer): await relay?.take(answer)
                    case .approval(let approval): await relay?.take(approval)
                    case .acknowledged, .none: break
                    }
                }
            })
        }
    }

    /// The ended harness's conversation, `sessionID`, up to the driver: the
    /// header alone when it has no session id. Logged, never thrown: the
    /// agent ends either way.
    func returnConversation(sessionID: String) async {
        let spec = core.spec
        let folder = spec.workingDirectory.isEmpty ? FileManager.default.currentDirectoryPath : spec.workingDirectory
        do {
            let ack = try await ConversationReturn.send(driverURL: url, agent: core.agent, harness: spec.harness, workingDirectory: folder,
                                                        sessionID: sessionID, token: token, from: claudeFolder)
            log("handed back \(sessionID.isEmpty ? "no session" : sessionID): the driver took \(ack.files) of its conversation's files")
        } catch {
            log("the conversation of \(sessionID.isEmpty ? "no session" : sessionID) wasn't returned: \(error)")
        }
    }

    private func helloMessage() async -> AgentProtocol_V1_WrapperMessage.OneOf_Message.Hello {
        var hello = AgentProtocol_V1_WrapperHello()
        hello.protocol = Self.protocolVersion
        hello.agent = core.agent
        hello.spec = core.spec
        hello.hostName = hostName
        return hello
    }
}

extension AgentProtocol_V1_WrapperMessage.OneOf_Message {
    public typealias Hello = AgentProtocol_V1_WrapperHello
}
