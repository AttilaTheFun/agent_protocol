// The agent's token: carried in the Job, handed to the wrapper in
// AGENT_TOKEN, kept from the harness, and shown as metadata on each call
// the wrapper makes for the agent (its driver's Connect and Conversation,
// its dispatcher's Report), a fresh one from the driver shown from then on;
// and a runner's, on its Renew and Report, a fresh one from a renewal
// (RenewResponse.token) shown from then on.

import AgentProtocol
import AgentWrapper
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Synchronization
import XCTest

/// Each call's method and its `authorization` metadata ("" for none).
final class SeenCalls: ServerInterceptor {
    let calls = Mutex<[String]>([])

    func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingServerRequest<Input>,
        context: ServerContext,
        next: @Sendable (StreamingServerRequest<Input>, ServerContext) async throws -> StreamingServerResponse<Output>
    ) async throws -> StreamingServerResponse<Output> {
        let shown = request.metadata[stringValues: AgentToken.metadataKey].first { _ in true } ?? ""
        calls.withLock { $0.append("\(context.descriptor.method) \(shown)") }
        return try await next(request, context)
    }

    func shown(_ method: String) -> [String] {
        calls.withLock { $0.filter { $0.hasPrefix(method + " ") }.map { String($0.dropFirst(method.count + 1)) } }
    }
}

/// A dispatcher that takes every report.
final class TestDispatcher: AgentProtocol_V1_AgentDispatcher.SimpleServiceProtocol {
    func claim(request: AgentProtocol_V1_ClaimRequest, context: ServerContext) async throws -> AgentProtocol_V1_ClaimResponse {
        .init()
    }

    func report(request: AgentProtocol_V1_JobReport, context: ServerContext) async throws -> AgentProtocol_V1_ReportResponse {
        .init()
    }

    func renew(request: AgentProtocol_V1_RenewRequest, context: ServerContext) async throws -> AgentProtocol_V1_RenewResponse {
        .init()
    }
}

/// A dispatcher whose renewals hand out the tokens given, in turn (""
/// for none, as an older dispatcher), each with a later expiry.
final class RefreshingDispatcher: AgentProtocol_V1_AgentDispatcher.SimpleServiceProtocol {
    let fresh: Mutex<[String]>

    init(fresh: [String]) {
        self.fresh = Mutex(fresh)
    }

    func claim(request: AgentProtocol_V1_ClaimRequest, context: ServerContext) async throws -> AgentProtocol_V1_ClaimResponse {
        .init()
    }

    func report(request: AgentProtocol_V1_JobReport, context: ServerContext) async throws -> AgentProtocol_V1_ReportResponse {
        .init()
    }

    func renew(request: AgentProtocol_V1_RenewRequest, context: ServerContext) async throws -> AgentProtocol_V1_RenewResponse {
        let token = fresh.withLock { $0.isEmpty ? "" : $0.removeFirst() }
        return .with {
            $0.claimExpires = .init(date: Date().addingTimeInterval(60))
            $0.token = token
        }
    }
}

/// A runner's part as the README has it: its bearer on Renew and Report is
/// Job.token until a renewal hands it a fresh one (RenewResponse.token),
/// which it holds from then on; an empty one leaves it as it was.
struct ReadmeRunner {
    let client: AgentProtocol_V1_AgentDispatcher.Client<HTTP2ClientTransport.Posix>
    let agent: AgentProtocol_V1_AgentID
    let token: AgentToken

    init(client: AgentProtocol_V1_AgentDispatcher.Client<HTTP2ClientTransport.Posix>, job: AgentProtocol_V1_Job) {
        self.client = client
        agent = job.agent
        token = AgentToken(job.token)
    }

    func renew() async throws {
        let response = try await client.renew(.with { $0.agent = agent }, metadata: token.metadata)
        token.replace(with: response.token)
    }

    func release(reason: String) async throws {
        _ = try await client.report(.with { $0.agent = agent; $0.released = .with { $0.reason = reason } }, metadata: token.metadata)
    }
}

/// A driver that sends a fresh token on the first connection, then drops
/// it, so the wrapper connects again.
final class RefreshingDriver: AgentProtocol_V1_AgentDriver.SimpleServiceProtocol {
    let connections = Mutex(0)

    func connect(request: RPCAsyncSequence<AgentProtocol_V1_WrapperMessage, any Error>,
                 response: RPCWriter<AgentProtocol_V1_DriverMessage>, context: ServerContext) async throws {
        let first = connections.withLock { count in
            count += 1
            return count == 1
        }
        if first {
            try await response.write(.with { $0.token = "fresh" })
            throw RPCError(code: .unavailable, message: "dropped, to be connected again")
        }
        for try await _ in request {}
    }

    func conversation(request: AgentProtocol_V1_ConversationRequest, response: RPCWriter<AgentProtocol_V1_ConversationFile>,
                      context: ServerContext) async throws {}
}

final class AgentTokenTests: XCTestCase {
    func testTheJobAndTheDriverCarryTheToken() throws {
        let job = AgentProtocol_V1_Job.with { $0.title = "t"; $0.token = "tok" }
        XCTAssertEqual(try AgentProtocol_V1_Job(serializedBytes: try job.serializedBytes() as [UInt8]).token, "tok")
        XCTAssertTrue(try job.jsonString().contains(#""token":"tok""#))
        XCTAssertEqual(try AgentProtocol_V1_Job(jsonString: #"{"title":"old"}"#).token, "", "a dispatcher that mints none")
        let fresh = AgentProtocol_V1_DriverMessage.with { $0.token = "t2" }
        let read = try AgentProtocol_V1_DriverMessage(serializedBytes: try fresh.serializedBytes() as [UInt8])
        guard case .token(let token) = read.message else { return XCTFail("a fresh token") }
        XCTAssertEqual(token, "t2")
    }

    func testARenewalCarriesAFreshToken() throws {
        let renewed = AgentProtocol_V1_RenewResponse.with { $0.claimExpires = .init(seconds: 100); $0.token = "fresh" }
        let read = try AgentProtocol_V1_RenewResponse(serializedBytes: try renewed.serializedBytes() as [UInt8])
        XCTAssertEqual(read.token, "fresh")
        XCTAssertEqual(read.claimExpires.seconds, 100)
        XCTAssertEqual(try AgentProtocol_V1_RenewResponse(jsonString: try renewed.jsonString()).token, "fresh")
        XCTAssertTrue(try renewed.jsonString().contains(#""token":"fresh""#))
        // An older dispatcher's renewal: no token, so the runner keeps its own.
        let older = AgentProtocol_V1_RenewResponse.with { $0.claimExpires = .init(seconds: 100) }
        XCTAssertEqual(try AgentProtocol_V1_RenewResponse(serializedBytes: try older.serializedBytes() as [UInt8]).token, "")
        XCTAssertEqual(try AgentProtocol_V1_RenewResponse(jsonString: #"{"claimExpires":"1970-01-01T00:01:40Z"}"#).token, "")
    }

    func testARunnerTakesAFreshTokenFromARenewal() async throws {
        let seen = SeenCalls()
        let transport = HTTP2ServerTransport.Posix(address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext)
        // A fresh token, then a renewal with none, then another fresh one.
        let dispatcher = RefreshingDispatcher(fresh: ["t2", "", "t3"])
        try await withGRPCServer(transport: transport, services: [dispatcher], interceptors: [seen]) { server in
            let address = try await transport.listeningAddress
            let port = try XCTUnwrap(address.ipv4?.port)
            let client = try HTTP2ClientTransport.Posix(target: .ipv4(host: "127.0.0.1", port: port), transportSecurity: .plaintext)
            try await withGRPCClient(transport: client) { grpc in
                let job = AgentProtocol_V1_Job.with { $0.agent.uuid = "a5"; $0.token = "t1" }
                let runner = ReadmeRunner(client: AgentProtocol_V1_AgentDispatcher.Client(wrapping: grpc), job: job)
                try await runner.renew()
                XCTAssertEqual(runner.token.value, "t2")
                try await runner.renew()
                XCTAssertEqual(runner.token.value, "t2", "an empty one leaves it")
                try await runner.release(reason: "done")
                try await runner.renew()
                try await runner.release(reason: "done")
                XCTAssertEqual(seen.shown("Renew"), ["Bearer t1", "Bearer t2", "Bearer t2"])
                XCTAssertEqual(seen.shown("Report"), ["Bearer t2", "Bearer t3"])
            }
            server.beginGracefulShutdown()
        }
    }

    func testARunnerKeepsItsTokenWithAnOlderDispatcher() async throws {
        let seen = SeenCalls()
        let transport = HTTP2ServerTransport.Posix(address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext)
        try await withGRPCServer(transport: transport, services: [TestDispatcher()], interceptors: [seen]) { server in
            let address = try await transport.listeningAddress
            let port = try XCTUnwrap(address.ipv4?.port)
            let client = try HTTP2ClientTransport.Posix(target: .ipv4(host: "127.0.0.1", port: port), transportSecurity: .plaintext)
            try await withGRPCClient(transport: client) { grpc in
                let job = AgentProtocol_V1_Job.with { $0.agent.uuid = "a6"; $0.token = "t1" }
                let runner = ReadmeRunner(client: AgentProtocol_V1_AgentDispatcher.Client(wrapping: grpc), job: job)
                try await runner.renew()
                try await runner.renew()
                try await runner.release(reason: "done")
                XCTAssertEqual(runner.token.value, "t1")
                XCTAssertEqual(seen.shown("Renew"), ["Bearer t1", "Bearer t1"])
                XCTAssertEqual(seen.shown("Report"), ["Bearer t1"])
            }
            server.beginGracefulShutdown()
        }
    }

    func testTheTokenComesFromTheEnvironmentAlone() throws {
        let job = #"{"agent":"u1","harness":"echo","token":"in-the-job"}"#
        let options = try WrapperOptions(arguments: [], environment: ["AGENT_ID": "u1@http://d", "AGENT_JOB": job, "AGENT_TOKEN": "secret"])
        XCTAssertEqual(options.token, "secret")
        let none = try WrapperOptions(arguments: [], environment: ["AGENT_ID": "u1@http://d", "AGENT_JOB": job])
        XCTAssertNil(none.token, "not from AGENT_JOB")
        XCTAssertThrowsError(try WrapperOptions(arguments: ["--token", "t"], environment: ["AGENT_ID": "u1@http://d"]), "no flag")
    }

    func testTheHarnessIsNotGivenTheToken() {
        let environment = HarnessLaunch.environment(from: ["AGENT_TOKEN": "secret", "AGENT_ID": "u1@http://d", "PATH": "/bin"])
        XCTAssertEqual(environment, ["AGENT_ID": "u1@http://d", "PATH": "/bin"])
    }

    func testTheTokenIsUnsetSoNoChildInheritsIt() throws {
        setenv("AGENT_TOKEN", "secret", 1)
        AgentToken.removeFromEnvironment()
        XCTAssertNil(getenv("AGENT_TOKEN"))
        XCTAssertNil(ProcessInfo.processInfo.environment["AGENT_TOKEN"])
        // A child started with the environment as it is now.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "printf %s \"${AGENT_TOKEN-unset}\""]
        let output = Pipe()
        child.standardOutput = output
        try child.run()
        child.waitUntilExit()
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "unset")
    }

    func testTheMetadataIsTheBearerToken() {
        XCTAssertEqual(Array(AgentToken().metadata[stringValues: AgentToken.metadataKey]), [])
        let token = AgentToken("t1")
        XCTAssertEqual(Array(token.metadata[stringValues: "authorization"]), ["Bearer t1"])
        token.replace(with: "")
        XCTAssertEqual(token.value, "t1", "an empty one is ignored")
        token.replace(with: "t2")
        XCTAssertEqual(Array(token.metadata[stringValues: "authorization"]), ["Bearer t2"])
    }

    func testEachCallForTheAgentShowsItsToken() async throws {
        let seen = SeenCalls()
        let transport = HTTP2ServerTransport.Posix(address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext)
        try await withGRPCServer(transport: transport, services: [TestDriver(), TestDispatcher()], interceptors: [seen]) { server in
            let address = try await transport.listeningAddress
            let port = try XCTUnwrap(address.ipv4?.port)
            let url = "http://127.0.0.1:\(port)"
            let token = AgentToken("t1")
            var agent = AgentProtocol_V1_AgentID()
            agent.uuid = "a3"
            agent.dispatcherURL = url

            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            _ = try await ResumePreparation.fetchConversation(
                driverURL: url, agent: agent, workingDirectory: "/work", harness: "claude", token: token, into: folder)
            XCTAssertEqual(seen.shown("Conversation"), ["Bearer t1"])

            try await XCTUnwrap(DispatcherReports(url: url, agent: agent, runner: "r", token: token)).started(session: "s1")
            try await XCTUnwrap(DispatcherReports(url: url, agent: agent, runner: "r")).started(session: "s2")
            XCTAssertEqual(seen.shown("Report"), ["Bearer t1", ""], "none when the job had none")

            var spec = AgentProtocol_V1_AgentSpec()
            spec.harness = "echo"
            let core = AgentCore(agent: agent, spec: spec, launch: .echo)
            try await core.start()
            let link = try XCTUnwrap(DriverLink(url: url, core: core, hostName: "test-host", token: token))
            let linking = Task { await link.run() }
            for _ in 0..<200 where seen.shown("Connect").isEmpty { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertEqual(seen.shown("Connect"), ["Bearer t1"])
            await core.stop()
            _ = await core.ended()
            await linking.value
            server.beginGracefulShutdown()
        }
    }

    func testAFreshTokenFromTheDriverIsShownFromThenOn() async throws {
        let seen = SeenCalls()
        let transport = HTTP2ServerTransport.Posix(address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext)
        try await withGRPCServer(transport: transport, services: [RefreshingDriver()], interceptors: [seen]) { server in
            let address = try await transport.listeningAddress
            let port = try XCTUnwrap(address.ipv4?.port)
            var spec = AgentProtocol_V1_AgentSpec()
            spec.harness = "echo"
            var agent = AgentProtocol_V1_AgentID()
            agent.uuid = "a4"
            let core = AgentCore(agent: agent, spec: spec, launch: .echo)
            try await core.start()
            let token = AgentToken("t1")
            let link = try XCTUnwrap(DriverLink(url: "http://127.0.0.1:\(port)", core: core, hostName: "test-host", token: token))
            let linking = Task { await link.run() }
            for _ in 0..<200 where seen.shown("Connect").count < 2 { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertEqual(seen.shown("Connect"), ["Bearer t1", "Bearer fresh"], "connected again with the fresh one")
            XCTAssertEqual(token.value, "fresh")
            await core.stop()
            _ = await core.ended()
            await linking.value
            server.beginGracefulShutdown()
        }
    }
}
