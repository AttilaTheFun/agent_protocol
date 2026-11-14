// DNS over TCP's framing (RFC 1035 §4.2.2): each message after a two-byte
// length, however the stream's chunks fall.

import NIOCore

/// The messages in a TCP stream, taken whole as their bytes arrive.
package struct DNSStreamFrames {
    private var buffer = ByteBuffer()

    package init() {}

    package mutating func append(_ chunk: ByteBuffer) {
        var chunk = chunk
        buffer.writeBuffer(&chunk)
    }

    /// The next whole message, or nil until more has arrived.
    package mutating func next() -> [UInt8]? {
        guard let length = buffer.getInteger(at: buffer.readerIndex, as: UInt16.self),
              buffer.readableBytes >= 2 + Int(length) else { return nil }
        buffer.moveReaderIndex(forwardBy: 2)
        let bytes = buffer.readBytes(length: Int(length)) ?? []
        buffer.discardReadBytes()
        return bytes
    }
}
