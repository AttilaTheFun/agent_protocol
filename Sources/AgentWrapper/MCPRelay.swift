import AgentProtocol
import Foundation

/// One of the agent's MCP connections (`agent-wrapper mcp`, which Claude
/// starts), as the relay answers it: a JSON-RPC message a line.
public protocol MCPClient: Sendable {
    func send(_ line: String)
}

/// The agent's MCP server, "visor", as the wrapper serves it: each message
/// from Claude's MCP client goes to the driver verbatim (WrapperMessage.mcp)
/// and the driver's answer (DriverMessage.mcp, the same id) comes back, so
/// the agent has the driver's tools (Visor's send_message, read_inbox,
/// list_sessions, …) as a session on the driver's own computer has them.
///
/// `approve`, Claude's permission prompt (`--permission-prompt-tool
/// mcp__visor__approve`), is the wrapper's own: added to the driver's
/// tools/list when the agent asks before acting, and each call to it asked
/// of the driver as an ApprovalRequest and answered by its Approval. The
/// driver never sees a tools/call for it.
///
/// A driver that doesn't serve MCP (an older one, which answers nothing):
/// an `initialize` it was sent and left unanswered (`Timing.answer`) is
/// answered here, with `approve` alone, and from then on its tool calls get
/// a JSON-RPC error and its approvals are denied, saying why. With no
/// driver at all the same, at once.
public actor MCPRelay {
    public struct Timing: Sendable {
        /// How long the driver has to answer a request that isn't a tool
        /// call (initialize, tools/list), or any request before it has
        /// answered one.
        public var answer: Duration
        /// How long a tool call may take, once the driver serves MCP.
        public var call: Duration
        /// How often an approval waiting on the person is said to be under
        /// way, when Claude takes progress.
        public var heartbeat: Duration
        /// How long an approval waits when Claude takes no progress, before
        /// it is denied as unanswered.
        public var unanswered: Duration

        public init(answer: Duration = .seconds(15), call: Duration = .seconds(15 * 60), heartbeat: Duration = .seconds(20),
                    unanswered: Duration = .seconds(25 * 60)) {
            self.answer = answer
            self.call = call
            self.heartbeat = heartbeat
            self.unanswered = unanswered
        }
    }

    /// Whether the wrapper has a driver (AGENT_DRIVER_URL) to relay to.
    public let hasDriver: Bool
    /// Whether the agent asks before acting (its spec's skip_permissions
    /// false): `approve` is offered.
    public let asksPermission: Bool
    private let timing: Timing
    private let log: @Sendable (String) -> Void

    /// Whether the driver serves MCP: nil until it answers (true), or
    /// leaves an initialize it was sent unanswered (false).
    public private(set) var driverServesMCP: Bool?

    private var clients: [String: any MCPClient] = [:]
    private var clientCount = 0
    /// The driver's stream, while connected, and how many there have been.
    private var link: (number: Int, continuation: AsyncStream<AgentProtocol_V1_WrapperMessage>.Continuation)?
    private var links = 0
    private var order = 0

    /// A request sent (or to be sent) to the driver, until it answers.
    private struct Forwarded {
        let order: Int
        let client: String
        /// Its JSON-RPC id, as JSON.
        let rpcID: String
        let method: String
        /// What is answered here when the driver doesn't (a result, as
        /// JSON), for the requests that have one.
        let fallback: String?
        let request: AgentProtocol_V1_McpRequest
        /// The driver connection it went on; nil while it waits for one.
        var sentOn: Int?
        var timer: Task<Void, Never>?
    }

    private var forwarded: [String: Forwarded] = [:]

    /// An `approve` call, until the driver answers it.
    private struct Asking {
        let order: Int
        let client: String
        let rpcID: String
        /// The tool's input as asked, a JSON object.
        let inputJSON: String
        let request: AgentProtocol_V1_ApprovalRequest
        var sentOn: Int?
        var tasks: [Task<Void, Never>] = []
    }

    private var asking: [String: Asking] = [:]

    public init(hasDriver: Bool, asksPermission: Bool, timing: Timing = Timing(), log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.hasDriver = hasDriver
        self.asksPermission = asksPermission
        self.timing = timing
        self.log = log
    }

    // MARK: - The agent's side

    /// A new MCP connection: its name ("1", "2", …), as its messages go to
    /// the driver (McpRequest.client).
    public func connected(_ client: any MCPClient) -> String {
        clientCount += 1
        let name = String(clientCount)
        clients[name] = client
        return name
    }

    /// The connection `name` closed: what it waited on is given up.
    public func disconnected(_ name: String) {
        clients[name] = nil
        for (id, entry) in forwarded where entry.client == name {
            entry.timer?.cancel()
            forwarded[id] = nil
        }
        for (id, entry) in asking where entry.client == name { withdraw(id) }
    }

    /// A line from the connection `name`: a request, a notification, or
    /// its answer to the server's own request.
    public func handle(_ line: String, from name: String) {
        guard let object = JSONText.object(line) else { return }
        let rpcID = object["id"].flatMap { $0 is NSNull ? nil : JSONText.encode($0) }
        guard let method = object["method"] as? String else {
            // The client's answer to something the driver's server asked.
            pass(line, from: name)
            return
        }
        let params = object["params"] as? [String: Any] ?? [:]
        guard let rpcID else {
            if method == "notifications/cancelled", let given = params["requestId"].flatMap(JSONText.encode) {
                if let approval = asking.first(where: { $0.value.client == name && $0.value.rpcID == given })?.key {
                    withdraw(approval)
                    return
                }
                for (id, entry) in forwarded where entry.client == name && entry.rpcID == given {
                    entry.timer?.cancel()
                    forwarded[id] = nil
                }
            }
            pass(line, from: name)
            return
        }
        if method == "tools/call", params["name"] as? String == "approve" {
            approve(rpcID: rpcID, params: params, client: name)
            return
        }
        forward(line, rpcID: rpcID, method: method, params: params, client: name)
    }

    /// A notification (or the client's answer): to the driver, when it is
    /// connected and may serve MCP; else nowhere.
    private func pass(_ line: String, from name: String) {
        guard hasDriver, driverServesMCP != false, let link else { return }
        link.continuation.yield(.with { $0.mcp = .with { $0.json = line; $0.client = name } })
    }

    private func forward(_ line: String, rpcID: String, method: String, params: [String: Any], client: String) {
        let fallback = Self.fallback(method: method, params: params, asksPermission: asksPermission)
        guard hasDriver else {
            return reply(client: client, rpcID: rpcID, fallback: fallback,
                         why: "This agent has no driver (AGENT_DRIVER_URL), so it has none of its tools.")
        }
        guard driverServesMCP != false else {
            return reply(client: client, rpcID: rpcID, fallback: fallback,
                         why: "The driver this agent runs under doesn't serve MCP, so its tools aren't here.")
        }
        order += 1
        let id = UUID().uuidString.lowercased()
        var entry = Forwarded(order: order, client: client, rpcID: rpcID, method: method, fallback: fallback,
                              request: .with { $0.id = id; $0.json = line; $0.client = client })
        if let link {
            link.continuation.yield(.with { $0.mcp = entry.request })
            entry.sentOn = link.number
        }
        let wait = method == "tools/call" && driverServesMCP == true ? timing.call : timing.answer
        entry.timer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            if !Task.isCancelled { await self?.unanswered(id, after: wait) }
        }
        forwarded[id] = entry
    }

    /// What a request is answered with here, when the driver can't: the
    /// handshake, a list of `approve` alone, a ping's nothing.
    static func fallback(method: String, params: [String: Any], asksPermission: Bool) -> String? {
        switch method {
        case "initialize":
            let version = (params["protocolVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "2024-11-05"
            return #"{"protocolVersion":\#(JSONText.string(version)),"capabilities":{"tools":{"listChanged":true}},"serverInfo":{"name":"visor","version":"agent-wrapper"}}"#
        case "tools/list":
            return #"{"tools":[\#(asksPermission ? approveTool : "")]}"#
        case "ping":
            return "{}"
        default:
            return nil
        }
    }

    private func unanswered(_ id: String, after wait: Duration) {
        guard let entry = forwarded.removeValue(forKey: id) else { return }
        if entry.method == "initialize", entry.sentOn != nil, driverServesMCP == nil {
            driverServesMCP = false
            log("mcp: the driver didn't answer initialize in \(Self.words(wait)): it doesn't serve MCP, so the agent has none of its tools, and its approvals are denied")
            for approval in asking.keys { deny(approval, unsupported: true) }
        }
        reply(client: entry.client, rpcID: entry.rpcID, fallback: entry.fallback, why: "The driver didn't answer in \(Self.words(wait)).")
    }

    /// A request answered here: with its fallback, else an error saying why.
    private func reply(client: String, rpcID: String, fallback: String?, why: String) {
        if let fallback {
            clients[client]?.send(#"{"jsonrpc":"2.0","id":\#(rpcID),"result":\#(fallback)}"#)
        } else {
            clients[client]?.send(#"{"jsonrpc":"2.0","id":\#(rpcID),"error":{"code":-32603,"message":\#(JSONText.string(why))}}"#)
        }
    }

    // MARK: - approve

    /// Claude's permission prompt: `{tool_name, input, tool_use_id}`, asked
    /// of the driver, and answered as Claude takes it back (`decision`).
    private func approve(rpcID: String, params: [String: Any], client: String) {
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let tool = (arguments["tool_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "tool"
        let input = arguments["input"] as? [String: Any] ?? [:]
        let inputJSON = JSONText.encode(input) ?? "{}"
        guard hasDriver else {
            return answer(client: client, rpcID: rpcID, decision: Self.deny(
                "This agent has no driver to ask for permission (AGENT_DRIVER_URL), so the call is denied."))
        }
        guard driverServesMCP != false else {
            return answer(client: client, rpcID: rpcID, decision: Self.deny(Self.cantApprove))
        }
        order += 1
        let id = UUID().uuidString.lowercased()
        var entry = Asking(order: order, client: client, rpcID: rpcID, inputJSON: inputJSON, request: .with {
            $0.id = id
            $0.tool = tool
            $0.summary = Self.summary(input)
            $0.inputJson = inputJSON
            $0.toolUseID = arguments["tool_use_id"] as? String ?? ""
        })
        if let link {
            link.continuation.yield(.with { $0.approval = entry.request })
            entry.sentOn = link.number
        }
        let timing = self.timing
        if let token = ((params["_meta"] as? [String: Any])?["progressToken"]).flatMap({ $0 is NSNull ? nil : JSONText.encode($0) }) {
            // Still waiting, said to Claude now and then, so it waits on.
            entry.tasks.append(Task { [weak self] in
                var beats = 0
                while true {
                    try? await Task.sleep(for: timing.heartbeat)
                    if Task.isCancelled { return }
                    beats += 1
                    await self?.progress(client: client, token: token, beats: beats)
                }
            })
        } else {
            entry.tasks.append(Task { [weak self] in
                try? await Task.sleep(for: timing.unanswered)
                if !Task.isCancelled { await self?.deny(id, unsupported: false) }
            })
        }
        asking[id] = entry
    }

    private func progress(client: String, token: String, beats: Int) {
        clients[client]?.send(#"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":\#(token),"progress":\#(beats),"message":"Waiting for permission from the driver"}}"#)
    }

    /// The driver's answer to an ApprovalRequest.
    public func take(_ approval: AgentProtocol_V1_Approval) {
        guard let entry = asking.removeValue(forKey: approval.requestID) else { return }
        for task in entry.tasks { task.cancel() }
        guard approval.allow else {
            return answer(client: entry.client, rpcID: entry.rpcID,
                          decision: Self.deny(approval.reason.isEmpty ? "The user denied this." : approval.reason))
        }
        let given = approval.updatedInputJson
        let updated = !given.isEmpty && JSONText.object(given) != nil ? given : entry.inputJSON
        answer(client: entry.client, rpcID: entry.rpcID, decision: #"{"behavior":"allow","updatedInput":\#(updated)}"#)
    }

    /// An approval denied here: unanswered in time, or the driver can't.
    private func deny(_ id: String, unsupported: Bool) {
        guard let entry = asking.removeValue(forKey: id) else { return }
        for task in entry.tasks { task.cancel() }
        if !unsupported, entry.sentOn != nil, let link { link.continuation.yield(.with { $0.approvalWithdrawn = id }) }
        let message = unsupported ? Self.cantApprove
            : "Nobody answered this permission request in \(Self.words(timing.unanswered)): go on without it, or ask again later."
        answer(client: entry.client, rpcID: entry.rpcID, decision: Self.deny(message))
    }

    /// An approval the agent gave up on: the driver told, nothing answered.
    private func withdraw(_ id: String) {
        guard let entry = asking.removeValue(forKey: id) else { return }
        for task in entry.tasks { task.cancel() }
        if entry.sentOn != nil, let link { link.continuation.yield(.with { $0.approvalWithdrawn = id }) }
    }

    /// A wait in words: "15 s", "25 minutes".
    static func words(_ wait: Duration) -> String {
        let seconds = wait.components.seconds
        return seconds >= 120 && seconds % 60 == 0 ? "\(seconds / 60) minutes" : "\(seconds) s"
    }

    static let cantApprove = "The driver this agent runs under can't take approvals (it doesn't serve MCP), so the call is denied."

    /// Claude's permission prompt's answer, refused.
    static func deny(_ message: String) -> String {
        #"{"behavior":"deny","message":\#(JSONText.string(message))}"#
    }

    /// The tool result Claude takes from its permission prompt: the
    /// decision, as JSON, in a text block.
    private func answer(client: String, rpcID: String, decision: String) {
        clients[client]?.send(#"{"jsonrpc":"2.0","id":\#(rpcID),"result":{"content":[{"type":"text","text":\#(JSONText.string(decision))}]}}"#)
    }

    /// The tool's descriptor, as Visor's own MCP server has it.
    static let approveTool = #"{"name":"approve","description":"Asks the Visor user to allow or deny a tool call.","inputSchema":{"type":"object","properties":{"tool_name":{"type":"string"},"input":{"type":"object"},"tool_use_id":{"type":"string"}}}}"#

    /// A line of a tool call's input for the prompt: its command, file,
    /// pattern or the like, else its first string (as Visor's MCPTools).
    static func summary(_ fields: [String: Any]) -> String {
        func line(_ text: String) -> String { String((text.split(separator: "\n", omittingEmptySubsequences: false).first ?? "").prefix(200)) }
        for key in ["command", "file_path", "path", "pattern", "query", "url", "description", "prompt"] {
            if let text = fields[key] as? String, !text.isEmpty { return line(text) }
        }
        return fields.keys.sorted().lazy.compactMap { fields[$0] as? String }.first.map(line) ?? ""
    }

    // MARK: - The driver's side

    /// A connection to the driver: what goes to it on this connection, the
    /// requests that waited for one first and every approval still asked
    /// (again: the driver takes an id once). Ending the stream ends the
    /// connection's part: requests it took unanswered fail.
    public func driverConnected() -> AsyncStream<AgentProtocol_V1_WrapperMessage> {
        links += 1
        let number = links
        link?.continuation.finish()
        let (stream, continuation) = AsyncStream<AgentProtocol_V1_WrapperMessage>.makeStream()
        link = (number, continuation)
        continuation.onTermination = { [weak self] _ in Task { await self?.driverDisconnected(number) } }
        for (id, entry) in forwarded.sorted(by: { $0.value.order < $1.value.order }) where entry.sentOn == nil {
            continuation.yield(.with { $0.mcp = entry.request })
            forwarded[id]?.sentOn = number
        }
        for (id, entry) in asking.sorted(by: { $0.value.order < $1.value.order }) {
            continuation.yield(.with { $0.approval = entry.request })
            asking[id]?.sentOn = number
        }
        return stream
    }

    private func driverDisconnected(_ number: Int) {
        if link?.number == number { link = nil }
        for (id, entry) in forwarded where entry.sentOn == number {
            entry.timer?.cancel()
            forwarded[id] = nil
            reply(client: entry.client, rpcID: entry.rpcID, fallback: entry.method == "initialize" ? entry.fallback : nil,
                  why: "The driver's connection dropped before it answered: try again.")
        }
        for (id, entry) in asking where entry.sentOn == number { asking[id]?.sentOn = nil }
    }

    /// The driver's MCP server's answer to a request (by its id), or a
    /// message of its own (no id) for a connection, or for every one.
    public func take(_ response: AgentProtocol_V1_McpResponse) {
        if driverServesMCP != true {
            if driverServesMCP == false { log("mcp: the driver serves MCP after all") }
            driverServesMCP = true
        }
        var line = JSONText.line(response.json)
        guard !response.id.isEmpty else {
            if response.client.isEmpty {
                for client in clients.values { client.send(line) }
            } else {
                clients[response.client]?.send(line)
            }
            return
        }
        guard let entry = forwarded.removeValue(forKey: response.id) else { return }
        entry.timer?.cancel()
        if entry.method == "tools/list", asksPermission { line = Self.withApprove(line) }
        clients[entry.client]?.send(line)
    }

    /// A tools/list result with `approve` in it.
    static func withApprove(_ line: String) -> String {
        guard var object = JSONText.object(line), var result = object["result"] as? [String: Any] else { return line }
        var tools = result["tools"] as? [Any] ?? []
        guard !tools.contains(where: { ($0 as? [String: Any])?["name"] as? String == "approve" }),
              let approve = JSONText.object(approveTool) else { return line }
        tools.insert(approve, at: 0)
        result["tools"] = tools
        object["result"] = result
        return JSONText.encode(object) ?? line
    }
}

/// JSON as text, a message a line.
enum JSONText {
    static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) as? [String: Any]
    }

    /// Any JSON value as compact text.
    static func encode(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]) else { return nil }
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    /// A string as a JSON string.
    static func string(_ text: String) -> String {
        encode(text) ?? "\"\""
    }

    /// A message as one line: as it is, unless it spans several.
    static func line(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: { $0 == "\n" || $0 == "\r" }), let value = try? JSONSerialization.jsonObject(
            with: Data(trimmed.utf8), options: [.fragmentsAllowed]), let compact = encode(value) else { return trimmed }
        return compact
    }
}
