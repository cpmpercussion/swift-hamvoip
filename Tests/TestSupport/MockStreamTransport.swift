// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore

/// The `StreamTransport` every test uses in place of a TCP socket (AU-5).
///
/// The stream counterpart of `MockTransport`, with one addition that is the
/// whole reason it is a separate type rather than a generic: **it can control
/// how injected bytes are chunked.**
///
/// That matters because a byte stream's chunk boundaries carry no protocol
/// meaning, so a decoder must handle a frame split across two chunks and two
/// frames arriving in one. A mock that always yields one frame per chunk is
/// the comfortable case, and it is the case that hides both bugs. So:
///
/// - `inject(_:)` yields exactly the `Data` it is given, however the caller
///   chose to slice it. Use it to hand over half a frame.
/// - `injectSplit(_:at:)` yields one frame as two chunks, split at a byte
///   offset the test chooses.
/// - `injectCoalesced(_:)` concatenates several frames into a single chunk.
///
/// Outbound, `send(_:)` records into `sent` exactly as `MockTransport` does —
/// but note that on a stream, what the code under test wrote is only
/// meaningful *concatenated*: assert on `sentBytes`, not on `sent`, unless the
/// individual write boundaries are themselves under test.
///
/// `finish()` (and `close()`, which calls it) ends `incoming`, so a consumer
/// loop terminates instead of hanging a test.
///
/// Thread safety: every accessor is lock-guarded, and `AsyncStream.Continuation`
/// is itself safe to call from any task.
public final class MockStreamTransport: StreamTransport {
    public let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let state = State()

    public init() {
        var escapedContinuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data>(bufferingPolicy: .unbounded) { continuation in
            escapedContinuation = continuation
        }
        self.incoming = stream
        self.continuation = escapedContinuation
    }

    // MARK: - Outbound (what the code under test wrote)

    /// Every `Data` passed to `send(_:)`, in call order.
    ///
    /// On a stream these boundaries are the code under test's own write
    /// choices, not a protocol fact. Prefer `sentBytes` unless the boundaries
    /// are what the test is about.
    public var sent: [Data] {
        state.withLock { $0.sent }
    }

    /// Everything written, concatenated — the byte stream the peer would see.
    public var sentBytes: Data {
        state.withLock { $0.sent.reduce(into: Data()) { $0.append($1) } }
    }

    /// Convenience for the common `sent.count` assertion.
    public var sentCount: Int {
        state.withLock { $0.sent.count }
    }

    /// Drop the recorded writes — useful to ignore a login handshake before
    /// asserting on what follows.
    public func clearSent() {
        state.withLock { $0.sent.removeAll() }
    }

    /// Records `bytes` in `sent`.
    ///
    /// - Throws: `StreamTransportError.closed` after `close()`/`finish()`,
    ///   matching a real transport's behaviour.
    public func send(_ bytes: Data) async throws {
        let isClosed: Bool = state.withLock { current in
            guard !current.isClosed else { return true }
            current.sent.append(bytes)
            return false
        }
        if isClosed { throw StreamTransportError.closed }
    }

    // MARK: - Inbound (what the peer "sent" us)

    /// Deliver one chunk to `incoming`, exactly as given. No-op once the
    /// stream has finished.
    public func inject(_ bytes: Data) {
        guard !isClosed else { return }
        continuation.yield(bytes)
    }

    /// Deliver several chunks to `incoming`, in order, each as its own chunk.
    public func inject(_ chunks: [Data]) {
        for chunk in chunks { inject(chunk) }
    }

    /// Deliver `bytes` as **two** chunks, split at `offset`.
    ///
    /// The case a decoder that assumes "one chunk is one frame" gets wrong.
    /// An `offset` outside `1..<bytes.count` delivers a single chunk, since
    /// there is no meaningful split to make.
    public func injectSplit(_ bytes: Data, at offset: Int) {
        guard offset > 0, offset < bytes.count else {
            inject(bytes)
            return
        }
        let start = bytes.startIndex
        inject(Data(bytes[start ..< bytes.index(start, offsetBy: offset)]))
        inject(Data(bytes[bytes.index(start, offsetBy: offset)...]))
    }

    /// Deliver several frames as a **single** chunk.
    ///
    /// The other case a decoder gets wrong: it must keep decoding after the
    /// first frame rather than discarding the remainder of the chunk.
    public func injectCoalesced(_ frames: [Data]) {
        inject(frames.reduce(into: Data()) { $0.append($1) })
    }

    /// Deliver `bytes` one byte at a time.
    ///
    /// The pathological chunking, and a cheap way to prove a decoder is a real
    /// state machine over a buffer rather than a parser that got lucky.
    public func injectByteByByte(_ bytes: Data) {
        for byte in bytes { inject(Data([byte])) }
    }

    // MARK: - Shutdown

    /// Whether `finish()` or `close()` has run.
    public var isClosed: Bool {
        state.withLock { $0.isClosed }
    }

    /// End `incoming` without pretending the transport was closed by the code
    /// under test — the peer half-closing. Idempotent.
    public func finish() {
        let alreadyClosed: Bool = state.withLock { current in
            defer { current.isClosed = true }
            return current.isClosed
        }
        guard !alreadyClosed else { return }
        continuation.finish()
    }

    public func close() async {
        finish()
    }

    // MARK: - Locked state

    private struct Storage {
        var sent: [Data] = []
        var isClosed = false
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Storage()

        func withLock<T>(_ body: (inout Storage) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(&storage)
        }
    }
}
