// The built-in echo harness (a whole flow without a model), and the
// wrapper's options as a runner gives them (AGENT_ID, AGENT_JOB, …).

import AgentProtocol
import AgentWrapper
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
    /// says so acts (`--permission-mode bypassPermissions`); one that doesn't,
    /// or says false, asks through the driver (`--permission-prompt-tool
    /// mcp__visor__approve`); `--skip-permissions` makes any job act.
    func testAJobSaysWhetherItsAgentAsksBeforeActing() throws {
        func options(_ job: String, _ arguments: [String] = []) throws -> WrapperOptions {
            try WrapperOptions(arguments: arguments, environment: ["AGENT_ID": "u1@http://d", "AGENT_JOB": job])
        }
        let skipping = try options(#"{"agent":"u1","harness":"claude","skipPermissions":true}"#)
        let asking = try options(#"{"agent":"u1","harness":"claude","skipPermissions":false}"#)
        let silent = try options(#"{"agent":"u1","harness":"claude"}"#)
        let overridden = try options(#"{"agent":"u1","harness":"claude","skipPermissions":false}"#, ["--skip-permissions"])
        let odd = try options(#"{"agent":"u1","harness":"claude","skipPermissions":"yes"}"#)
        XCTAssertTrue(skipping.spec.skipPermissions)
        XCTAssertFalse(asking.spec.skipPermissions)
        XCTAssertFalse(silent.spec.skipPermissions, "a job without the field asks")
        XCTAssertTrue(overridden.spec.skipPermissions, "--skip-permissions stays an override")
        XCTAssertFalse(odd.spec.skipPermissions, "only a JSON boolean")

        let mcp = HarnessLaunch.MCP(command: "/w", socket: "/tmp/s")
        func launch(_ options: WrapperOptions) throws -> [String] {
            try HarnessLaunch.for(options.spec, claudeProgram: "/bin/claude", mcp: mcp).arguments
        }
        for acting in [skipping, overridden] {
            let arguments = try launch(acting)
            XCTAssertEqual(arguments.suffix(2), ["--permission-mode", "bypassPermissions"])
            XCTAssertFalse(arguments.contains("--permission-prompt-tool"))
        }
        for asker in [asking, silent] {
            let arguments = try launch(asker)
            XCTAssertEqual(arguments.suffix(2), ["--permission-prompt-tool", "mcp__visor__approve"])
            XCTAssertFalse(arguments.contains("--permission-mode"))
        }

        let job = AgentProtocol_V1_Job.with { $0.skipPermissions = true }
        XCTAssertTrue(try AgentProtocol_V1_Job(serializedBytes: try job.serializedBytes() as [UInt8]).skipPermissions)
        XCTAssertEqual(try job.jsonString(), #"{"skipPermissions":true}"#, "the same name as AGENT_JOB's key")
        XCTAssertFalse(try AgentProtocol_V1_Job(jsonString: #"{"title":"old"}"#).skipPermissions, "a dispatcher that says nothing")
    }
}
