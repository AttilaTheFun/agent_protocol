// The built-in echo harness (a whole flow without a model), and the
// wrapper's options as a runner gives them (AGENT_ID, AGENT_JOB, …).

import AgentProtocol
import AgentWrapper
import Foundation
import XCTest

final class EchoAndOptionsTests: XCTestCase {
    func testTheEchoHarnessAnswersEachMessageWithItsWords() async throws {
        var spec = AgentProtocol_V1_AgentSpec()
        spec.harness = "echo"
        spec.prompt = "first"
        let launch = try HarnessLaunch.for(spec)
        XCTAssertTrue(launch.isEcho)
        let core = AgentCore(agent: .init(), spec: spec, launch: launch)
        try await core.start()
        await core.send(id: "m2", text: "second \"quoted\"")
        for _ in 0..<100 {
            let replies = await core.entries.filter { $0.role == .assistant }.map(\.text)
            if replies.count == 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let replies = await core.entries.filter { $0.role == .assistant }.map(\.text)
        XCTAssertEqual(replies, ["echo: first", "echo: second \"quoted\""])
        let session = await core.sessionID
        XCTAssertTrue(session.hasPrefix("echo-"))
        await core.stop()
        let why = await core.ended()
        XCTAssertEqual(why, "the harness ended")
    }

    func testARunnersEnvironmentIsTheJob() throws {
        let job = #"{"agent":"u1","dispatcherURL":"http://d:7434","title":"Fix it","prompt":"Begin","harness":"echo","model":"m","repository":"o/r","ref":"main","labels":["bug"],"workingDirectory":"/w","driverURL":"http://v:7434"}"#
        let options = try WrapperOptions(arguments: [], environment: [
            "AGENT_ID": "u1@http://d:7434", "AGENT_JOB": job, "AGENT_DISPATCHER_URL": "http://d:7434", "AGENT_RUNNER": "mini",
        ])
        XCTAssertEqual(options.agent.uuid, "u1")
        XCTAssertEqual(options.agent.dispatcherURL, "http://d:7434")
        XCTAssertEqual(options.spec.title, "Fix it")
        XCTAssertEqual(options.spec.prompt, "Begin")
        XCTAssertEqual(options.spec.harness, "echo")
        XCTAssertEqual(options.spec.workingDirectory, "/w")
        XCTAssertEqual(options.spec.labels["repository"], "o/r")
        XCTAssertEqual(options.spec.labels["bug"], "")
        XCTAssertEqual(options.driverURL, "http://v:7434", "the job's driver, with no AGENT_DRIVER_URL")
        XCTAssertEqual(options.dispatcherURL, "http://d:7434")
        XCTAssertEqual(options.runner, "mini")
        let driven = try WrapperOptions(arguments: [], environment: ["AGENT_ID": "u1@http://d", "AGENT_JOB": job, "AGENT_DRIVER_URL": "http://elsewhere:1"])
        XCTAssertEqual(driven.driverURL, "http://elsewhere:1", "the environment's driver wins")
        XCTAssertThrowsError(try WrapperOptions(arguments: [], environment: ["AGENT_ID": "no-at-sign"]))
        XCTAssertThrowsError(try WrapperOptions(arguments: ["--agent", "u"], environment: [:]), "no dispatcher")
    }

    /// Job.skip_permissions, as AGENT_JOB's `skipPermissions`: a job that
    /// says true acts (`--permission-mode bypassPermissions`); one that says
    /// false, or nothing, asks through the driver (`--permission-prompt-tool
    /// mcp__visor__approve`); `--skip-permissions` makes any job act.
    func testAJobSaysWhetherItsAgentAsksBeforeActing() throws {
        func options(_ job: String, _ arguments: [String] = []) throws -> WrapperOptions {
            try WrapperOptions(arguments: arguments, environment: ["AGENT_ID": "u1@http://d", "AGENT_JOB": job])
        }
        let skipping = try options(#"{"agent":"u1","harness":"claude","skipPermissions":true}"#)
        let asking = try options(#"{"agent":"u1","harness":"claude","skipPermissions":false}"#)
        let silent = try options(#"{"agent":"u1","harness":"claude"}"#)
        let silentOverridden = try options(#"{"agent":"u1","harness":"claude"}"#, ["--skip-permissions"])
        let overridden = try options(#"{"agent":"u1","harness":"claude","skipPermissions":false}"#, ["--skip-permissions"])
        let odd = try options(#"{"agent":"u1","harness":"claude","skipPermissions":"yes"}"#)
        XCTAssertTrue(skipping.spec.skipPermissions)
        XCTAssertFalse(asking.spec.skipPermissions)
        XCTAssertFalse(silent.spec.skipPermissions, "a job without the field asks")
        XCTAssertTrue(silentOverridden.spec.skipPermissions, "--skip-permissions, for a job without the field")
        XCTAssertTrue(overridden.spec.skipPermissions, "--skip-permissions stays an override")
        XCTAssertFalse(odd.spec.skipPermissions, "only a JSON boolean")

        for acting in [skipping, silentOverridden, overridden] {
            XCTAssertEqual(try Self.permissionArguments(acting), ["--permission-mode", "bypassPermissions"])
        }
        for asker in [asking, silent, odd] {
            XCTAssertEqual(try Self.permissionArguments(asker), ["--permission-prompt-tool", "mcp__visor__approve"])
        }
    }

    /// The launch's permission arguments, with an MCP server (as the
    /// wrapper always starts Claude).
    static func permissionArguments(_ options: WrapperOptions) throws -> [String] {
        let mcp = HarnessLaunch.MCP(command: "/w", socket: "/tmp/s")
        let arguments = try HarnessLaunch.for(options.spec, claudeProgram: "/bin/claude", mcp: mcp).arguments
        return arguments.indices.filter { ["--permission-mode", "--permission-prompt-tool"].contains(arguments[$0]) }
            .flatMap { arguments[$0...($0 + 1)] }
    }

    /// Job.skip_permissions has presence: absent, false and true each come
    /// through the proto's binary and JSON forms as themselves.
    func testSkipPermissionsHasPresence() throws {
        let absent = AgentProtocol_V1_Job.with { $0.title = "t" }
        let no = AgentProtocol_V1_Job.with { $0.title = "t"; $0.skipPermissions = false }
        let yes = AgentProtocol_V1_Job.with { $0.title = "t"; $0.skipPermissions = true }
        XCTAssertFalse(absent.hasSkipPermissions)
        XCTAssertTrue(no.hasSkipPermissions, "false, said, is present")
        for (job, has, value) in [(absent, false, false), (no, true, false), (yes, true, true)] {
            let binary = try AgentProtocol_V1_Job(serializedBytes: try job.serializedBytes() as [UInt8])
            XCTAssertEqual(binary.hasSkipPermissions, has)
            XCTAssertEqual(binary.skipPermissions, value)
            let json = try AgentProtocol_V1_Job(jsonString: try job.jsonString())
            XCTAssertEqual(json.hasSkipPermissions, has)
            XCTAssertEqual(json.skipPermissions, value)
            XCTAssertEqual(json, job)
        }
        XCTAssertEqual(try absent.jsonString(), #"{"title":"t"}"#, "absent: no key")
        XCTAssertEqual(try no.jsonString(), #"{"title":"t","skipPermissions":false}"#, "the same name as AGENT_JOB's key")
        XCTAssertEqual(try yes.jsonString(), #"{"title":"t","skipPermissions":true}"#)
        XCTAssertFalse(try AgentProtocol_V1_Job(jsonString: #"{"title":"old"}"#).hasSkipPermissions, "a dispatcher that says nothing")
        XCTAssertNotEqual(try no.serializedBytes() as [UInt8], try absent.serializedBytes() as [UInt8], "false is on the wire")
    }

    /// A runner as the README says: `skipPermissions` in AGENT_JOB only when
    /// the job has it; `--skip-permissions` when it hasn't (an old driver,
    /// Visor 0.59.1) or it is true. Absent acts, as runners' agents always
    /// have; false asks; true acts.
    func testARunnerPassesSkipPermissionsOnAsTheREADMESays() throws {
        func run(_ job: AgentProtocol_V1_Job) throws -> (agentJob: [String: Any], arguments: [String], options: WrapperOptions) {
            var agentJob: [String: Any] = ["agent": "u1", "harness": "claude", "title": job.title]
            if job.hasSkipPermissions { agentJob["skipPermissions"] = job.skipPermissions }
            let arguments = !job.hasSkipPermissions || job.skipPermissions ? ["--skip-permissions"] : []
            let text = String(decoding: try JSONSerialization.data(withJSONObject: agentJob, options: [.sortedKeys]), as: UTF8.self)
            let options = try WrapperOptions(arguments: arguments, environment: ["AGENT_ID": "u1@http://d", "AGENT_JOB": text])
            return (agentJob, arguments, options)
        }
        let absent = try run(.with { $0.title = "old" })
        XCTAssertNil(absent.agentJob["skipPermissions"], "no key when the job has none")
        XCTAssertEqual(absent.arguments, ["--skip-permissions"])
        XCTAssertEqual(try Self.permissionArguments(absent.options), ["--permission-mode", "bypassPermissions"])

        let no = try run(.with { $0.title = "asks"; $0.skipPermissions = false })
        XCTAssertEqual(no.agentJob["skipPermissions"] as? Bool, false)
        XCTAssertEqual(no.arguments, [])
        XCTAssertEqual(try Self.permissionArguments(no.options), ["--permission-prompt-tool", "mcp__visor__approve"])

        let yes = try run(.with { $0.title = "acts"; $0.skipPermissions = true })
        XCTAssertEqual(yes.agentJob["skipPermissions"] as? Bool, true)
        XCTAssertEqual(yes.arguments, ["--skip-permissions"])
        XCTAssertEqual(try Self.permissionArguments(yes.options), ["--permission-mode", "bypassPermissions"])
    }
}
