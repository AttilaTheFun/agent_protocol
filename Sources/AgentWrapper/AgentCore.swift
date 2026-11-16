import AgentProtocol
import Foundation

/// One agent, under its harness: its conversation's rows, what it is doing,
/// the messages waiting for its turn to end, and everyone watching. A
/// message sent while it works waits; each turn's end takes the next.
public actor AgentCore {
    public let agent: AgentProtocol_V1_AgentID
    public let spec: AgentProtocol_V1_AgentSpec
    private let launch: HarnessLaunch
    private let log: @Sendable (String) -> Void

    private var process: Process?
    private var input: FileHandle?
    private var rows: [AgentProtocol_V1_TranscriptEntry] = []
    private var places: [String: Int] = [:]
    private var now = AgentProtocol_V1_EphemeralState()
    private var waiting: [(id: String, text: String)] = []
    private var session = ""
    private var endedBecause: String?
    private var watchers: [UUID: AsyncStream<WrapperOutput>.Continuation] = [:]
    private var endWaiters: [CheckedContinuation<String, Never>] = []
    /// The built-in echo harness: no process, each message answered here.
    private var echoing = false
    /// The echo harness's turn under way: its message's id.
    private var echoTurn: String?
    /// Interrupts sent to the harness, by request id, not yet answered.
    private var interrupts: Set<String> = []
    /// Whether the turn under way was interrupted: its end (Claude's
    /// "error_during_execution") is then the interrupt, not an error.
    private var interrupted = false

    /// Why a harness didn't start.
    public enum Problem: Error, Equatable, CustomStringConvertible {
        /// Its working directory couldn't be made: the folder, and why.
        case folderNotMade(String, String)
        /// Its program didn't start because its working directory isn't
        /// there (Foundation on Linux says only "no such file", naming the
        /// program): the folder, the program, and the error.
        case folderMissing(String, program: String, String)
        /// Its program didn't start, in a folder that is there.
        case notStarted(program: String, folder: String, String)

        public var description: String {
            switch self {
            case .folderNotMade(let folder, let why): "its working directory \(folder) can't be made: \(why)"
            case .folderMissing(let folder, let program, let why):
                "its working directory \(folder) isn't there, so \(program) didn't start: \(why)"
            case .notStarted(let program, let folder, let why):
                "\(program) didn't start\(folder.isEmpty ? "" : " in \(folder)"): \(why)"
            }
        }
    }

    public init(agent: AgentProtocol_V1_AgentID, spec: AgentProtocol_V1_AgentSpec, launch: HarnessLaunch,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.agent = agent
        self.spec = spec
        self.launch = launch
        self.log = log
        now.model = spec.model
    }

    /// The harness started in its working directory (made first, with any
    /// folders above it, when it isn't there: a fresh job's folder under
    /// AGENT_SESSIONS_DIR is), and the spec's prompt sent when it has one.
    public func start() throws {
        if launch.isEcho {
            session = "echo-" + UUID().uuidString.lowercased()
            echoing = true
            tell(.sessionID(session))
            if !spec.prompt.isEmpty { _ = send(id: UUID().uuidString.lowercased(), text: spec.prompt) }
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.environment = HarnessLaunch.environment(from: ProcessInfo.processInfo.environment)
        let folder = spec.workingDirectory
        if !folder.isEmpty {
            do {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            } catch {
                throw Problem.folderNotMade(folder, "\(error)")
            }
            process.currentDirectoryURL = URL(fileURLWithPath: folder, isDirectory: true)
        }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let lines = AsyncStream<String>.makeStream()
        let splitter = LineSplitter()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                lines.continuation.finish()
                return
            }
            for line in splitter.add(data) { lines.continuation.yield(line) }
        }
        let log = self.log
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { log("harness: " + String(decoding: data, as: UTF8.self)) }
        }
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            Task { await self?.harnessEnded(status: status) }
        }
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            var isFolder: ObjCBool = false
            if !folder.isEmpty, !(FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder) && isFolder.boolValue) {
                throw Problem.folderMissing(folder, program: launch.executable, "\(error)")
            }
            throw Problem.notStarted(program: launch.executable, folder: folder, "\(error)")
        }
        self.process = process
        input = stdin.fileHandleForWriting
        Task { [weak self] in
            for await line in lines.stream { await self?.take(line) }
        }
        if !spec.prompt.isEmpty { _ = send(id: UUID().uuidString.lowercased(), text: spec.prompt) }
    }

    /// Words for the agent: now when it is free, else at its turn's end.
    /// Whether they wait.
    @discardableResult
    public func send(id: String, text: String) -> Bool {
        guard endedBecause == nil else { return false }
        guard !rows.contains(where: { $0.id == id }), !waiting.contains(where: { $0.id == id }) else { return now.busy }
        if now.busy {
            waiting.append((id, text))
            now.queued = waiting.map(\.text)
            tell(.state(now))
            return true
        }
        begin(id: id, text: text)
        return false
    }

    /// The turn under way stopped, the harness kept for the next message
    /// (a message waiting begins once it has stopped). Claude is sent a
    /// control request on its stdin, as Claude Code's SDKs send one
    /// (ClaudeLine.interrupt); it answers it, then ends the turn with its
    /// result. The echo harness's turn just ends, unanswered. Whether there
    /// was a turn to stop.
    @discardableResult
    public func interrupt() -> Bool {
        guard endedBecause == nil, now.busy else {
            log("an interrupt, with no turn under way")
            return false
        }
        if echoing {
            echoTurn = nil
            interrupted = true
            endTurn(error: nil)
            return true
        }
        guard let input else { return false }
        let id = "interrupt-" + UUID().uuidString.lowercased()
        interrupts.insert(id)
        interrupted = true
        do {
            try input.write(contentsOf: Data((ClaudeLine.interrupt(requestID: id) + "\n").utf8))
        } catch {
            interrupts.remove(id)
            interrupted = false
            log("the interrupt couldn't be sent: \(error)")
            return false
        }
        return true
    }

    /// Ends the agent: its harness asked to end, and made to.
    public func stop(grace: Duration = .seconds(3)) async {
        if echoing {
            harnessEnded(status: 0)
            return
        }
        guard let process, process.isRunning else { return }
        try? input?.close()
        process.terminate()
        try? await Task.sleep(for: grace)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    /// What it has said and is doing, and from now on what changes: taken
    /// together, so nothing falls between them.
    public func attach() -> (rows: [AgentProtocol_V1_TranscriptEntry], state: AgentProtocol_V1_EphemeralState, sessionID: String,
                             ended: String?, changes: AsyncStream<WrapperOutput>) {
        let (stream, continuation) = AsyncStream<WrapperOutput>.makeStream()
        if endedBecause != nil {
            continuation.finish()
        } else {
            let key = UUID()
            watchers[key] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.detach(key) } }
        }
        return (rows, now, session, endedBecause, stream)
    }

    /// Why it ended, once it has.
    public func ended() async -> String {
        if let endedBecause { return endedBecause }
        return await withCheckedContinuation { endWaiters.append($0) }
    }

    public var state: AgentProtocol_V1_EphemeralState { now }
    public var sessionID: String { session }
    public var entries: [AgentProtocol_V1_TranscriptEntry] { rows }

    // MARK: - The harness's side

    private func begin(id: String, text: String) {
        var row = AgentProtocol_V1_TranscriptEntry()
        row.id = id
        row.role = .user
        row.text = text
        put(row)
        now.busy = true
        now.activity = ""
        tell(.state(now))
        if echoing {
            // A moment's work, then the words back and the turn's end.
            echoTurn = id
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                await self?.echo(id: id, text: text)
            }
            return
        }
        guard let input else { return }
        try? input.write(contentsOf: Data((ClaudeLine.userTurn(text) + "\n").utf8))
    }

    private func take(_ line: String) {
        for event in ClaudeLine.read(line) {
            switch event {
            case .started(let id, let model):
                if id != session {
                    session = id
                    tell(.sessionID(id))
                }
                if !model.isEmpty, model != now.model {
                    now.model = model
                    tell(.state(now))
                }
            case .text(let id, let text):
                var row = AgentProtocol_V1_TranscriptEntry()
                row.id = id
                row.role = .assistant
                row.text = text
                put(row)
                if now.thinking {
                    now.thinking = false
                    tell(.state(now))
                }
            case .thinking:
                if !now.thinking {
                    now.thinking = true
                    tell(.state(now))
                }
            case .toolStarted(let id, let name, let label):
                var row = AgentProtocol_V1_TranscriptEntry()
                row.id = id
                row.role = .assistant
                row.activities = [label]
                put(row)
                var call = AgentProtocol_V1_ToolCall()
                call.id = id
                call.name = name
                call.label = label
                now.tools.append(call)
                now.activity = label
                tell(.state(now))
            case .toolFinished(let id):
                now.tools.removeAll { $0.id == id }
                tell(.state(now))
            case .turnEnded(let error):
                endTurn(error: error)
            case .controlAnswered(let id, let error):
                guard interrupts.remove(id) != nil else { break }
                if let error {
                    interrupted = false
                    log("the harness didn't take the interrupt: \(error)")
                }
            }
        }
    }

    /// The turn's end: free, or on to the next message waiting.
    private func endTurn(error: String?) {
        if interrupted {
            log("the turn was interrupted")
        } else if let error {
            log("turn ended in error: \(error)")
        }
        interrupted = false
        now.busy = false
        now.thinking = false
        now.tools = []
        now.activity = ""
        if waiting.isEmpty {
            tell(.state(now))
        } else {
            let next = waiting.removeFirst()
            now.queued = waiting.map(\.text)
            begin(id: next.id, text: next.text)
        }
    }

    /// The echo harness's answer to the message `id`.
    private func echo(id: String, text: String) {
        guard endedBecause == nil, echoTurn == id else { return }
        echoTurn = nil
        let reply = #"{"type":"assistant","message":{"id":"echo-\#(id)","content":[{"type":"text","text":\#(Self.json(text))}]}}"#
        take(reply)
        take(#"{"type":"result","subtype":"success","is_error":false}"#)
    }

    /// `text` as a JSON string.
    private static func json(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["echo: " + text])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    private func harnessEnded(status: Int32) {
        guard endedBecause == nil else { return }
        let why = status == 0 ? "the harness ended" : "the harness ended with status \(status)"
        endedBecause = why
        now.busy = false
        tell(.state(now))
        tell(.ended(why))
        for continuation in watchers.values { continuation.finish() }
        watchers = [:]
        for waiter in endWaiters { waiter.resume(returning: why) }
        endWaiters = []
    }

    private func put(_ row: AgentProtocol_V1_TranscriptEntry) {
        if let place = places[row.id] {
            rows[place] = row
        } else {
            places[row.id] = rows.count
            rows.append(row)
        }
        tell(.entry(row))
    }

    private func tell(_ output: WrapperOutput) {
        for continuation in watchers.values { continuation.yield(output) }
    }

    private func detach(_ key: UUID) {
        watchers[key] = nil
    }
}
