// The agent's MCP server, "visor", through its wrapper: Claude's MCP
// client starts `agent-wrapper mcp`, which pipes to the wrapper's socket;
// the wrapper relays each message to its driver (WrapperMessage.mcp) and
// the answer back (DriverMessage.mcp); Claude's permission prompt,
// `approve`, becomes an ApprovalRequest and the driver's Approval its
// answer. And when there is no driver, or one that doesn't serve MCP, an
// answer all the same, never a wait without end.

import AgentProtocol
import AgentWrapper
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Synchronization
import XCTest

/// JSON for the tests: a line's object, a value's text.
enum JSONLine {
    static func object(_ line: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    static func text(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[null]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    /// A permission prompt's decision, from its tool result.
    static func decision(_ line: String) -> [String: Any]? {
        guard let result = object(line)?["result"] as? [String: Any], let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else { return nil }
        return object(text)
    }
}

/// Lines, as they come.
final class Lines: Sendable {
    private let state = Mutex<(buffer: Data, lines: [String])>((Data(), []))

    func add(_ data: Data) {
        state.withLock { state in
            state.buffer.append(data)
            while let end = state.buffer.firstIndex(of: 0x0A) {
                state.lines.append(String(decoding: state.buffer[state.buffer.startIndex..<end], as: UTF8.self))
                state.buffer.removeSubrange(state.buffer.startIndex...end)
            }
        }
    }

    var all: [String] { state.withLock { $0.lines } }

    /// The first line `matching`, within 10 s.
    func first(_ matching: @escaping @Sendable ([String: Any]) -> Bool) async throws -> [String: Any] {
        for _ in 0..<200 {
            if let line = all.lazy.compactMap(JSONLine.object).first(where: matching) { return line }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("no such line in \(all)")
        throw CancellationError()
    }

    /// The permission prompt's decision answering `id`.
    func decision(_ id: Any) async throws -> [String: Any] {
        let line = try await answer(id)
        return try XCTUnwrap(JSONLine.decision(JSONLine.text(line)))
    }

    /// The error answering `id`.
    func error(_ id: Any) async throws -> [String: Any] {
        let line = try await answer(id)
        return try XCTUnwrap(line["error"] as? [String: Any])
    }

    /// The result answering `id`.
    func result(_ id: Any) async throws -> [String: Any] {
        let line = try await answer(id)
        return try XCTUnwrap(line["result"] as? [String: Any])
    }

    /// The answer to the JSON-RPC request `id`.
    func answer(_ id: Any) async throws -> [String: Any] {
        let wanted = JSONLine.text(id)
        return try await first { line in line["id"].map(JSONLine.text) == wanted }
    }
}

/// How `agent-wrapper mcp`'s pipe ended, once it has.
final class Ended: Sendable {
    let status = Mutex<Int32?>(nil)
}

/// An MCP connection played here, for the relay alone.
final class FakeMCPClient: MCPClient {
    let lines = Lines()

    func send(_ line: String) {
        lines.add(Data((line + "\n").utf8))
    }
}

/// What a driver was told, and how it answers: played on the relay's own
/// stream, without gRPC.
final class PlayedDriver: Sendable {
    let heard = Mutex<[AgentProtocol_V1_WrapperMessage]>([])
    private let task: Mutex<Task<Void, Never>?> = Mutex(nil)

    /// Connected to `relay`, answering with `answer` (nothing, for an older
    /// driver that doesn't serve MCP).
    init(_ relay: MCPRelay, answer: @escaping @Sendable (AgentProtocol_V1_WrapperMessage) -> AgentProtocol_V1_DriverMessage? = { _ in nil }) async {
        let stream = await relay.driverConnected()
        task.withLock {
            $0 = Task { [self] in
                for await message in stream {
                    self.heard.withLock { $0.append(message) }
                    switch answer(message)?.message {
                    case .mcp(let response): await relay.take(response)
                    case .approval(let approval): await relay.take(approval)
                    default: break
                    }
                }
            }
        }
    }

    func disconnect() {
        task.withLock { $0?.cancel() }
    }

    var methods: [String] {
        heard.withLock { $0.compactMap { message in
            guard case .mcp(let request) = message.message else { return nil }
            return JSONLine.object(request.json)?["method"] as? String
        } }
    }

    var approvals: [AgentProtocol_V1_ApprovalRequest] {
        heard.withLock { $0.compactMap { if case .approval(let request) = $0.message { request } else { nil } } }
    }

    var withdrawn: [String] {
        heard.withLock { $0.compactMap { if case .approvalWithdrawn(let id) = $0.message { id } else { nil } } }
    }
}

/// Visor's side, as a test plays it over gRPC: its MCP server's logic for
/// the agent (initialize, a tool, a call) and the person's answers to its
/// approvals (Bash allowed with its command changed, anything else denied).
final class MCPDriver: AgentProtocol_V1_AgentDriver.SimpleServiceProtocol {
    let heard = Mutex<[AgentProtocol_V1_WrapperMessage]>([])

    func connect(request: RPCAsyncSequence<AgentProtocol_V1_WrapperMessage, any Error>,
                 response: RPCWriter<AgentProtocol_V1_DriverMessage>, context: ServerContext) async throws {
        for try await message in request {
            heard.withLock { $0.append(message) }
            switch message.message {
            case .mcp(let mcp):
                guard !mcp.id.isEmpty, let object = JSONLine.object(mcp.json), let id = object["id"] else { continue }
                let rpcID = JSONLine.text(id)
                func answer(_ result: String) -> AgentProtocol_V1_DriverMessage {
                    .with { $0.mcp = .with { $0.id = mcp.id; $0.json = #"{"jsonrpc":"2.0","id":\#(rpcID),"result":\#(result)}"# } }
                }
                switch object["method"] as? String {
                case "initialize":
                    try await response.write(answer(#"{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":true}},"serverInfo":{"name":"visor-test","version":"1"}}"#))
                case "tools/list":
                    try await response.write(answer(#"{"tools":[{"name":"send_message","inputSchema":{"type":"object"}}]}"#))
                    // And unasked, for that connection.
                    try await response.write(.with { $0.mcp = .with {
                        $0.json = #"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#
                        $0.client = mcp.client
                    } })
                case "tools/call":
                    let params = object["params"] as? [String: Any]
                    let to = (params?["arguments"] as? [String: Any])?["session"] as? String ?? ""
                    try await response.write(answer(#"{"content":[{"type":"text","text":"sent to \#(to)"}]}"#))
                default:
                    try await response.write(.with { $0.mcp = .with { $0.id = mcp.id; $0.json = #"{"jsonrpc":"2.0","id":\#(rpcID),"error":{"code":-32601,"message":"no"}}"# } })
                }
            case .approval(let asked):
                try await response.write(.with { $0.approval = .with {
                    $0.requestID = asked.id
                    $0.allow = asked.tool == "Bash"
                    if asked.tool == "Bash" { $0.updatedInputJson = #"{"command":"ls -la"}"# } else { $0.reason = "Not that file." }
                } })
            default:
                break
            }
        }
    }

    func conversation(request: AgentProtocol_V1_ConversationRequest, response: RPCWriter<AgentProtocol_V1_ConversationFile>,
                      context: ServerContext) async throws {}

    var mcpMethods: [String] {
        heard.withLock { $0.compactMap { message in
            guard case .mcp(let request) = message.message else { return nil }
            return JSONLine.object(request.json)?["method"] as? String
        } }
    }

    var approvals: [AgentProtocol_V1_ApprovalRequest] {
        heard.withLock { $0.compactMap { if case .approval(let request) = $0.message { request } else { nil } } }
    }
}

final class MCPRelayTests: XCTestCase {
    func testTheProtoCarriesMCPAndApprovals() throws {
        let up = AgentProtocol_V1_WrapperMessage.with { $0.mcp = .with { $0.id = "r1"; $0.json = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#; $0.client = "1" } }
        guard case .mcp(let request) = try AgentProtocol_V1_WrapperMessage(serializedBytes: try up.serializedBytes() as [UInt8]).message
        else { return XCTFail("an MCP request") }
        XCTAssertEqual(request.id, "r1")
        XCTAssertEqual(request.json, #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        XCTAssertEqual(request.client, "1")

        let withdrawn = AgentProtocol_V1_WrapperMessage.with { $0.approvalWithdrawn = "a1" }
        guard case .approvalWithdrawn(let id) = try AgentProtocol_V1_WrapperMessage(serializedBytes: try withdrawn.serializedBytes() as [UInt8]).message
        else { return XCTFail("an approval withdrawn") }
        XCTAssertEqual(id, "a1")

        let down = AgentProtocol_V1_DriverMessage.with { $0.mcp = .with { $0.id = "r1"; $0.json = "{}"; $0.client = "2" } }
        guard case .mcp(let response) = try AgentProtocol_V1_DriverMessage(serializedBytes: try down.serializedBytes() as [UInt8]).message
        else { return XCTFail("an MCP response") }
        XCTAssertEqual(response, down.mcp)

        let asked = AgentProtocol_V1_WrapperMessage.with { $0.approval = .with { $0.id = "a1"; $0.tool = "Bash"; $0.inputJson = "{}"; $0.toolUseID = "tu1" } }
        XCTAssertEqual(try AgentProtocol_V1_WrapperMessage(serializedBytes: try asked.serializedBytes() as [UInt8]).approval.toolUseID, "tu1")
        let answered = AgentProtocol_V1_DriverMessage.with { $0.approval = .with { $0.requestID = "a1"; $0.allow = true; $0.updatedInputJson = #"{"a":1}"# } }
        XCTAssertEqual(try AgentProtocol_V1_DriverMessage(serializedBytes: try answered.serializedBytes() as [UInt8]).approval.updatedInputJson, #"{"a":1}"#)
        XCTAssertTrue(try answered.jsonString().contains(#""updatedInputJson""#))
    }

    func testClaudeIsGivenTheMCPServerAndForManualPermissionsItsApprove() throws {
        var spec = AgentProtocol_V1_AgentSpec()
        spec.harness = "claude"
        spec.model = "m"
        let mcp = HarnessLaunch.MCP(command: "/opt/agent/agent-wrapper", socket: "/tmp/agent-mcp-ab12cd/mcp.sock")
        let manual = try HarnessLaunch.for(spec, claudeProgram: "/bin/claude", mcp: mcp)
        XCTAssertEqual(manual.arguments, ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--model", "m",
                                          "--mcp-config", mcp.config, "--permission-prompt-tool", "mcp__visor__approve"])
        XCTAssertEqual(manual.environment, ["AGENT_MCP_SOCKET": "/tmp/agent-mcp-ab12cd/mcp.sock"])
        let config = try XCTUnwrap(JSONLine.object(mcp.config))
        let visor = try XCTUnwrap((config["mcpServers"] as? [String: Any])?["visor"] as? [String: Any])
        XCTAssertEqual(Set(visor.keys), ["type", "command", "args", "env"], "nothing else, nothing secret")
        XCTAssertEqual(visor["command"] as? String, "/opt/agent/agent-wrapper")
        XCTAssertEqual(visor["args"] as? [String], ["mcp"])
        XCTAssertEqual(visor["env"] as? [String: String], ["AGENT_MCP_SOCKET": "/tmp/agent-mcp-ab12cd/mcp.sock"])

        spec.skipPermissions = true
        spec.resumeSessionID = "s1"
        let skipping = try HarnessLaunch.for(spec, claudeProgram: "/bin/claude", mcp: mcp)
        XCTAssertEqual(skipping.arguments, ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--model", "m",
                                            "--resume", "s1", "--mcp-config", mcp.config, "--permission-mode", "bypassPermissions"])

        let none = try HarnessLaunch.for(spec, claudeProgram: "/bin/claude")
        XCTAssertFalse(none.arguments.contains("--mcp-config"))
        XCTAssertEqual(none.environment, [:])

        // The token stays the wrapper's: not in claude's environment, not on
        // any command line.
        let environment = HarnessLaunch.environment(from: ["AGENT_TOKEN": "secret-token", "PATH": "/bin"]).merging(manual.environment) { $1 }
        XCTAssertEqual(environment, ["PATH": "/bin", "AGENT_MCP_SOCKET": "/tmp/agent-mcp-ab12cd/mcp.sock"])
        XCTAssertFalse((manual.arguments + skipping.arguments).joined(separator: " ").contains("secret-token"))
    }

    func testTheSocketIsPrivateAndGoneWhenClosed() throws {
        let relay = MCPRelay(hasDriver: false, asksPermission: true)
        let server = try MCPSocketServer(relay: relay)
        let folder = (server.path as NSString).deletingLastPathComponent
        let folderMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? NSNumber)
        let socketMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: server.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(folderMode.intValue & 0o777, 0o700)
        XCTAssertEqual(socketMode.intValue & 0o777, 0o600)
        server.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder))
    }

    /// The whole way: `agent-wrapper mcp`'s pipe, the wrapper's socket and
    /// relay, its driver link over gRPC, and a driver that serves MCP.
    func testClaudesMCPMessagesReachTheDriverAndItsApprovalsAnswerClaude() async throws {
        let driver = MCPDriver()
        let transport = HTTP2ServerTransport.Posix(address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext)
        try await withGRPCServer(transport: transport, services: [driver]) { server in
            let address = try await transport.listeningAddress
            let port = try XCTUnwrap(address.ipv4?.port)
            var spec = AgentProtocol_V1_AgentSpec()
            spec.harness = "echo"
            let core = AgentCore(agent: .with { $0.uuid = "a5" }, spec: spec, launch: .echo)
            try await core.start()
            let relay = MCPRelay(hasDriver: true, asksPermission: true)
            let socket = try MCPSocketServer(relay: relay)
            defer { socket.close() }
            let link = try XCTUnwrap(DriverLink(url: "http://127.0.0.1:\(port)", core: core, hostName: "test-host", relay: relay))
            let linking = Task { await link.run() }

            // `agent-wrapper mcp`, as Claude starts it: its stdin and stdout.
            let input = Pipe(), output = Pipe()
            let lines = Lines()
            output.fileHandleForReading.readabilityHandler = { lines.add($0.availableData) }
            let ended = Ended()
            let path = socket.path
            let (inputFD, outputFD) = (input.fileHandleForReading.fileDescriptor, output.fileHandleForWriting.fileDescriptor)
            Thread.detachNewThread {
                let status = MCPStdio.pump(socket: path, input: inputFD, output: outputFD)
                ended.status.withLock { $0 = status }
            }
            func say(_ line: String) { input.fileHandleForWriting.write(Data((line + "\n").utf8)) }

            say(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"2"}}}"#)
            let initialized = try await lines.answer(1)
            XCTAssertEqual(((initialized["result"] as? [String: Any])?["serverInfo"] as? [String: Any])?["name"] as? String, "visor-test",
                           "the driver's own answer")
            let serves = await relay.driverServesMCP
            XCTAssertEqual(serves, true)
            say(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)

            say(#"{"jsonrpc":"2.0","id":"list","method":"tools/list"}"#)
            let listed = try await lines.answer("list")
            let tools = ((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
            XCTAssertEqual(tools, ["approve", "send_message"], "the wrapper's approve beside the driver's tools")
            _ = try await lines.first { $0["method"] as? String == "notifications/tools/list_changed" }

            say(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"send_message","arguments":{"session":"s1","server":"v1","text":"hi"}}}"#)
            let sent = try await lines.answer(3)
            let content = (sent["result"] as? [String: Any])?["content"] as? [[String: Any]]
            XCTAssertEqual(content?.first?["text"] as? String, "sent to s1")

            say(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"approve","arguments":{"tool_name":"Bash","input":{"command":"ls","description":"List"},"tool_use_id":"tu1"}}}"#)
            let allowed = try await lines.decision(4)
            XCTAssertEqual(allowed["behavior"] as? String, "allow")
            XCTAssertEqual(allowed["updatedInput"] as? [String: String], ["command": "ls -la"], "the driver's input")

            say(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"approve","arguments":{"tool_name":"Write","input":{"file_path":"/etc/hosts"}}}}"#)
            let denied = try await lines.decision(5)
            XCTAssertEqual(denied["behavior"] as? String, "deny")
            XCTAssertEqual(denied["message"] as? String, "Not that file.")

            let asked = driver.approvals
            XCTAssertEqual(asked.map(\.tool), ["Bash", "Write"])
            XCTAssertEqual(asked.first?.summary, "ls")
            XCTAssertEqual(asked.first?.toolUseID, "tu1")
            XCTAssertEqual(JSONLine.object(asked.first?.inputJson ?? "") as? [String: String], ["command": "ls", "description": "List"])
            XCTAssertEqual(driver.mcpMethods, ["initialize", "notifications/initialized", "tools/list", "tools/call"],
                           "approve never reaches the driver as MCP")

            // Claude closes its end: the pipe ends cleanly.
            try input.fileHandleForWriting.close()
            for _ in 0..<200 where ended.status.withLock({ $0 }) == nil { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertEqual(ended.status.withLock { $0 }, 0)
            output.fileHandleForReading.readabilityHandler = nil

            await core.stop()
            _ = await core.ended()
            await linking.value
            server.beginGracefulShutdown()
        }
    }

    func testAnAllowWithoutAnInputGivesTheInputAsAsked() async throws {
        let relay = MCPRelay(hasDriver: true, asksPermission: true)
        let client = FakeMCPClient()
        let name = await relay.connected(client)
        let driver = await PlayedDriver(relay) { message in
            guard case .approval(let asked) = message.message else { return nil }
            return .with { $0.approval = .with { $0.requestID = asked.id; $0.allow = true } }
        }
        await relay.handle(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"approve","arguments":{"tool_name":"Edit","input":{"file_path":"/w/a","old_string":"x"}}}}"#, from: name)
        let decision = try await client.lines.decision(7)
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        XCTAssertEqual(decision["updatedInput"] as? [String: String], ["file_path": "/w/a", "old_string": "x"])
        driver.disconnect()
    }

    func testADriverThatDoesntServeMCPLeavesTheAgentApproveAloneAndClearErrors() async throws {
        let relay = MCPRelay(hasDriver: true, asksPermission: true, timing: .init(answer: .milliseconds(300)))
        let client = FakeMCPClient()
        let name = await relay.connected(client)
        let older = await PlayedDriver(relay)
        let started = ContinuousClock.now
        await relay.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#, from: name)
        let initialized = try await client.lines.answer(1)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(300), "the driver had its time to answer")
        let result = try XCTUnwrap(initialized["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "visor")
        let serves = await relay.driverServesMCP
        XCTAssertEqual(serves, false)

        await relay.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, from: name)
        let listed = try await client.lines.answer(2)
        XCTAssertEqual(((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["approve"])

        await relay.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"send_message","arguments":{}}}"#, from: name)
        let failed = try await client.lines.error(3)
        XCTAssertEqual(failed["code"] as? Int, -32603)
        XCTAssertTrue((failed["message"] as? String ?? "").contains("doesn't serve MCP"), "\(failed)")

        await relay.handle(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"approve","arguments":{"tool_name":"Bash","input":{"command":"ls"}}}}"#, from: name)
        let denied = try await client.lines.decision(4)
        XCTAssertEqual(denied["behavior"] as? String, "deny")
        XCTAssertTrue((denied["message"] as? String ?? "").contains("can't take approvals"), "\(denied)")
        XCTAssertEqual(older.methods, ["initialize"], "nothing more was sent to it")
        XCTAssertTrue(older.approvals.isEmpty)
        older.disconnect()
    }

    func testWithNoDriverEverythingIsAnsweredAtOnce() async throws {
        let relay = MCPRelay(hasDriver: false, asksPermission: false)
        let client = FakeMCPClient()
        let name = await relay.connected(client)
        await relay.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#, from: name)
        _ = try await client.lines.result(1)
        await relay.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, from: name)
        let listed = try await client.lines.result(2)
        XCTAssertEqual((listed["tools"] as? [Any])?.count, 0, "no approve for an agent that doesn't ask")
        await relay.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_sessions","arguments":{}}}"#, from: name)
        let failed = try await client.lines.error(3)
        XCTAssertTrue((failed["message"] as? String ?? "").contains("no driver"), "\(failed)")
        await relay.handle(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"approve","arguments":{"tool_name":"Bash","input":{}}}}"#, from: name)
        let denied = try await client.lines.decision(4)
        XCTAssertEqual(denied["behavior"] as? String, "deny")
    }

    func testAToolCallTheDriverLeavesUnansweredFailsInTime() async throws {
        let relay = MCPRelay(hasDriver: true, asksPermission: true, timing: .init(answer: .seconds(5), call: .milliseconds(300)))
        let client = FakeMCPClient()
        let name = await relay.connected(client)
        // A driver that answers initialize, then nothing.
        let driver = await PlayedDriver(relay) { message in
            guard case .mcp(let request) = message.message, let object = JSONLine.object(request.json),
                  object["method"] as? String == "initialize", let id = object["id"] else { return nil }
            return .with { $0.mcp = .with { $0.id = request.id; $0.json = #"{"jsonrpc":"2.0","id":\#(JSONLine.text(id)),"result":{}}"# } }
        }
        await relay.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#, from: name)
        _ = try await client.lines.answer(1)
        await relay.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_inbox","arguments":{}}}"#, from: name)
        let failed = try await client.lines.error(2)
        XCTAssertTrue((failed["message"] as? String ?? "").contains("didn't answer"), "\(failed)")
        driver.disconnect()
    }

    func testAnApprovalNobodyAnswersIsDeniedAndWithdrawn() async throws {
        let relay = MCPRelay(hasDriver: true, asksPermission: true, timing: .init(heartbeat: .milliseconds(100), unanswered: .milliseconds(300)))
        let client = FakeMCPClient()
        let name = await relay.connected(client)
        let driver = await PlayedDriver(relay)
        await relay.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"approve","arguments":{"tool_name":"Bash","input":{"command":"ls"}}}}"#, from: name)
        let denied = try await client.lines.decision(1)
        XCTAssertEqual(denied["behavior"] as? String, "deny")
        XCTAssertTrue((denied["message"] as? String ?? "").contains("Nobody answered"), "\(denied)")
        for _ in 0..<100 where driver.withdrawn.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(driver.withdrawn, driver.approvals.map(\.id), "the driver told to withdraw its prompt")

        // With progress: told it waits, and the agent giving up withdraws it.
        await relay.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"approve","arguments":{"tool_name":"Bash","input":{}},"_meta":{"progressToken":"p2"}}}"#, from: name)
        _ = try await client.lines.first { ($0["params"] as? [String: Any])?["progressToken"] as? String == "p2" }
        await relay.handle(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}"#, from: name)
        for _ in 0..<100 where driver.withdrawn.count < 2 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(driver.withdrawn.count, 2)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(client.lines.all.contains { JSONLine.object($0)?["id"] as? Int == 2 }, "nothing answered for a call given up")
        driver.disconnect()
    }

    func testAnApprovalAskedWhileTheDriverIsAwayIsAskedWhenItConnects() async throws {
        let relay = MCPRelay(hasDriver: true, asksPermission: true)
        let client = FakeMCPClient()
        let name = await relay.connected(client)
        await relay.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"approve","arguments":{"tool_name":"Bash","input":{"command":"make"}}}}"#, from: name)
        let driver = await PlayedDriver(relay) { message in
            guard case .approval(let asked) = message.message else { return nil }
            return .with { $0.approval = .with { $0.requestID = asked.id; $0.allow = false } }
        }
        let denied = try await client.lines.decision(1)
        XCTAssertEqual(denied["behavior"] as? String, "deny")
        XCTAssertEqual(denied["message"] as? String, "The user denied this.")
        XCTAssertEqual(driver.approvals.map(\.summary), ["make"])
        driver.disconnect()
    }
}
