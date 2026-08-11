// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore

/// A ``DatagramTransport`` that reports every datagram crossing it and then
/// forwards it unchanged.
///
/// This exists for one reason, and it is the whole reason the OQ-7 experiment
/// taps the transport instead of listening to `M17ReflectorClient.events`:
///
/// `M17ReflectorClient` **drops any datagram that does not parse** as one of the
/// documented layouts, and `M17StreamPacket.parse` demands exactly
/// `M17StreamPacket.byteCount` bytes. That is correct behaviour — guessing at an
/// unrecognised datagram is worse — but it makes `events` useless as an
/// instrument here. If the reflector's stream frame really is 54 bytes, every
/// one of them is discarded before it reaches `events`, and a harness watching
/// `events` would report a reflector that sent no audio at all: the wrong answer
/// to OQ-7, arrived at with confidence. Observing *below* the parser is the only
/// way the experiment can see the evidence that would refute our reading of
/// Table 27.
///
/// Ordering: the observer is called before the datagram is forwarded, so a
/// report never omits a datagram the client has already acted on.
///
/// Thread safety: the only mutable state is the pump task, which is
/// lock-guarded; `AsyncStream.Continuation` is safe to call from any task.
final class RecordingTransport: DatagramTransport {

    /// Datagrams from the wrapped transport, in arrival order, republished
    /// after the observer has seen them.
    let incoming: AsyncStream<Data>

    private let upstream: any DatagramTransport
    private let continuation: AsyncStream<Data>.Continuation
    private let onOutbound: @Sendable (Data) -> Void
    private let state = State()

    /// - Parameters:
    ///   - upstream: The transport that actually moves bytes. This object
    ///     becomes the single consumer of its `incoming` stream.
    ///   - onInbound: Called once per received datagram, before it is
    ///     forwarded.
    ///   - onOutbound: Called once per sent datagram, before it is handed to
    ///     `upstream`. Called even if the send then throws — the point of the
    ///     record is what we tried to put on the wire.
    init(
        wrapping upstream: any DatagramTransport,
        onInbound: @escaping @Sendable (Data) -> Void,
        onOutbound: @escaping @Sendable (Data) -> Void = { _ in }
    ) {
        self.upstream = upstream
        self.onOutbound = onOutbound

        var escapedContinuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data>(bufferingPolicy: .unbounded) { continuation in
            escapedContinuation = continuation
        }
        self.incoming = stream
        self.continuation = escapedContinuation

        // Captured as locals: the task must not close over a partially
        // initialised `self`.
        let source = upstream.incoming
        let republish = escapedContinuation!
        let pump = Task {
            for await datagram in source {
                onInbound(datagram)
                republish.yield(datagram)
            }
            republish.finish()
        }
        state.withLock { $0.pump = pump }
    }

    func send(_ datagram: Data) async throws {
        onOutbound(datagram)
        try await upstream.send(datagram)
    }

    /// Closes the wrapped transport, which ends the pump loop and finishes
    /// ``incoming``. Idempotent, like the transport it wraps.
    func close() async {
        await upstream.close()
        let pump: Task<Void, Never>? = state.withLock { current in
            let existing = current.pump
            current.pump = nil
            return existing
        }
        pump?.cancel()
        continuation.finish()
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Storage()

        struct Storage {
            var pump: Task<Void, Never>?
        }

        func withLock<T>(_ body: (inout Storage) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(&storage)
        }
    }
}
