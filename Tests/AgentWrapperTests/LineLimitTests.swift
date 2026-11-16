// A line from Claude's MCP client is capped (MCPRelay.defaultLineLimit,
// 3 MiB, under gRPC's 4 MiB a message): a longer one is never held whole,
// the rest of it is discarded, and Claude is answered with a JSON-RPC
// error (-32600) for its request's id; the lines after it are taken as
// ever.

@testable import AgentWrapper
import Foundation
import XCTest

final class LineLimitTests: XCTestCase {
    func testLinesUpToTheLimitAreWholeAndALongerOneIsDroppedAsItComes() {
        let splitter = LineSplitter(limit: 10)
        XCTAssertEqual(splitter.pieces(Data("short\n0123456789\n".utf8)), [.line("short"), .line("0123456789")], "the limit itself is whole")
        // Over the limit, in pieces: dropped as it comes, given back once it ends.
        XCTAssertEqual(splitter.pieces(Data("0123456789AB".utf8)), [])
        XCTAssertEqual(splitter.pieces(Data(String(repeating: "x", count: 500).utf8)), [])
        XCTAssertEqual(splitter.pieces(Data("CD\nnext\n".utf8)),
                       [.tooLong(bytes: 514, tail: String(("0123456789AB" + String(repeating: "x", count: 500) + "CD").suffix(LineSplitter.tailBytes))),
                        .line("next")])
        // Over it in one piece, with its newline.
        XCTAssertEqual(splitter.pieces(Data("0123456789ABC\nafter".utf8)), [.tooLong(bytes: 13, tail: "0123456789ABC")])
        XCTAssertEqual(splitter.pieces(Data("\n".utf8)), [.line("after")])
        // With no limit, as before.
        XCTAssertEqual(LineSplitter().add(Data((String(repeating: "y", count: 100_000) + "\n").utf8)).map(\.count), [100_000])
    }

    func testTheIdAMessageEndsWithIsFound() {
        XCTAssertEqual(MCPRelay.trailingID(#"…"arguments":{"text":"xxx"}},"jsonrpc":"2.0","id":7}"#), "7")
        XCTAssertEqual(MCPRelay.trailingID(#"…"jsonrpc":"2.0","id" : "a\"b" } "#), #""a\"b""#)
        XCTAssertNil(MCPRelay.trailingID(#"…"params":{"id":3}}"#), "a nested object's id isn't the request's")
        XCTAssertNil(MCPRelay.trailingID(#"…"id":7,"method":"tools/call","params":{}}"#), "an id elsewhere can't be told from the end")
    }

    /// Over the wrapper's socket, at the real limit: a 3.5 MiB tools/call
    /// answered with an error for its id, and the ping after it answered.
    func testAnOverLongMessageOnTheSocketGetsAnErrorAndTheNextIsTaken() async throws {
        XCTAssertEqual(MCPRelay.defaultLineLimit, 3 * 1024 * 1024)
        let relay = MCPRelay(hasDriver: false, asksPermission: true)
        let server = try MCPSocketServer(relay: relay)
        defer { server.close() }
        let fd = MCPSocketServer.connect(to: server.path)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { _ = close(fd) }
        let lines = Lines()
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                guard count > 0 else { return }
                lines.add(Data(buffer[0..<count]))
            }
        }
        let big = #"{"method":"tools/call","params":{"name":"send_message","arguments":{"text":""#
            + String(repeating: "x", count: 3 * 1024 * 1024 + 512 * 1024) + #""}},"jsonrpc":"2.0","id":9}"#
        XCTAssertTrue(MCPSocketServer.write(Array((big + "\n").utf8), to: fd))
        XCTAssertTrue(MCPSocketServer.write(Array((#"{"jsonrpc":"2.0","id":10,"method":"ping"}"# + "\n").utf8), to: fd))
        let refused = try await lines.error(9)
        XCTAssertEqual(refused["code"] as? Int, -32600)
        XCTAssertTrue((refused["message"] as? String ?? "").contains("over the 3145728 bytes"), "\(refused)")
        _ = try await lines.result(10)
    }
}
