import Foundation
import Synchronization
#if canImport(Glibc)
import Glibc
private let streamSocket = Int32(SOCK_STREAM.rawValue)
#elseif canImport(Musl)
import Musl
private let streamSocket = SOCK_STREAM
#elseif canImport(Darwin)
import Darwin
private let streamSocket = SOCK_STREAM
#endif

// The C library's own, by names the types' methods don't shadow.
private func posixClose(_ fd: Int32) -> Int32 { close(fd) }
private func posixWrite(_ fd: Int32, _ bytes: UnsafeRawPointer?, _ count: Int) -> Int { write(fd, bytes, count) }
private func posixConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 { connect(fd, address, length) }

/// The environment variable that tells `agent-wrapper mcp` where its
/// wrapper listens.
public let mcpSocketVariable = "AGENT_MCP_SOCKET"

/// Where the wrapper takes its agent's MCP connections: a Unix socket in a
/// private folder of its own (0700, the socket 0600), each line read handed
/// to the relay in order, its answers written back. Nothing secret crosses
/// it: the agent's token stays in the wrapper.
public final class MCPSocketServer: Sendable {
    public let path: String
    let folder: String
    private let listener: Int32

    /// Listening, in a new folder under `base` (the temporary folder;
    /// /tmp when that is too long a path for a socket).
    public init(relay: MCPRelay, base: String = NSTemporaryDirectory()) throws {
        let parent = base.hasSuffix("/") ? String(base.dropLast()) : base
        var template = Array(((parent.utf8.count > 60 ? "/tmp" : parent) + "/agent-mcp-XXXXXX").utf8CString)
        guard let made = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else { throw POSIXFailure("mkdtemp") }
        folder = String(cString: made)
        path = folder + "/mcp.sock"
        let fd = socket(AF_UNIX, streamSocket, 0)
        guard fd >= 0 else { throw POSIXFailure("socket") }
        Self.closeOnExec(fd)
        let bound = Self.withAddress(path) { bind(fd, $0, $1) } ?? -1
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            let failure = POSIXFailure("listening at \(path)")
            _ = posixClose(fd)
            throw failure
        }
        listener = fd
        Thread.detachNewThread { [listener] in
            while true {
                let connection = accept(listener, nil, nil)
                if connection < 0 {
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    return
                }
                Self.closeOnExec(connection)
                Self.serve(MCPSocketConnection(fd: connection), relay: relay)
            }
        }
    }

    /// No more connections, and the folder gone.
    public func close() {
        shutdown(listener, Int32(SHUT_RDWR))
        _ = unlink(path)
        _ = rmdir(folder)
    }

    /// A connection's lines, to the relay in order, until it closes. A line
    /// over the relay's limit (MCPRelay.lineLimit) is never held whole: it
    /// is discarded as it comes and the relay told (MCPRelay.tooLong).
    private static func serve(_ connection: MCPSocketConnection, relay: MCPRelay) {
        let (pieces, continuation) = AsyncStream<LineSplitter.Piece>.makeStream()
        Task {
            let name = await relay.connected(connection)
            for await piece in pieces {
                switch piece {
                case .line(let line): if !line.isEmpty { await relay.handle(line, from: name) }
                case .tooLong(let bytes, let tail): await relay.tooLong(bytes: bytes, tail: tail, from: name)
                }
            }
            await relay.disconnected(name)
            connection.close()
        }
        Thread.detachNewThread {
            let splitter = LineSplitter(limit: relay.lineLimit)
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(connection.fd, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                for piece in splitter.pieces(Data(buffer[0..<count])) { continuation.yield(piece) }
            }
            continuation.finish()
        }
    }

    static func closeOnExec(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    /// `body` given `path` as a Unix socket's address; nil when it is too
    /// long for one.
    static func withAddress<Result>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Result) -> Result? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// A connection to the socket at `path`, or -1.
    static func connect(to path: String) -> Int32 {
        let fd = socket(AF_UNIX, streamSocket, 0)
        guard fd >= 0 else { return -1 }
        closeOnExec(fd)
        guard withAddress(path, { posixConnect(fd, $0, $1) }) == 0 else {
            _ = posixClose(fd)
            return -1
        }
        return fd
    }

    /// All of `bytes` written to `fd`: false when it can't take them.
    @discardableResult
    static func write(_ bytes: [UInt8], to fd: Int32) -> Bool {
        var written = 0
        while written < bytes.count {
            let count = bytes[written...].withUnsafeBytes { posixWrite(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            written += count
        }
        return true
    }
}

/// One MCP connection, as the relay writes to it: a line at a time.
final class MCPSocketConnection: MCPClient {
    let fd: Int32
    private let writing = Mutex(())

    init(fd: Int32) {
        self.fd = fd
    }

    func send(_ line: String) {
        writing.withLock { _ in _ = MCPSocketServer.write(Array((line + "\n").utf8), to: fd) }
    }

    func close() {
        writing.withLock { _ in _ = posixClose(fd) }
    }
}

/// A system call that failed, with its errno.
struct POSIXFailure: Error, CustomStringConvertible {
    let description: String

    init(_ what: String) {
        description = "\(what): \(String(cString: strerror(errno)))"
    }
}

/// `agent-wrapper mcp`: the stdio MCP server Claude starts (its
/// `--mcp-config`), which is only a pipe to its wrapper: Claude's messages
/// to the wrapper's socket (AGENT_MCP_SOCKET), the wrapper's answers back.
public enum MCPStdio {
    /// Run as Claude's MCP server: until Claude closes its input, or the
    /// wrapper its socket.
    public static func run(environment: [String: String]) -> Int32 {
        guard let path = environment[mcpSocketVariable], !path.isEmpty else {
            FileHandle.standardError.write(Data("agent-wrapper mcp: \(mcpSocketVariable) isn't set: Claude starts this under agent-wrapper\n".utf8))
            return 2
        }
        signal(SIGPIPE, SIG_IGN)
        return pump(socket: path, input: 0, output: 1)
    }

    /// `input` to the socket at `path`, and what it answers to `output`.
    public static func pump(socket path: String, input: Int32, output: Int32) -> Int32 {
        let fd = MCPSocketServer.connect(to: path)
        guard fd >= 0 else {
            FileHandle.standardError.write(Data("agent-wrapper mcp: \(POSIXFailure("no wrapper at \(path)"))\n".utf8))
            return 1
        }
        Thread.detachNewThread {
            copy(from: input, to: fd)
            shutdown(fd, Int32(SHUT_WR))
        }
        copy(from: fd, to: output)
        _ = posixClose(fd)
        return 0
    }

    private static func copy(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0, MCPSocketServer.write(Array(buffer[0..<count]), to: destination) else { return }
        }
    }
}
