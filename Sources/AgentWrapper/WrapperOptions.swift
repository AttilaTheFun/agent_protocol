import AgentProtocol
import Foundation

/// What the wrapper is told to run. As a runner starts it, from the
/// environment (Shireworks' contract, 12 Nov 2026):
///
/// - `AGENT_ID`: `<uuid>@<dispatcher URL>`;
/// - `AGENT_JOB`: the job as JSON, `{agent, dispatcherURL, title, prompt,
///   sourceURL, repository, ref, harness?, model?, effort?, labels,
///   workingDirectory?, driverURL?, resumeSessionID?, sources?}`, where
///   `sources` is `[{repository, ref, name}]`;
/// - `AGENT_DISPATCHER_URL`: whom it reports Started, Completed and Failed to;
/// - `AGENT_DRIVER_URL`: the driver it dials, if any;
/// - `AGENT_RUNNER`: the runner's name;
/// - `AGENT_SESSIONS_DIR`: where the runner keeps sessions; a job with no
///   working directory works in `<dir>/Claude/<agent>` there (refused
///   unless the agent's id is a UUID and its harness one folder's name);
/// - `AGENT_SOURCES_DIR`: where a resumed session's `sources` are cloned;
/// - `AGENT_TOKEN`: the agent's token (Job.token), if its job had one:
///   shown to its driver and dispatcher (AgentToken), and never given to
///   the harness. Only here: not in AGENT_JOB, and no flag, so it stays off
///   every command line.
///
/// By hand, the same as flags:
///
///     agent-wrapper --agent <uuid> --dispatcher <url> [--harness claude|echo] [--model m] [--effort e]
///                   [--cwd dir] [--title t] [--prompt text] [--resume id] [--skip-permissions] [--label key=value]…
///
/// AGENT_WRAPPER_CLAUDE stands in for `claude`.
public struct WrapperOptions: Sendable, Equatable {
    public var agent = AgentProtocol_V1_AgentID()
    public var spec = AgentProtocol_V1_AgentSpec()
    public var driverURL: String?
    public var dispatcherURL: String?
    public var runner: String?
    public var claudeProgram: String?
    /// A resumed session's repositories (AGENT_JOB's `sources`), cloned
    /// under `sourcesDirectory` before it starts.
    public var sources: [AgentProtocol_V1_Source] = []
    /// Where the runner keeps sources (AGENT_SOURCES_DIR: /Volumes/Sources).
    public var sourcesDirectory: String?
    /// The agent's token (AGENT_TOKEN), if any.
    public var token: String?

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case missing(String)
        case unknown(String)
        case bad(String)

        public var description: String {
            switch self {
            case .missing(let what): "\(what) is needed"
            case .unknown(let what): "\(what)?"
            case .bad(let what): what
            }
        }
    }

    public static let usage = """
        Usage: agent-wrapper --agent <uuid> --dispatcher <url> [--harness claude|echo] [--model m] [--effort e]
                             [--cwd dir] [--title t] [--prompt text] [--resume id] [--skip-permissions] [--label key=value]…
        Or, as a runner starts it: AGENT_ID=<uuid>@<url> AGENT_JOB=<json> [AGENT_DISPATCHER_URL] [AGENT_DRIVER_URL] [AGENT_RUNNER] [AGENT_TOKEN].
        """

    public init(arguments: [String], environment: [String: String]) throws(Problem) {
        spec.harness = "claude"
        if let id = environment["AGENT_ID"], !id.isEmpty {
            guard let at = id.firstIndex(of: "@") else { throw .bad("AGENT_ID is <uuid>@<dispatcher URL>") }
            agent.uuid = String(id[..<at])
            agent.dispatcherURL = String(id[id.index(after: at)...])
        }
        if let job = environment["AGENT_JOB"], !job.isEmpty { try take(job: job) }
        try take(arguments: arguments)
        guard !agent.uuid.isEmpty else { throw .missing("--agent or AGENT_ID") }
        guard !agent.dispatcherURL.isEmpty else { throw .missing("--dispatcher or AGENT_ID") }
        driverURL = Self.given(environment["AGENT_DRIVER_URL"]) ?? driverURL
        dispatcherURL = Self.given(environment["AGENT_DISPATCHER_URL"])
        runner = Self.given(environment["AGENT_RUNNER"])
        claudeProgram = Self.given(environment["AGENT_WRAPPER_CLAUDE"])
        sourcesDirectory = Self.given(environment["AGENT_SOURCES_DIR"])
        token = Self.given(environment["AGENT_TOKEN"])
        // A session with no folder named, where the runner keeps sessions
        // (AGENT_SESSIONS_DIR: /Volumes/Sessions): a folder of its own
        // there, <dir>/Claude/<id>, as Visor's SessionFolders gives one.
        // Its id and harness name it, so each must be one folder's name:
        // the id a UUID, the harness no path (a "/", "..", or nothing),
        // else the folder could be anywhere.
        if spec.workingDirectory.isEmpty, let sessions = Self.given(environment["AGENT_SESSIONS_DIR"]) {
            try Self.checkFolderParts(agent: agent.uuid, harness: spec.harness)
            spec.workingDirectory = "\(sessions)/\(Self.folderName(of: spec.harness))/\(agent.uuid)"
        }
    }

    /// The agent's id and harness, before they name its folder under
    /// AGENT_SESSIONS_DIR: refused unless the id is a UUID and the harness
    /// a single path component.
    static func checkFolderParts(agent uuid: String, harness: String) throws(Problem) {
        guard UUID(uuidString: uuid) != nil else {
            throw .bad("the agent's id \"\(uuid)\" isn't a UUID, so it can't name its folder under AGENT_SESSIONS_DIR")
        }
        guard !harness.isEmpty, harness != ".", harness != "..", !harness.contains("/"), !harness.contains("\0") else {
            throw .bad("the harness \"\(harness)\" isn't a single folder name (no \"/\", \".\" or \"..\", not empty), so it can't name its folder under AGENT_SESSIONS_DIR")
        }
    }

    /// A harness's part of a session's folder: Claude, Codex.
    static func folderName(of harness: String) -> String {
        harness.isEmpty ? "Claude" : harness.prefix(1).uppercased() + harness.dropFirst()
    }

    private static func given(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// The job's JSON (AGENT_JOB).
    private mutating func take(job: String) throws(Problem) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(job.utf8))) as? [String: Any] else {
            throw .bad("AGENT_JOB isn't a JSON object")
        }
        func string(_ key: String) -> String { object[key] as? String ?? "" }
        if !string("agent").isEmpty { agent.uuid = string("agent") }
        if !string("dispatcherURL").isEmpty { agent.dispatcherURL = string("dispatcherURL") }
        if !string("harness").isEmpty { spec.harness = string("harness") }
        spec.title = string("title")
        spec.prompt = string("prompt")
        spec.model = string("model")
        spec.effort = string("effort")
        spec.workingDirectory = string("workingDirectory")
        for (key, value) in [("sourceURL", string("sourceURL")), ("repository", string("repository")), ("ref", string("ref"))] where !value.isEmpty {
            spec.labels[key] = value
        }
        for label in object["labels"] as? [String] ?? [] { spec.labels[label] = "" }
        if !string("driverURL").isEmpty { driverURL = string("driverURL") }
        if !string("resumeSessionID").isEmpty { spec.resumeSessionID = string("resumeSessionID") }
        for source in object["sources"] as? [[String: Any]] ?? [] {
            sources.append(.with {
                $0.repository = source["repository"] as? String ?? ""
                $0.ref = source["ref"] as? String ?? ""
                $0.name = source["name"] as? String ?? ""
            })
        }
    }

    private mutating func take(arguments: [String]) throws(Problem) {
        var rest = arguments[...]
        func value(_ flag: String) throws(Problem) -> String {
            guard let next = rest.popFirst() else { throw .missing("a value for \(flag)") }
            return next
        }
        while let flag = rest.popFirst() {
            switch flag {
            case "--agent": agent.uuid = try value(flag)
            case "--dispatcher": agent.dispatcherURL = try value(flag)
            case "--harness": spec.harness = try value(flag)
            case "--model": spec.model = try value(flag)
            case "--effort": spec.effort = try value(flag)
            case "--cwd": spec.workingDirectory = try value(flag)
            case "--title": spec.title = try value(flag)
            case "--prompt": spec.prompt = try value(flag)
            case "--resume": spec.resumeSessionID = try value(flag)
            case "--skip-permissions": spec.skipPermissions = true
            case "--label":
                let pair = try value(flag)
                guard let equals = pair.firstIndex(of: "=") else { throw .bad("--label takes key=value") }
                spec.labels[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
            default: throw .unknown(flag)
            }
        }
    }
}
