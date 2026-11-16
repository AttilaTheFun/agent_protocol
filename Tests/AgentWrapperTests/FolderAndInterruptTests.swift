// A fresh job's folder made before its harness starts (a missing one made
// Linux's Foundation say the program wasn't there), and the driver's
// interrupt sent to Claude as a control request: the turn ends, the harness
// carries on.

import AgentProtocol
import AgentWrapper
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Synchronization
import XCTest

final class FolderAndInterruptTests: XCTestCase {
    private func scratch(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    /// Until `condition` holds of the core, or 10 s.
    private func until(_ core: AgentCore, _ condition: @escaping @Sendable (AgentCore) async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition(core) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("not in time")
    }

    /// Whether two lines are the same JSON, whatever their keys' order.
    private func sameJSON(_ one: String?, _ other: String) -> Bool {
        guard let one, let a = try? JSONSerialization.jsonObject(with: Data(one.utf8)) as? NSDictionary,
              let b = try? JSONSerialization.jsonObject(with: Data(other.utf8)) as? NSDictionary else { return false }
        return a.isEqual(b)
    }

    private func agent(_ uuid: String) -> AgentProtocol_V1_AgentID {
        var agent = AgentProtocol_V1_AgentID()
        agent.uuid = uuid
        agent.dispatcherURL = "http://dispatcher"
        return agent
    }

    // MARK: - The working directory

    func testAFreshJobsFolderUnderTheSessionsDirectoryIsMadeAndTheHarnessWorksInIt() async throws {
        let sessions = scratch("sessions")
        defer { try? FileManager.default.removeItem(at: sessions) }
        let options = try WrapperOptions(arguments: [], environment: [
            "AGENT_ID": "0a9e4e10-0000-4000-8000-000000000009@http://dispatcher", "AGENT_JOB": #"{"prompt":"where"}"#,
            "AGENT_SESSIONS_DIR": sessions.path,
        ])
        let folder = sessions.appendingPathComponent("Claude/0a9e4e10-0000-4000-8000-000000000009").path
        XCTAssertEqual(options.spec.workingDirectory, folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessions.path), "nothing made it yet")
        let launch = try HarnessLaunch.for(options.spec, claudeProgram: FakeClaude.interruptible)
        let core = AgentCore(agent: options.agent, spec: options.spec, launch: launch)
        try await core.start()
        try await until(core) { core in await core.entries.contains { $0.text.hasPrefix("here: ") } }
        let answer = await core.entries.first { $0.text.hasPrefix("here: ") }?.text ?? ""
        let worked = URL(fileURLWithPath: String(answer.dropFirst("here: ".count))).resolvingSymlinksInPath().path
        XCTAssertEqual(worked, URL(fileURLWithPath: folder).resolvingSymlinksInPath().path)
        await core.stop(grace: .milliseconds(200))
        _ = await core.ended()
    }

    func testTheSessionsFolderIsNamedOnlyByAUUIDAndASingleHarnessName() throws {
        let id = "0a9e4e10-0000-4000-8000-00000000000a"
        func options(_ agent: String, harness: String? = nil) throws -> WrapperOptions {
            let job = harness.map { #"{"harness":"\#($0)"}"# } ?? "{}"
            return try WrapperOptions(arguments: [], environment: [
                "AGENT_ID": "\(agent)@http://dispatcher", "AGENT_JOB": job, "AGENT_SESSIONS_DIR": "/Volumes/Sessions",
            ])
        }
        XCTAssertEqual(try options(id).spec.workingDirectory, "/Volumes/Sessions/Claude/\(id)")
        XCTAssertEqual(try options(id, harness: "echo").spec.workingDirectory, "/Volumes/Sessions/Echo/\(id)")
        for bad in ["u9", "../../etc", "\(id)/..", "0a9e4e10-0000-4000-8000-00000000000a/x"] {
            XCTAssertThrowsError(try options(bad), "agent \(bad)") { error in
                guard case WrapperOptions.Problem.bad(let why) = error else { return XCTFail("\(error)") }
                XCTAssertTrue(why.contains("isn't a UUID"), why)
            }
        }
        for bad in ["..", ".", "a/b", "/claude"] {
            XCTAssertThrowsError(try options(id, harness: bad), "harness \(bad)") { error in
                guard case WrapperOptions.Problem.bad(let why) = error else { return XCTFail("\(error)") }
                XCTAssertTrue(why.contains("isn't a single folder name"), why)
            }
        }
        XCTAssertThrowsError(try WrapperOptions(arguments: ["--harness", ""], environment: [
            "AGENT_ID": "\(id)@http://dispatcher", "AGENT_SESSIONS_DIR": "/Volumes/Sessions",
        ]), "an empty harness")
        // A job that names its folder is taken as it is: no folder is built.
        let named = try WrapperOptions(arguments: [], environment: [
            "AGENT_ID": "u9@http://dispatcher", "AGENT_JOB": #"{"workingDirectory":"/w"}"#, "AGENT_SESSIONS_DIR": "/Volumes/Sessions",
        ])
        XCTAssertEqual(named.spec.workingDirectory, "/w")
    }

    func testAFolderThatCantBeMadeIsNamed() async throws {
        let place = scratch("blocked")
        defer { try? FileManager.default.removeItem(at: place) }
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        // A file where a folder above it would be.
        let file = place.appendingPathComponent("Claude")
        try Data("not a folder".utf8).write(to: file)
        let folder = file.appendingPathComponent("u10").path
        var spec = AgentProtocol_V1_AgentSpec()
        spec.workingDirectory = folder
        let core = AgentCore(agent: agent("u10"), spec: spec, launch: HarnessLaunch(executable: FakeClaude.interruptible, arguments: []))
        do {
            try await core.start()
            XCTFail("it started")
        } catch {
            guard case AgentCore.Problem.folderNotMade(let named, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(named, folder)
            XCTAssertTrue("\(error)".contains(folder), "\(error)")
        }
    }

    func testAProgramThatDoesntStartIsNamedWithItsFolder() async throws {
        let folder = scratch("there")
        defer { try? FileManager.default.removeItem(at: folder) }
        var spec = AgentProtocol_V1_AgentSpec()
        spec.workingDirectory = folder.path
        let program = folder.appendingPathComponent("no-such-claude").path
        let core = AgentCore(agent: agent("u11"), spec: spec, launch: HarnessLaunch(executable: program, arguments: []))
        do {
            try await core.start()
            XCTFail("it started")
        } catch {
            guard case AgentCore.Problem.notStarted(let named, let place, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(named, program)
            XCTAssertEqual(place, folder.path, "the folder was made, and is there")
        }
    }

    // MARK: - Interrupts

    func testAnInterruptIsAControlRequestTheTurnEndsAndTheNextMessageGoesThrough() async throws {
        let record = scratch("stdin").appendingPathExtension("jsonl")
        defer { try? FileManager.default.removeItem(at: record) }
        var spec = AgentProtocol_V1_AgentSpec()
        spec.harness = "claude"
        spec.workingDirectory = FileManager.default.temporaryDirectory.path
        let core = AgentCore(agent: agent("u12"), spec: spec, launch: HarnessLaunch(executable: FakeClaude.interruptible, arguments: [record.path]))
        try await core.start()
        let nothing = await core.interrupt()
        XCTAssertFalse(nothing, "no turn under way: nothing sent")

        await core.send(id: "m1", text: "slow work")
        try await until(core) { core in await core.entries.contains { $0.text == "working on: slow work" } }
        let busy = await core.state.busy
        XCTAssertTrue(busy)
        let sent = await core.interrupt()
        XCTAssertTrue(sent)
        try await until(core) { core in await !core.state.busy }
        let ended = await core.attach().ended
        XCTAssertNil(ended, "the harness carries on")

        let lines = try String(contentsOf: record, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, "\(lines)")
        XCTAssertTrue(sameJSON(lines.first, ClaudeLine.userTurn("slow work")), "\(lines)")
        let interrupt = try XCTUnwrap(lines.last)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(interrupt.utf8)) as? [String: Any])
        let id = try XCTUnwrap(object["request_id"] as? String)
        XCTAssertTrue(id.hasPrefix("interrupt-"), id)
        XCTAssertEqual(interrupt, #"{"request":{"subtype":"interrupt"},"request_id":"\#(id)","type":"control_request"}"#)

        await core.send(id: "m2", text: "after")
        try await until(core) { core in
            let answered = await core.entries.contains { $0.text == "echo: after" }
            let busy = await core.state.busy
            return answered && !busy
        }
        let words = await core.entries.map(\.text)
        XCTAssertEqual(words, ["slow work", "working on: slow work", "after", "echo: after"])
        let all = try String(contentsOf: record, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(all.count, 3)
        XCTAssertTrue(sameJSON(all.last, ClaudeLine.userTurn("after")), "\(all)")
        await core.stop(grace: .milliseconds(200))
        _ = await core.ended()
    }

    func testTheEchoHarnesssTurnEndsUnansweredWhenInterrupted() async throws {
        var spec = AgentProtocol_V1_AgentSpec()
        spec.harness = "echo"
        let core = AgentCore(agent: agent("u13"), spec: spec, launch: .echo)
        try await core.start()
        await core.send(id: "e1", text: "never answered")
        let sent = await core.interrupt()
        XCTAssertTrue(sent)
        let busy = await core.state.busy
        XCTAssertFalse(busy)
        try await Task.sleep(for: .milliseconds(400))
        await core.send(id: "e2", text: "answered")
        try await until(core) { core in await core.entries.contains { $0.text == "echo: answered" } }
        let replies = await core.entries.filter { $0.role == .assistant }.map(\.text)
        XCTAssertEqual(replies, ["echo: answered"])
        await core.stop()
        _ = await core.ended()
    }

    func testTheDriversInterruptReachesTheHarness() async throws {
        let driver = InterruptingDriver()
        let transport = HTTP2ServerTransport.Posix(address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext)
        let record = scratch("stdin").appendingPathExtension("jsonl")
        defer { try? FileManager.default.removeItem(at: record) }
        try await withGRPCServer(transport: transport, services: [driver]) { server in
            let address = try await transport.listeningAddress
            let port = try XCTUnwrap(address.ipv4?.port)
            var spec = AgentProtocol_V1_AgentSpec()
            spec.harness = "claude"
            spec.workingDirectory = FileManager.default.temporaryDirectory.path
            let core = AgentCore(agent: agent("u14"), spec: spec, launch: HarnessLaunch(executable: FakeClaude.interruptible, arguments: [record.path]))
            try await core.start()
            let link = try XCTUnwrap(DriverLink(url: "http://127.0.0.1:\(port)", core: core, hostName: "test-host"))
            let linking = Task { await link.run() }
            for _ in 0..<200 where !driver.heard("echo: after") { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertTrue(driver.heard("echo: after"), "after the interrupt, the driver's next message was answered")
            let lines = try String(contentsOf: record, encoding: .utf8).split(separator: "\n").map(String.init)
            XCTAssertEqual(lines.count, 3, "\(lines)")
            XCTAssertTrue(lines[1].hasPrefix(#"{"request":{"subtype":"interrupt"},"request_id":"interrupt-"#), lines[1])
            let ended = await core.attach().ended
            XCTAssertNil(ended)
            await core.stop(grace: .milliseconds(200))
            _ = await core.ended()
            await linking.value
            server.beginGracefulShutdown()
        }
    }
}

/// A driver that sends a slow message, interrupts it once it is under way,
/// then sends another once the turn has ended.
final class InterruptingDriver: AgentProtocol_V1_AgentDriver.SimpleServiceProtocol {
    private let texts = Mutex<[String]>([])

    func heard(_ text: String) -> Bool {
        texts.withLock { $0.contains(text) }
    }

    func connect(request: RPCAsyncSequence<AgentProtocol_V1_WrapperMessage, any Error>,
                 response: RPCWriter<AgentProtocol_V1_DriverMessage>, context: ServerContext) async throws {
        var interrupted = false
        var followed = false
        for try await message in request {
            switch message.message {
            case .hello:
                try await response.write(.with { $0.send = .with { $0.id = "d1"; $0.text = "slow work" } })
            case .entries(let rows):
                texts.withLock { $0 += rows.entries.map(\.text) }
                if !interrupted, rows.entries.contains(where: { $0.text == "working on: slow work" }) {
                    interrupted = true
                    try await response.write(.with { $0.interrupt = .init() })
                }
            case .state(let state):
                if interrupted, !followed, !state.busy {
                    followed = true
                    try await response.write(.with { $0.send = .with { $0.id = "d2"; $0.text = "after" } })
                }
            default:
                break
            }
        }
    }

    func conversation(request: AgentProtocol_V1_ConversationRequest, response: RPCWriter<AgentProtocol_V1_ConversationFile>,
                      context: ServerContext) async throws {}
}
