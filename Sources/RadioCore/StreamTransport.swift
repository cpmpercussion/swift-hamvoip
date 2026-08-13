// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Errors surfaced by a `StreamTransport`.
///
/// Deliberately a small, closed set, and deliberately *separate* from
/// `DatagramTransportError` even though the cases line up: the two seams are
/// not interchangeable, and a shared error type would let a stream error be
/// caught by code that only knows how to recover a datagram one.
public enum StreamTransportError: Error, Equatable, CustomStringConvertible {
    /// The transport was closed (locally or by the peer) before or during the
    /// operation.
    case closed

    /// The endpoint could not be formed — e.g. port 0, or an unusable host.
    case invalidEndpoint(String)

    /// The connection failed or was lost. Payload is a human-readable
    /// description of the underlying error, for logging only.
    case connectionFailed(String)

    /// Bytes could not be written.
    case sendFailed(String)

    public var description: String {
        switch self {
        case .closed:
            return "stream transport is closed"
        case .invalidEndpoint(let detail):
            return "invalid endpoint: \(detail)"
        case .connectionFailed(let detail):
            return "connection failed: \(detail)"
        case .sendFailed(let detail):
            return "send failed: \(detail)"
        }
    }
}

/// The seam that keeps TCP sockets out of protocol code (AU-5).
///
/// The stream counterpart of `DatagramTransport`, and it exists for the same
/// reason: EchoLink needs TCP for the proxy (port 8100) and for the direct
/// directory connection (port 5200), and no unit test may open a socket.
/// Tests substitute `MockStreamTransport` from the `TestSupport` target.
///
/// **`incoming` yields whatever the network hands over, and its chunk
/// boundaries carry no meaning.** This is the one thing that distinguishes
/// this protocol from `DatagramTransport`, and getting it wrong is the classic
/// way to write a decoder that passes every test and fails on a real
/// connection. A yielded `Data` may be:
///
/// - a fraction of one protocol frame,
/// - exactly one frame, which is what a mock that has not thought about it
///   will produce and what makes the mistake invisible,
/// - several frames,
/// - or the tail of one frame followed by the head of the next.
///
/// Reassembly is therefore the caller's job, not this layer's: a conformer
/// knows nothing about EchoLink's 9-byte proxy header and must not pretend to.
/// `EchoLinkProxyFrameDecoder` (EL-4) is the buffer that turns this byte
/// stream back into frames.
///
/// The other two rules match `DatagramTransport` exactly:
///
/// - Iterate `incoming` **once**; it is a single-consumer stream, and a second
///   iteration will steal elements from the first.
/// - `close()` is idempotent and finishes `incoming`, which is how a consumer
///   loop learns the link is gone.
///
/// Conformers must be `Sendable`: a transport is shared between the actor that
/// drives the protocol and whatever queue the network layer calls back on.
public protocol StreamTransport: Sendable {
    /// Bytes received from the peer, in arrival order.
    ///
    /// Chunk boundaries are an artefact of the network and carry no protocol
    /// meaning — see the type's documentation. Finishes when the transport
    /// closes, the peer half-closes, or the connection fails.
    var incoming: AsyncStream<Data> { get }

    /// Send `bytes` to the peer.
    ///
    /// - Throws: `StreamTransportError` if the transport is closed or the
    ///   write fails. Unlike the datagram case a successful return does mean
    ///   the bytes are in the kernel's send buffer in order, but it still does
    ///   not mean the peer has seen them.
    func send(_ bytes: Data) async throws

    /// Close the transport and finish `incoming`. Idempotent.
    func close() async
}
