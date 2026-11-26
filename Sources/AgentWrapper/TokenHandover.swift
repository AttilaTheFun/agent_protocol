import CAgentPOSIX
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// The C library's own, by a name TokenHandover's methods don't shadow.
private func posixRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int { read(fd, buffer, count) }

/// How the agent's token (Job.token) reaches the wrapper from its runner,
/// never in any environment (agent_protocol#17), and what keeps it there:
///
/// - `AGENT_TOKEN_FD=<n>`: a descriptor the wrapper inherits (a pipe's
///   reading end, say; standard input, 0, is one), read to its end and
///   closed. A standard descriptor (0 to 2) is /dev/null after.
/// - `AGENT_TOKEN_FILE=<path>`: a file read and then deleted. It must be a
///   regular file of the wrapper's own user, readable by no one else
///   (0600 or tighter), and should be on a tmpfs (/run, /dev/shm): one on
///   a disk is taken, with a log line.
/// - `AGENT_TOKEN`, the environment, as before: taken, with a log line, for
///   one release more (0.6), then dropped.
///
/// One of the first two at most. Either way the token is the bytes given,
/// less any white space around them (a file's last newline); empty, there
/// is none. No program the wrapper starts gets it in any form.
///
/// On Linux, what keeps it is `protectProcess`, the first thing agent-wrapper
/// does: the process undumpable, so its /proc/<pid> is root's, and the
/// harness, which runs as the wrapper's user, is refused its environ, fd,
/// mem and maps (cmdline and status stay readable, as `ps` needs). Root
/// with CAP_SYS_PTRACE still reads all of it, and with CAP_SYS_ADMIN or
/// CAP_PERFMON its environ and maps: a runner keeps those from its agents
/// (the OCI default set has none of them). On macOS
/// there's no such thing; the handover is what keeps it there: `ps -E`
/// (KERN_PROCARGS2) shows a process's environment as it began, which no
/// longer holds the token, and reading another process's memory takes
/// the debugger's entitlement or root.
public enum TokenHandover {
    public static let descriptorVariable = "AGENT_TOKEN_FD"
    public static let fileVariable = "AGENT_TOKEN_FILE"
    public static let environmentVariable = "AGENT_TOKEN"
    /// Every variable of the handover: none goes to the harness.
    public static let variables: Set<String> = [descriptorVariable, fileVariable, environmentVariable]
    /// More than any token is long: what's read past it is refused.
    static let largest = 64 * 1024

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case unreadable(String, String)
        case notPrivate(String)
        case tooLong(String)
        case notRemoved(String, String)

        public var description: String {
            switch self {
            case .unreadable(let what, let why): "the agent's token can't be read from \(what): \(why)"
            case .notPrivate(let path):
                "\(fileVariable) \(path) isn't a regular file of this user's that no one else can read (0600), so it isn't taken; it's deleted"
            case .tooLong(let what): "the agent's token in \(what) is longer than \(largest) bytes"
            case .notRemoved(let path, let why): "\(fileVariable) \(path) was read but can't be deleted: \(why)"
            }
        }
    }

    /// This process undumpable (Linux), before anything is read: nil, or
    /// why it isn't (on macOS, that there's no such thing).
    @discardableResult
    public static func protectProcess() -> String? {
        if agent_set_undumpable() == 0 { return nil }
        return errno == ENOTSUP ? "a process can't be made undumpable here" : String(cString: strerror(errno))
    }

    /// The token as `options` say it was handed over ("" for none), each
    /// form's handover undone: the descriptor closed, the file deleted.
    /// `log` says what's deprecated or looks wrong; nothing logs the token.
    public static func take(_ options: WrapperOptions, log: (String) -> Void) throws(Problem) -> String {
        if let fd = options.tokenDescriptor {
            if options.token != nil { log("\(environmentVariable) is ignored: the token came on \(descriptorVariable)") }
            return try fromDescriptor(fd)
        }
        if let path = options.tokenFile {
            if options.token != nil { log("\(environmentVariable) is ignored: the token came in \(fileVariable)") }
            return try fromFile(path, log: log)
        }
        if let token = options.token {
            log("the token came in \(environmentVariable), which is deprecated (agent_protocol#17) and goes in 0.7: hand it over on \(descriptorVariable) or in \(fileVariable)")
            return token
        }
        return ""
    }

    /// `fd` read to its end and closed; a standard one is /dev/null after,
    /// so the next descriptor opened isn't taken for it.
    static func fromDescriptor(_ fd: Int32) throws(Problem) -> String {
        let what = "\(descriptorVariable)=\(fd)"
        defer {
            _ = close(fd)
            if fd <= 2 {
                let null = open("/dev/null", O_RDWR)
                if null >= 0, null != fd {
                    _ = dup2(null, fd)
                    _ = close(null)
                }
            }
        }
        return try readAll(fd, what: what)
    }

    /// The file at `path` read and deleted, once it's checked as private.
    static func fromFile(_ path: String, log: (String) -> Void) throws(Problem) -> String {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw .unreadable("\(fileVariable) \(path)", String(cString: strerror(errno))) }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0
        else {
            _ = unlink(path)
            throw .notPrivate(path)
        }
        if agent_on_tmpfs(fd) == 0 { log("\(fileVariable) \(path) isn't on a tmpfs, so the token was on a disk") }
        let token = try readAll(fd, what: "\(fileVariable) \(path)")
        guard unlink(path) == 0 else { throw .notRemoved(path, String(cString: strerror(errno))) }
        return token
    }

    /// What `fd` has until its end, as text less the white space around it.
    static func readAll(_ fd: Int32, what: String) throws(Problem) -> String {
        var bytes = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { posixRead(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw .unreadable(what, String(cString: strerror(errno))) }
            if count == 0 { break }
            bytes += buffer[..<count]
            guard bytes.count <= largest else { throw .tooLong(what) }
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
