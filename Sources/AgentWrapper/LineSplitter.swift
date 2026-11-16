import Foundation
import Synchronization

/// Bytes as they come, given back as whole lines: what is left of a line
/// waits for the rest. With a limit, a line longer than it is never kept
/// whole: what came of it is dropped as it comes, the rest of it up to its
/// newline is discarded, and it is given back as `.tooLong`, with its size
/// and its last few bytes (where a JSON-RPC message may name its id).
final class LineSplitter: Sendable {
    enum Piece: Equatable, Sendable {
        case line(String)
        /// A line over the limit, dropped: how long it was, and its end.
        case tooLong(bytes: Int, tail: String)
    }

    /// How much of an over-long line's end is kept.
    static let tailBytes = 256

    /// The longest line given back whole, in bytes (not counting its
    /// newline); nil for no limit.
    let limit: Int?

    private struct State {
        var buffer = Data()
        /// While a line over the limit is being discarded: how much of it
        /// has come so far, and its last bytes.
        var discarding: (bytes: Int, tail: Data)?
    }

    private let state = Mutex(State())

    init(limit: Int? = nil) {
        self.limit = limit
    }

    /// The whole lines alone (for a splitter with no limit, every line).
    func add(_ data: Data) -> [String] {
        pieces(data).compactMap { if case .line(let line) = $0 { line } else { nil } }
    }

    /// The lines, and the over-long lines dropped, in order.
    func pieces(_ data: Data) -> [Piece] {
        let limit = self.limit
        return state.withLock { state in
            state.buffer.append(data)
            var pieces: [Piece] = []
            while true {
                let end = state.buffer.firstIndex(of: 0x0A)
                if var discarding = state.discarding {
                    let part = state.buffer[state.buffer.startIndex..<(end ?? state.buffer.endIndex)]
                    discarding.bytes += part.count
                    discarding.tail = Self.tail(discarding.tail + part)
                    guard let end else {
                        state.buffer.removeAll()
                        state.discarding = discarding
                        break
                    }
                    state.buffer.removeSubrange(state.buffer.startIndex...end)
                    state.discarding = nil
                    pieces.append(.tooLong(bytes: discarding.bytes, tail: String(decoding: discarding.tail, as: UTF8.self)))
                    continue
                }
                guard let end else {
                    // No newline yet: past the limit, it is dropped as it comes.
                    if let limit, state.buffer.count > limit {
                        state.discarding = (state.buffer.count, Self.tail(state.buffer))
                        state.buffer.removeAll()
                    }
                    break
                }
                let line = state.buffer[state.buffer.startIndex..<end]
                if let limit, line.count > limit {
                    pieces.append(.tooLong(bytes: line.count, tail: String(decoding: Self.tail(line), as: UTF8.self)))
                } else {
                    pieces.append(.line(String(decoding: line, as: UTF8.self)))
                }
                state.buffer.removeSubrange(state.buffer.startIndex...end)
            }
            return pieces
        }
    }

    private static func tail(_ data: Data) -> Data {
        Data(data.suffix(tailBytes))
    }
}
