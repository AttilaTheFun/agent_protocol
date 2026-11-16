import AgentProtocol
import Foundation

/// How a harness is started: its program and arguments, for an agent's
/// spec; or, for `echo`, no program at all (AgentCore answers each message
/// with its words, so a whole flow can be proven without a model).
public struct HarnessLaunch: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    /// Added to the harness's environment (the wrapper's, less its token).
    public var environment: [String: String]

    public init(executable: String, arguments: [String], environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    /// The agent's MCP server, "visor": `command mcp` (agent-wrapper's own
    /// subcommand, MCPStdio), which reaches the wrapper at `socket`.
    public struct MCP: Sendable, Equatable {
        public var command: String
        public var socket: String

        public init(command: String, socket: String) {
            self.command = command
            self.socket = socket
        }

        /// Claude's `--mcp-config`: the server and where it reaches the
        /// wrapper, nothing secret.
        public var config: String {
            let server: [String: Any] = ["type": "stdio", "command": command, "args": ["mcp"], "env": [mcpSocketVariable: socket]]
            let data = (try? JSONSerialization.data(withJSONObject: ["mcpServers": ["visor": server]],
                                                    options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Claude's permission prompt, when the agent asks before acting: the
    /// MCP server's `approve`, which the wrapper answers (MCPRelay).
    public static let permissionPromptTool = "mcp__visor__approve"

    /// The built-in echo harness.
    public static let echo = HarnessLaunch(executable: "", arguments: ["echo"])

    public var isEcho: Bool { self == .echo }

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case unsupported(String)
        case notFound(String)

        public var description: String {
            switch self {
            case .unsupported(let harness): "the harness \(harness) isn't supported yet"
            case .notFound(let name): "\(name) isn't on PATH"
            }
        }
    }

    /// Claude Code in print mode, talking stream JSON both ways, its stdin
    /// kept open for each turn: `claude -p`, for any harness, is the idea.
    /// With `mcp`, the MCP server "visor" (`--mcp-config`), and, when the
    /// agent asks before acting, its `approve` as the permission prompt;
    /// when it acts, `--permission-mode bypassPermissions`. A resumed
    /// session the same. `program` overrides where `claude` is (a test's
    /// stand-in).
    public static func claude(_ spec: AgentProtocol_V1_AgentSpec, program: String? = nil, mcp: MCP? = nil,
                              path: String? = ProcessInfo.processInfo.environment["PATH"]) throws(Problem) -> HarnessLaunch {
        guard let executable = program ?? locate("claude", path: path) else { throw .notFound("claude") }
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        if !spec.model.isEmpty { arguments += ["--model", spec.model] }
        if !spec.resumeSessionID.isEmpty { arguments += ["--resume", spec.resumeSessionID] }
        var environment: [String: String] = [:]
        if let mcp {
            arguments += ["--mcp-config", mcp.config]
            environment[mcpSocketVariable] = mcp.socket
            if !spec.skipPermissions { arguments += ["--permission-prompt-tool", permissionPromptTool] }
        }
        if spec.skipPermissions { arguments += ["--permission-mode", "bypassPermissions"] }
        return HarnessLaunch(executable: executable, arguments: arguments, environment: environment)
    }

    /// The launch for `spec`'s harness ("claude" when it names none).
    public static func `for`(_ spec: AgentProtocol_V1_AgentSpec, claudeProgram: String? = nil, mcp: MCP? = nil) throws(Problem) -> HarnessLaunch {
        switch spec.harness {
        case "claude", "": try claude(spec, program: claudeProgram, mcp: mcp)
        case "echo": .echo
        default: throw .unsupported(spec.harness)
        }
    }

    /// The harness's environment: the wrapper's, without the agent's token
    /// (AGENT_TOKEN), which is the wrapper's to show, not the harness's to
    /// be handed. The wrapper unsets it too (AgentToken.removeFromEnvironment);
    /// neither keeps it from a harness that reads /proc/<wrapper>/environ.
    public static func environment(from wrapper: [String: String]) -> [String: String] {
        wrapper.filter { $0.key != "AGENT_TOKEN" }
    }

    /// This program's own path, for Claude to start it as its MCP server.
    public static func ownPath() -> String {
        if let linked = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") { return linked }
        return Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    /// Where `name` is on `path`, if anywhere.
    static func locate(_ name: String, path: String?) -> String? {
        for folder in (path ?? "/usr/local/bin:/usr/bin:/bin").split(separator: ":") {
            let candidate = "\(folder)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
