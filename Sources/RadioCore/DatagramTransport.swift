// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Errors surfaced by a `DatagramTransport`.
///
/// Deliberately a small, closed set: protocol code above the transport should
/// react to *classes* of failure (the link died, the write failed), never to
/// the details of whichever socket API is underneath.
public enum DatagramTransportError: Error, Equatable, CustomStringConvertible {
    /// The transport was closed (locally or by the peer) before or during the
    /// operation.
    case closed

    /// The endpoint could not be formed — e.g. port 0, or an unusable host.
    case invalidEndpoint(String)

    /// The connection failed or was lost. Payload is a human-readable
    /// description of the underlying error, for logging only.
    case connectionFailed(String)

    /// A datagram could not be written.
    case sendFailed(String)

    public var description: String {
        switch self {
        case .closed:
            return "transport is closed"
        case .invalidEndpoint(let detail):
            return "invalid endpoint: \(detail)"
        case .connectionFailed(let detail):
            return "connection failed: \(detail)"
        case .sendFailed(let detail):
            return "send failed: \(detail)"
        }
    }
}

/// The seam that keeps sockets out of protocol code (AU-5).
///
/// Everything above this protocol — IAX2 framing, the M17 reflector FSM, the
/// call state machines — deals only in datagrams in and datagrams out. That is
/// what makes those layers unit-testable: tests substitute `MockTransport`
/// (in the `TestSupport` target) and drive them from recorded byte fixtures,
/// so **no unit test ever opens a socket**.
///
/// There are exactly two production-shaped rules for conformers:
///
/// - `incoming` yields received datagrams in arrival order, one element per
///   datagram, with no reassembly or coalescing. Iterate it **once**; it is a
///   single-consumer stream, and a second iteration will steal elements from
///   the first.
/// - `close()` is idempotent and finishes `incoming`, which is how a consumer
///   loop learns the link is gone.
///
/// Conformers must be `Sendable`: a transport is shared between the actor that
/// drives the protocol and whatever queue the network layer calls back on.
public protocol DatagramTransport: Sendable {
    /// Datagrams received from the peer, in arrival order.
    ///
    /// Finishes when the transport closes or the connection fails.
    var incoming: AsyncStream<Data> { get }

    /// Send one datagram to the peer.
    ///
    /// - Throws: `DatagramTransportError` if the transport is closed or the
    ///   write fails. UDP being what it is, a successful return means "handed
    ///   to the network", never "delivered".
    func send(_ datagram: Data) async throws

    /// Close the transport and finish `incoming`. Idempotent.
    func close() async
}
