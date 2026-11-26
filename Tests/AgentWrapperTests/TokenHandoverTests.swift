// The agent's token handed over outside any environment (agent_protocol#17):
// on a descriptor (AGENT_TOKEN_FD), read to its end and closed, or in a
// 0600 file (AGENT_TOKEN_FILE), read and deleted; AGENT_TOKEN still taken,
// deprecated. And, on Linux, agent-wrapper itself as a runner starts it:
// the token shown to its dispatcher, none in its harness's environment, and
// the wrapper undumpable, so its harness (the same user) is refused its
// /proc/<pid>/environ, fd and mem, while the harness reads its own.

import AgentProtocol
import AgentWrapper
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Synchronization
import XCTest

final class TokenHandoverTests: XCTestCase {
    let base = ["AGENT_ID": "u1@http://d", "AGENT_JOB": #"{"harness":"echo"}"#]

    func options(_ extra: [String: String]) throws -> WrapperOptions {
        try WrapperOptions(arguments: [], environment: base.merging(extra) { $1 })
    }

    /// What `take` logs, kept.
    final class Lines: @unchecked Sendable {
        var lines: [String] = []
        func log(_ line: String) { lines.append(line) }
    }

    func testTheOptionsSayHowTheTokenComes() throws {
        XCTAssertEqual(try options(["AGENT_TOKEN_FD": "3"]).tokenDescriptor, 3)
        XCTAssertEqual(try options(["AGENT_TOKEN_FILE": "/run/agent/tokens/a.token"]).tokenFile, "/run/agent/tokens/a.token")
        XCTAssertNil(try options(["AGENT_TOKEN_FD": ""]).tokenDescriptor, "empty is unset")
        XCTAssertThrowsError(try options(["AGENT_TOKEN_FD": "three"]))
        XCTAssertThrowsError(try options(["AGENT_TOKEN_FD": "-1"]))
        XCTAssertThrowsError(try options(["AGENT_TOKEN_FD": "3", "AGENT_TOKEN_FILE": "/run/t"]), "one way, not two")
    }

    func testTheDescriptorIsReadToItsEndAndClosed() throws {
        var ends: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&ends), 0)
        XCTAssertEqual(write(ends[1], "eyJ.token.sig\n", 14), 14)
        close(ends[1])
        let lines = Lines()
        let token = try TokenHandover.take(try options(["AGENT_TOKEN_FD": "\(ends[0])"]), log: lines.log)
        XCTAssertEqual(token, "eyJ.token.sig", "less its newline")
        XCTAssertEqual(fcntl(ends[0], F_GETFD), -1, "closed")
        XCTAssertEqual(errno, EBADF)
        XCTAssertEqual(lines.lines, [])
    }

    func testTheFileIsReadAndDeleted() throws {
        let file = try privateFile("eyJ.token.sig\n", mode: 0o600)
        let lines = Lines()
        let token = try TokenHandover.take(try options(["AGENT_TOKEN_FILE": file]), log: lines.log)
        XCTAssertEqual(token, "eyJ.token.sig")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file), "gone once read")
        XCTAssertFalse(lines.lines.contains { $0.contains("eyJ") }, "the token is never logged")
    }

    /// A file others could read isn't taken: it's deleted unread, and the
    /// wrapper won't start. Nor is a link.
    func testAFileOthersCanReadIsRefused() throws {
        let file = try privateFile("t", mode: 0o644)
        XCTAssertThrowsError(try TokenHandover.take(try options(["AGENT_TOKEN_FILE": file]), log: { _ in })) {
            XCTAssertEqual($0 as? TokenHandover.Problem, .notPrivate(file))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
        let target = try privateFile("t", mode: 0o600)
        let link = target + ".link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        XCTAssertThrowsError(try TokenHandover.take(try options(["AGENT_TOKEN_FILE": link]), log: { _ in }), "a link isn't followed")
        try? FileManager.default.removeItem(atPath: target)
        try? FileManager.default.removeItem(atPath: link)
    }

    /// AGENT_TOKEN, as before, with a line saying it's deprecated; beside a
    /// descriptor, ignored.
    func testTheEnvironmentIsStillTakenDeprecated() throws {
        let lines = Lines()
        XCTAssertEqual(try TokenHandover.take(try options(["AGENT_TOKEN": "from-env"]), log: lines.log), "from-env")
        XCTAssertEqual(lines.lines.count, 1)
        XCTAssertTrue(lines.lines[0].contains("deprecated"), lines.lines[0])
        XCTAssertFalse(lines.lines[0].contains("from-env"))

        var ends: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&ends), 0)
        XCTAssertEqual(write(ends[1], "from-fd", 7), 7)
        close(ends[1])
        let both = Lines()
        XCTAssertEqual(try TokenHandover.take(try options(["AGENT_TOKEN": "from-env", "AGENT_TOKEN_FD": "\(ends[0])"]), log: both.log), "from-fd")
        XCTAssertEqual(both.lines, ["AGENT_TOKEN is ignored: the token came on AGENT_TOKEN_FD"])
        XCTAssertEqual(try TokenHandover.take(try options([:]), log: lines.log), "", "none")
    }

    func privateFile(_ text: String, mode: Int) throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("token-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("agent.token").path
        XCTAssertTrue(FileManager.default.createFile(atPath: file, contents: Data(text.utf8), attributes: [.posixPermissions: mode]))
        return file
    }

    #if os(Linux)
    /// A stand-in for Claude that looks for the token where a hostile one
    /// would: its own environment, and the wrapper's (its parent's)
    /// /proc/<pid>/environ, fd and mem, each opened as a process of the
    /// same user, and its own /proc/self/environ (dumpable again from its
    /// exec). It writes what it found to STAND_IN_REPORT, then says its
    /// session and ends.
    static let standIn = FakeClaude.write(#"""
    import errno, json, os, sys
    wrapper = os.getppid()
    def tried(path, folder=False):
        try:
            if folder:
                os.listdir(path)
            else:
                os.close(os.open(path, os.O_RDONLY))
            return "opened"
        except OSError as e:
            return errno.errorcode.get(e.errno, str(e.errno))
    found = {"environment": sorted(k for k in os.environ if k.startswith("AGENT_TOKEN")),
             "token in environment": any("eyJ" in v for v in os.environ.values()),
             "environ": tried("/proc/%d/environ" % wrapper),
             "fd": tried("/proc/%d/fd" % wrapper, folder=True),
             "fd/0": tried("/proc/%d/fd/0" % wrapper),
             "mem": tried("/proc/%d/mem" % wrapper),
             "cmdline": tried("/proc/%d/cmdline" % wrapper),
             "own environ": tried("/proc/self/environ"),
             "arguments": sys.argv[1:]}
    with open(os.environ["STAND_IN_REPORT"], "w") as report:
        json.dump(found, report)
    print(json.dumps({"type": "system", "subtype": "init", "session_id": "stand-in", "model": "m"}), flush=True)
    """#)

    /// agent-wrapper, as SwiftPM built it beside the tests.
    func wrapperProgram() throws -> String {
        let folders = [Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent(),
                       URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()].compactMap { $0 }
        for folder in folders {
            for candidate in [folder, folder.deletingLastPathComponent()] {
                let path = candidate.appendingPathComponent("agent-wrapper").path
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
        }
        XCTFail("no agent-wrapper beside the tests in \(folders.map(\.path)): swift build --build-tests first")
        throw CocoaError(.fileNoSuchFile)
    }

    /// Whether this process may read any process's memory anyway (root
    /// with CAP_SYS_PTRACE, bit 19 of CapEff), which undumpable doesn't stop.
    func mayTraceAnything() -> Bool {
        let status = (try? String(contentsOfFile: "/proc/self/status", encoding: .utf8)) ?? ""
        guard let line = status.split(separator: "\n").first(where: { $0.hasPrefix("CapEff:") }),
              let caps = UInt64(line.dropFirst("CapEff:".count).trimmingCharacters(in: .whitespaces), radix: 16)
        else { return false }
        return caps & (1 << 19) != 0
    }

    /// agent-wrapper run as a runner runs it, with `handover` set (and
    /// `input` its standard input), against a dispatcher that keeps each
    /// call's bearer: what its stand-in found, the bearers its reports
    /// showed, and what it logged.
    func runWrapper(_ handover: [String: String], input: String? = nil) async throws -> (found: [String: Any], shown: [String], log: String) {
        if mayTraceAnything() { throw XCTSkip("this process has CAP_SYS_PTRACE, which reads an undumpable process's /proc all the same") }
        let program = try wrapperProgram()
        let report = FileManager.default.temporaryDirectory.appendingPathComponent("stand-in-\(UUID().uuidString.prefix(8)).json").path
        let seen = SeenCalls()
        let transport = HTTP2ServerTransport.Posix(address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext)
        var log = ""
        try await withGRPCServer(transport: transport, services: [TestDispatcher()], interceptors: [seen]) { server in
            let port = try XCTUnwrap(try await transport.listeningAddress.ipv4?.port)
            let wrapper = Process()
            wrapper.executableURL = URL(fileURLWithPath: program)
            wrapper.arguments = ["--skip-permissions"]
            wrapper.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("AGENT_") }.merging([
                "AGENT_ID": "\(UUID().uuidString.lowercased())@http://127.0.0.1:\(port)",
                "AGENT_JOB": #"{"harness":"claude","prompt":""}"#,
                "AGENT_DISPATCHER_URL": "http://127.0.0.1:\(port)",
                "AGENT_RUNNER": "tests",
                "AGENT_WRAPPER_CLAUDE": Self.standIn,
                "STAND_IN_REPORT": report,
            ].merging(handover) { $1 }) { $1 }
            let stdin = Pipe(), stderr = Pipe()
            wrapper.standardInput = stdin
            wrapper.standardOutput = FileHandle.nullDevice
            wrapper.standardError = stderr
            try wrapper.run()
            if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
            try stdin.fileHandleForWriting.close()
            let logged = stderr.fileHandleForReading.readDataToEndOfFile()
            wrapper.waitUntilExit()
            log = String(decoding: logged, as: UTF8.self)
            XCTAssertEqual(wrapper.terminationStatus, 0, log)
            server.beginGracefulShutdown()
        }
        let found = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: report))) as? [String: Any], log)
        try? FileManager.default.removeItem(atPath: report)
        return (found, seen.shown("Report"), log)
    }

    /// What every handover must leave: the token in no environment of the
    /// harness's, and the wrapper's /proc refused it (EACCES), while it
    /// reads its own; agent-wrapper's own path (/proc/self/exe, read while
    /// undumpable) given to Claude for its MCP server.
    func checkHarnessSawNothing(_ found: [String: Any], log: String) {
        XCTAssertEqual(found["environment"] as? [String], [], log)
        XCTAssertEqual(found["token in environment"] as? Bool, false)
        for refused in ["environ", "fd", "fd/0", "mem"] {
            XCTAssertEqual(found[refused] as? String, "EACCES", "the harness opening /proc/<wrapper>/\(refused)")
        }
        XCTAssertEqual(found["cmdline"] as? String, "opened", "cmdline stays readable, as ps needs")
        XCTAssertEqual(found["own environ"] as? String, "opened", "the harness, dumpable from its exec, reads its own /proc")
        let arguments = (found["arguments"] as? [String] ?? []).joined(separator: " ")
        let program = URL(fileURLWithPath: (try? wrapperProgram()) ?? "?").resolvingSymlinksInPath().path
        XCTAssertTrue(arguments.contains(#""command":"\#(program)""#), arguments)
        XCTAssertFalse(log.contains("eyJ"), "the token is never logged")
    }

    func testTheWrapperTakesItsTokenOnStandardInput() async throws {
        let run = try await runWrapper(["AGENT_TOKEN_FD": "0"], input: "eyJ.fd.sig\n")
        XCTAssertEqual(run.shown.last, "Bearer eyJ.fd.sig", run.log)
        checkHarnessSawNothing(run.found, log: run.log)
        XCTAssertFalse(run.log.contains("deprecated"), run.log)
    }

    func testTheWrapperTakesItsTokenFromAFileItDeletes() async throws {
        let folder = FileManager.default.fileExists(atPath: "/dev/shm") ? URL(fileURLWithPath: "/dev/shm") : FileManager.default.temporaryDirectory
        let file = folder.appendingPathComponent("agent-\(UUID().uuidString.prefix(8)).token").path
        XCTAssertTrue(FileManager.default.createFile(atPath: file, contents: Data("eyJ.file.sig\n".utf8), attributes: [.posixPermissions: 0o600]))
        let run = try await runWrapper(["AGENT_TOKEN_FILE": file])
        XCTAssertEqual(run.shown.last, "Bearer eyJ.file.sig", run.log)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file), "the file is gone")
        checkHarnessSawNothing(run.found, log: run.log)
    }

    /// The fallback: the token in AGENT_TOKEN still works, logged as
    /// deprecated, and the wrapper's environ (which holds it) is refused.
    func testTheWrapperStillTakesAGENT_TOKEN() async throws {
        let run = try await runWrapper(["AGENT_TOKEN": "eyJ.env.sig"])
        XCTAssertEqual(run.shown.last, "Bearer eyJ.env.sig", run.log)
        XCTAssertTrue(run.log.contains("the token came in AGENT_TOKEN, which is deprecated"), run.log)
        checkHarnessSawNothing(run.found, log: run.log.replacingOccurrences(of: "eyJ.env.sig", with: ""))
    }
    #endif
}
