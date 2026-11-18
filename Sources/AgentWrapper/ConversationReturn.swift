// A session handed back from this runner (DriverMessage.hand_back): once
// its harness has ended, its conversation goes up to its driver
// (AgentDriver.ReturnConversation), the same files Conversation brought
// down when it moved here (ResumePreparation), so the turns it took here
// aren't lost when it moves back. For Claude, under its folder
// (ResumePreparation.claudeFolder()): the conversation,
// `projects/<key>/<session>.jsonl`; every file under the folder beside it,
// `projects/<key>/<session>/…` (its subagents', its tool results); and every
// file under the project's memory, `projects/<key>/memory/…`.
//
// Nothing but regular files under Claude's folder goes: no symbolic link
// below it is followed (one is skipped, as a socket or a device is), so a
// link the agent made can't send up a file from anywhere else.

import AgentProtocol
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

public enum ConversationReturn {
    /// The most of a file one ConversationFile carries: 1 MiB, as the
    /// driver's pieces coming down are, well under gRPC's 4 MiB limit on a
    /// message.
    public static let pieceSize = 1 << 20

    /// How long the driver has to take the whole conversation before the
    /// wrapper gives up on it and ends anyway: 5 minutes, for a long
    /// conversation over a slow link.
    public static let deadline: Duration = .seconds(5 * 60)

    /// A file to send: its place under the harness's folder, and where it is.
    public struct File: Equatable, Sendable {
        public let place: String
        public let url: URL
    }

    /// The folder Claude Code keeps a working directory's conversations in,
    /// under `projects/`: the directory's real path (every link in it
    /// followed, as Claude's own working directory is: /private/tmp on a
    /// Mac, not /tmp), every character but an ASCII letter or digit as "-".
    /// `/Users/logan/Developer/visor_app` is `-Users-logan-Developer-visor-app`.
    /// Claude shortens a very long one (with a hash of the path), which
    /// this doesn't: `files` then finds the conversation by its name.
    public static func projectKey(for workingDirectory: String) -> String {
        let path = realPath((workingDirectory as NSString).expandingTildeInPath)
        return String(path.unicodeScalars.map { scalar -> Character in
            let ascii = scalar.isASCII && (("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar))
            return ascii ? Character(scalar) : "-"
        })
    }

    /// The conversation `sessionID` of a harness that worked in
    /// `workingDirectory`, under Claude's `folder`: the conversation, the
    /// files under the folder beside it, and the project's memory, in that
    /// order (each folder's files by their places). Its project's folder is
    /// the working directory's (projectKey), or else the one under
    /// `projects/` holding `<sessionID>.jsonl` (Claude's key for a long
    /// path, or one keyed some other way). Empty for an empty session id,
    /// or one that isn't a single name.
    public static func files(sessionID: String, workingDirectory: String, in folder: URL) -> [File] {
        guard !sessionID.isEmpty, !sessionID.contains("/"), sessionID != ".", sessionID != ".." else { return [] }
        let root = folder.path
        guard kind(atPath: root + "/projects") == .folder else { return [] }
        let transcript = sessionID + ".jsonl"
        var key = projectKey(for: workingDirectory)
        if kind(atPath: "\(root)/projects/\(key)/\(transcript)") != .file,
           let found = (try? FileManager.default.contentsOfDirectory(atPath: root + "/projects"))?.sorted().first(where: { name in
               kind(atPath: "\(root)/projects/\(name)") == .folder
                   && kind(atPath: "\(root)/projects/\(name)/\(transcript)") == .file
           }) {
            key = found
        }
        let project = "projects/" + key
        guard !key.isEmpty, kind(atPath: root + "/" + project) == .folder else { return [] }
        var found: [File] = []
        if kind(atPath: "\(root)/\(project)/\(transcript)") == .file {
            found.append(File(place: "\(project)/\(transcript)", url: folder.appendingPathComponent("\(project)/\(transcript)")))
        }
        for beside in [sessionID, "memory"] {
            found += regularFiles(under: "\(project)/\(beside)", in: folder)
        }
        return found
    }

    /// Every regular file under `place` (a folder under `folder`), by its
    /// place, sorted: folders walked without following a link, and anything
    /// else (a link, a socket) skipped. Empty when `place` is no folder.
    static func regularFiles(under place: String, in folder: URL) -> [File] {
        let root = folder.path
        guard kind(atPath: root + "/" + place) == .folder else { return [] }
        var found: [File] = []
        var folders = [place]
        while let next = folders.popLast() {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root + "/" + next)) ?? []
            for name in names {
                let inside = next + "/" + name
                switch kind(atPath: root + "/" + inside) {
                case .file: found.append(File(place: inside, url: folder.appendingPathComponent(inside, isDirectory: false)))
                case .folder: folders.append(inside)
                case .other: continue
                }
            }
        }
        return found.sorted { $0.place < $1.place }
    }

    /// `file` in pieces of at most `size` bytes, each handed to `body` as it
    /// is read (a file is never held whole), `last` on its last piece. An
    /// empty file is one empty piece. It is opened without following a
    /// link, so one put in its place since it was found isn't read.
    public static func pieces(of file: File, size: Int = pieceSize,
                              _ body: (AgentProtocol_V1_ConversationFile) async throws -> Void) async throws {
        let descriptor = open(file.url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Problem.unreadable(file.place, String(cString: strerror(errno))) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { throw Problem.unreadable(file.place, "not a regular file") }
        var piece = try handle.read(upToCount: size) ?? Data()
        while true {
            let next = piece.isEmpty ? Data() : (try handle.read(upToCount: size) ?? Data())
            let last = next.isEmpty
            let sent = piece
            try await body(.with {
                $0.place = file.place
                $0.data = sent
                $0.last = last
            })
            if last { return }
            piece = next
        }
    }

    /// The conversation of `agent`, whose harness worked in
    /// `workingDirectory` as `sessionID`, from Claude's `folder` up to the
    /// driver at `driverURL` (ReturnConversation), showing the agent's
    /// `token`: the header, then each file in pieces. An empty session id
    /// (the harness never said one), or a harness other than Claude, is
    /// the header alone. Answers the driver's acknowledgement.
    public static func send(driverURL: String, agent: AgentProtocol_V1_AgentID, harness: String, workingDirectory: String,
                            sessionID: String, token: AgentToken = AgentToken(), from folder: URL,
                            deadline: Duration = Self.deadline) async throws -> AgentProtocol_V1_ReturnedConversationAck {
        guard let components = URLComponents(string: driverURL), components.scheme == "http",
              let host = components.host, !host.isEmpty else { throw Problem.badDriver(driverURL) }
        let harness = harness.isEmpty ? "claude" : harness
        let header = AgentProtocol_V1_ReturnedConversationHeader.with {
            $0.agent = agent
            $0.harness = harness
            $0.workingDirectory = workingDirectory
            $0.sessionID = sessionID
        }
        let files = harness == "claude" ? Self.files(sessionID: sessionID, workingDirectory: workingDirectory, in: folder) : []
        let transport = try HTTP2ClientTransport.Posix(target: .dns(host: host, port: components.port ?? 80), transportSecurity: .plaintext)
        var options = CallOptions.defaults
        options.timeout = deadline
        return try await withGRPCClient(transport: transport) { client in
            let driver = AgentProtocol_V1_AgentDriver.Client(wrapping: client)
            return try await driver.returnConversation(metadata: token.metadata, options: options, requestProducer: { writer in
                try await writer.write(.with { $0.header = header })
                for file in files {
                    try await pieces(of: file) { piece in try await writer.write(.with { $0.file = piece }) }
                }
            }, onResponse: { response in try response.message })
        }
    }

    public enum Problem: Error, CustomStringConvertible {
        case badDriver(String)
        case unreadable(String, String)

        public var description: String {
            switch self {
            case .badDriver(let url): "the driver isn't http://host:port: \(url)"
            case .unreadable(let place, let why): "\(place) can't be read: \(why)"
            }
        }
    }

    enum Kind { case file, folder, other }

    /// What is at `path`, its last component's link not followed (lstat):
    /// a link is `other`, whatever it points at.
    static func kind(atPath path: String) -> Kind {
        var status = stat()
        guard lstat(path, &status) == 0 else { return .other }
        switch status.st_mode & S_IFMT {
        case S_IFREG: return .file
        case S_IFDIR: return .folder
        default: return .other
        }
    }

    /// `path` with every link in it followed, as realpath(3) has it; as it
    /// is when it isn't there.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
