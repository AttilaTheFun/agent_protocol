// A session handed back (DriverMessage.hand_back): its conversation's files
// gathered from a stand-in for Claude's folder (the conversation, the folder
// beside it, the project's memory; no link followed, nothing but regular
// files), sent in pieces of at most 1 MiB, and, against a driver played here
// over gRPC, the wrapper ending its harness, returning its conversation
// (ReturnConversation, the header then the files, the agent's token shown),
// and only then ending. A stop is as it was: no return. And the hello says
// protocol 2.

import AgentProtocol
@testable import AgentWrapper
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Synchronization
import XCTest

/// A driver that hands back each agent once it knows its session (or
/// stops it, `stops`), and keeps what ReturnConversation brought: the
/// header, each file joined from its pieces, and the order things happened
/// in ("returned", "ended"). `unimplemented`, its ReturnConversation is an
/// older driver's.
final class HandBackDriver: AgentProtocol_V1_AgentDriver.SimpleServiceProtocol {
    let stops: Bool
    let unimplemented: Bool
    let header = Mutex<AgentProtocol_V1_ReturnedConversationHeader?>(nil)
    let files = Mutex<[String: Data]>([:])
    let order = Mutex<[String]>([])
    let returns = Mutex(0)

    init(stops: Bool = false, unimplemented: Bool = false) {
        self.stops = stops
        self.unimplemented = unimplemented
    }

    func connect(request: RPCAsyncSequence<AgentProtocol_V1_WrapperMessage, any Error>,
                 response: RPCWriter<AgentProtocol_V1_DriverMessage>, context: ServerContext) async throws {
        var told = false
        for try await message in request {
            let session: String
            switch message.message {
            case .hello(let hello): session = hello.sessionID
            case .sessionID(let id): session = id
            case .ended: order.withLock { $0.append("ended") }; continue
            default: continue
            }
            guard !told, !session.isEmpty else { continue }
            told = true
            try await response.write(.with { if stops { $0.stop = .init() } else { $0.handBack = .init() } })
        }
    }

    func conversation(request: AgentProtocol_V1_ConversationRequest, response: RPCWriter<AgentProtocol_V1_ConversationFile>,
                      context: ServerContext) async throws {}

    func returnConversation(request: RPCAsyncSequence<AgentProtocol_V1_ReturnedConversation, any Error>,
                            context: ServerContext) async throws -> AgentProtocol_V1_ReturnedConversationAck {
        returns.withLock { $0 += 1 }
        if unimplemented { throw RPCError(code: .unimplemented, message: "no ReturnConversation") }
        var taken: [String: Data] = [:]
        var count: Int64 = 0
        for try await part in request {
            switch part.part {
            case .header(let header): self.header.withLock { $0 = header }
            case .file(let piece):
                taken[piece.place, default: Data()].append(piece.data)
                if piece.last { count += 1 }
            case .none: break
            }
        }
        files.withLock { $0 = taken }
        order.withLock { $0.append("returned") }
        let session = header.withLock { $0?.sessionID ?? "" }
        return .with { $0.files = count; $0.sessionID = session }
    }
}

final class HandBackTests: XCTestCase {
    private func folder(_ name: String) throws -> URL {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: made) }
        return made
    }

    private func write(_ text: String, at place: String, in folder: URL) throws {
        let file = folder.appendingPathComponent(place, isDirectory: false)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func testClaudesKeyForAFolderIsItsPathWithEveryOtherCharacterADash() {
        XCTAssertEqual(ConversationReturn.projectKey(for: "/nowhere/Developer/visor_app/a.b c"), "-nowhere-Developer-visor-app-a-b-c")
        XCTAssertEqual(ConversationReturn.projectKey(for: "/nowhere/Volumes/Sessions/Claude/5e55f0a9-0000"), "-nowhere-Volumes-Sessions-Claude-5e55f0a9-0000")
    }

    func testTheConversationTheFolderBesideItAndTheMemoryAreGatheredAndNothingElse() throws {
        let claude = try folder("claude")
        let work = try folder("work")
        let outside = try folder("outside")
        try write("secret\n", at: "secret.md", in: outside)
        let project = "projects/" + ConversationReturn.projectKey(for: work.path)
        try write("{\"a\":1}\n", at: "\(project)/s1.jsonl", in: claude)
        try write("{}\n", at: "\(project)/s1/subagents/agent-a.jsonl", in: claude)
        try write("result\n", at: "\(project)/s1/tool-results/r1.txt", in: claude)
        try write("- a memory\n", at: "\(project)/memory/MEMORY.md", in: claude)
        try write("a fact\n", at: "\(project)/memory/facts/fact.md", in: claude)
        try write("another conversation\n", at: "\(project)/s2.jsonl", in: claude)
        try write("{}\n", at: "settings.json", in: claude)
        // Links, to a file and a folder outside Claude's folder and to one
        // inside it, and a pipe: none of them a regular file.
        let manager = FileManager.default
        try manager.createSymbolicLink(atPath: claude.path + "/\(project)/memory/leak.md", withDestinationPath: outside.path + "/secret.md")
        try manager.createSymbolicLink(atPath: claude.path + "/\(project)/s1/outside", withDestinationPath: outside.path)
        try manager.createSymbolicLink(atPath: claude.path + "/\(project)/memory/settings.json", withDestinationPath: claude.path + "/settings.json")
        XCTAssertEqual(mkfifo(claude.path + "/\(project)/s1/pipe", 0o600), 0)

        let files = ConversationReturn.files(sessionID: "s1", workingDirectory: work.path, in: claude)
        XCTAssertEqual(files.map(\.place), [
            "\(project)/s1.jsonl",
            "\(project)/s1/subagents/agent-a.jsonl",
            "\(project)/s1/tool-results/r1.txt",
            "\(project)/memory/MEMORY.md",
            "\(project)/memory/facts/fact.md",
        ], "the conversation first, then the folder beside it, then the memory; no link, no pipe, no other conversation")
        XCTAssertEqual(ConversationReturn.files(sessionID: "", workingDirectory: work.path, in: claude), [], "no session, no files")
        XCTAssertEqual(ConversationReturn.files(sessionID: "../x", workingDirectory: work.path, in: claude), [])
        XCTAssertEqual(ConversationReturn.files(sessionID: "s1", workingDirectory: work.path, in: outside), [], "no projects folder")
    }

    func testAProjectFolderThatIsALinkIsNotFollowed() throws {
        let claude = try folder("claude")
        let work = try folder("work")
        let outside = try folder("outside")
        try write("{}\n", at: "s1.jsonl", in: outside)
        try write("- a memory\n", at: "memory/MEMORY.md", in: outside)
        try FileManager.default.createDirectory(at: claude.appendingPathComponent("projects"), withIntermediateDirectories: true)
        let project = "projects/" + ConversationReturn.projectKey(for: work.path)
        try FileManager.default.createSymbolicLink(atPath: claude.path + "/" + project, withDestinationPath: outside.path)
        XCTAssertEqual(ConversationReturn.files(sessionID: "s1", workingDirectory: work.path, in: claude), [])
    }

    func testAConversationUnderAnotherKeyIsFoundByItsName() throws {
        let claude = try folder("claude")
        try write("{}\n", at: "projects/-shortened-1a2b3c/s9.jsonl", in: claude)
        try write("- a memory\n", at: "projects/-shortened-1a2b3c/memory/MEMORY.md", in: claude)
        try write("{}\n", at: "projects/-other/s8.jsonl", in: claude)
        let files = ConversationReturn.files(sessionID: "s9", workingDirectory: "/nowhere/at/all", in: claude)
        XCTAssertEqual(files.map(\.place), ["projects/-shortened-1a2b3c/s9.jsonl", "projects/-shortened-1a2b3c/memory/MEMORY.md"])
    }

    func testAFileGoesInPiecesOfAtMostOneMebibyteTheLastMarked() async throws {
        let claude = try folder("claude")
        let size = ConversationReturn.pieceSize
        XCTAssertEqual(size, 1 << 20)
        var bytes = Data(count: size * 5 / 2)
        for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index &* 31) }
        let sizes: [(name: String, data: Data, pieces: [Int])] = [
            ("big", bytes, [size, size, size / 2]),
            ("exact", bytes.prefix(size), [size]),
            ("small", Data("{}\n".utf8), [3]),
            ("empty", Data(), [0]),
        ]
        for (name, data, expected) in sizes {
            try data.write(to: claude.appendingPathComponent(name))
            var pieces: [AgentProtocol_V1_ConversationFile] = []
            try await ConversationReturn.pieces(of: .init(place: "projects/p/\(name)", url: claude.appendingPathComponent(name))) { pieces.append($0) }
            XCTAssertEqual(pieces.map(\.data.count), expected, name)
            XCTAssertEqual(pieces.map(\.last), expected.indices.map { $0 == expected.count - 1 }, "\(name): last on its last piece alone")
            XCTAssertEqual(Set(pieces.map(\.place)), ["projects/p/\(name)"])
            XCTAssertEqual(pieces.reduce(Data()) { $0 + $1.data }, data, "\(name): its pieces are the file")
        }
        // A link put where a file was found isn't read.
        try FileManager.default.createSymbolicLink(atPath: claude.path + "/linked", withDestinationPath: claude.path + "/small")
        do {
            try await ConversationReturn.pieces(of: .init(place: "projects/p/linked", url: claude.appendingPathComponent("linked"))) { _ in }
            XCTFail("a link is refused")
        } catch {}
    }

    /// The agent, under the stand-in Claude (session "fake-session"),
    /// working in `work`, linked to a driver at `port` with Claude's folder
    /// `claude`: its core and its link's task.
    private func linked(port: Int, work: URL, claude: URL, token: AgentToken = AgentToken())
        async throws -> (core: AgentCore, linking: Task<Void, Never>) {
        var spec = AgentProtocol_V1_AgentSpec()
        spec.harness = "claude"
        spec.workingDirectory = work.path
        var agent = AgentProtocol_V1_AgentID()
        agent.uuid = "a7"
        agent.dispatcherURL = "http://dispatcher"
        let core = AgentCore(agent: agent, spec: spec, launch: HarnessLaunch(executable: FakeClaude.path, arguments: []))
        try await core.start()
        let link = try XCTUnwrap(DriverLink(url: "http://127.0.0.1:\(port)", core: core, hostName: "test-host", token: token, claudeFolder: claude))
        return (core, Task { await link.run() })
    }

    func testAHandBackEndsTheHarnessReturnsItsConversationThenEnds() async throws {
        let claude = try folder("claude")
        let work = try folder("work")
        let project = "projects/" + ConversationReturn.projectKey(for: work.path)
        try write("{\"turn\":\"here\"}\n", at: "\(project)/fake-session.jsonl", in: claude)
        try write("{}\n", at: "\(project)/fake-session/subagents/agent-a.jsonl", in: claude)
        try write("- a memory\n", at: "\(project)/memory/MEMORY.md", in: claude)
        let driver = HandBackDriver()
        let seen = SeenCalls()
        let transport = HTTP2ServerTransport.Posix(address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext)
        try await withGRPCServer(transport: transport, services: [driver], interceptors: [seen]) { server in
            let address = try await transport.listeningAddress
            let port = try XCTUnwrap(address.ipv4?.port)
            let (core, linking) = try await linked(port: port, work: work, claude: claude, token: AgentToken("t1"))
            _ = await core.ended()
            XCTAssertEqual(driver.order.withLock { $0 }.first, "returned", "the conversation went up before the agent ended")
            await linking.value
            XCTAssertEqual(driver.order.withLock { $0 }, ["returned", "ended"], "then the end, as usual")
            let header = try XCTUnwrap(driver.header.withLock { $0 })
            XCTAssertEqual(header.agent.uuid, "a7")
            XCTAssertEqual(header.harness, "claude")
            XCTAssertEqual(header.workingDirectory, work.path)
            XCTAssertEqual(header.sessionID, "fake-session")
            XCTAssertEqual(driver.files.withLock { $0 }, [
                "\(project)/fake-session.jsonl": Data("{\"turn\":\"here\"}\n".utf8),
                "\(project)/fake-session/subagents/agent-a.jsonl": Data("{}\n".utf8),
                "\(project)/memory/MEMORY.md": Data("- a memory\n".utf8),
            ])
            XCTAssertEqual(seen.shown("ReturnConversation"), ["Bearer t1"], "the agent's token, as on every call")
            server.beginGracefulShutdown()
        }
    }

    func testAHandBackToADriverWithoutReturnConversationStillEnds() async throws {
        let claude = try folder("claude")
        let work = try folder("work")
        try write("{}\n", at: "projects/\(ConversationReturn.projectKey(for: work.path))/fake-session.jsonl", in: claude)
        let driver = HandBackDriver(unimplemented: true)
        let transport = HTTP2ServerTransport.Posix(address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext)
        try await withGRPCServer(transport: transport, services: [driver]) { server in
            let address = try await transport.listeningAddress
            let port = try XCTUnwrap(address.ipv4?.port)
            let (core, linking) = try await linked(port: port, work: work, claude: claude)
            let why = await core.ended()
            XCTAssertTrue(why.hasPrefix("the harness ended"), why)
            await linking.value
            XCTAssertEqual(driver.returns.withLock { $0 }, 1, "it was tried")
            XCTAssertEqual(driver.order.withLock { $0 }, ["ended"], "and the end told all the same")
            server.beginGracefulShutdown()
        }
    }

    func testWithNoSessionTheHeaderComesAlone() async throws {
        let claude = try folder("claude")
        let driver = HandBackDriver()
        let transport = HTTP2ServerTransport.Posix(address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext)
        try await withGRPCServer(transport: transport, services: [driver]) { server in
            let address = try await transport.listeningAddress
            let port = try XCTUnwrap(address.ipv4?.port)
            var agent = AgentProtocol_V1_AgentID()
            agent.uuid = "a8"
            let ack = try await ConversationReturn.send(driverURL: "http://127.0.0.1:\(port)", agent: agent, harness: "", workingDirectory: "/w",
                                                        sessionID: "", from: claude)
            XCTAssertEqual(ack.files, 0)
            let header = try XCTUnwrap(driver.header.withLock { $0 })
            XCTAssertEqual(header.agent.uuid, "a8")
            XCTAssertEqual(header.harness, "claude", "the default harness, named")
            XCTAssertEqual(header.sessionID, "")
            XCTAssertEqual(driver.files.withLock { $0 }, [:])
            server.beginGracefulShutdown()
        }
    }

    func testAStopEndsTheAgentAndReturnsNothing() async throws {
        let claude = try folder("claude")
        let work = try folder("work")
        try write("{}\n", at: "projects/\(ConversationReturn.projectKey(for: work.path))/fake-session.jsonl", in: claude)
        let driver = HandBackDriver(stops: true)
        let transport = HTTP2ServerTransport.Posix(address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext)
        try await withGRPCServer(transport: transport, services: [driver]) { server in
            let address = try await transport.listeningAddress
            let port = try XCTUnwrap(address.ipv4?.port)
            let (core, linking) = try await linked(port: port, work: work, claude: claude)
            let why = await core.ended()
            XCTAssertTrue(why.hasPrefix("the harness ended"), why)
            await linking.value
            XCTAssertEqual(driver.returns.withLock { $0 }, 0, "a stop returns no conversation")
            XCTAssertEqual(driver.order.withLock { $0 }, ["ended"])
            server.beginGracefulShutdown()
        }
    }

    func testTheHelloSaysProtocolTwo() {
        XCTAssertEqual(DriverLink.protocolVersion, 2, "a driver may send it hand_back")
        let read = AgentProtocol_V1_DriverMessage.with { $0.handBack = .init() }
        guard case .handBack = try? AgentProtocol_V1_DriverMessage(serializedBytes: read.serializedBytes() as [UInt8]).message else {
            return XCTFail("hand_back goes over the wire")
        }
    }
}
