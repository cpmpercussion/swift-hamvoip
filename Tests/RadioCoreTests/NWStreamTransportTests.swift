// SPDX-License-Identifier: Apache-2.0

#if canImport(Network)

import Network
import XCTest
@testable import RadioCore

/// Cancellation and lifecycle tests for `NWStreamTransport` (EL-3).
///
/// The same shape, and the same constraint, as `NWDatagramTransportTests`:
/// AU-5 forbids network access, so every test uses `unreachableHost` — an
/// RFC 2606 `.invalid` name that never resolves — and never asserts on whether
/// the connection succeeds. What is under test is local: a cancelled `send`
/// comes back promptly, and `incoming` finishes when it should.
final class NWStreamTransportTests: XCTestCase {
    private static let unreachableHost = "no-such-host.invalid"

    /// Races `operation` against a wall-clock timeout so a regression that
    /// reintroduces a hang fails this test instead of hanging CI forever.
    private func withTimeout<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private struct TimeoutError: Error {}

    // MARK: - Construction

    func testPortZeroIsRejected() {
        XCTAssertThrowsError(try NWStreamTransport(host: Self.unreachableHost, port: 0)) { error in
            guard case StreamTransportError.invalidEndpoint = error else {
                return XCTFail("expected .invalidEndpoint, got \(error)")
            }
        }
    }

    // MARK: - Parameters

    /// Nagle must be off, and it must be off on the *transport* layer.
    ///
    /// The regression this pins: `noDelay` used to be set inside
    /// `if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options`.
    /// That is the IP layer, the cast never succeeded, and the connection ran
    /// with Nagle on while the comment above it said otherwise. Reading the
    /// option back through `transportProtocol` is what makes the failure
    /// visible — a test that only checked "some layer has noDelay" would have
    /// passed the broken version too.
    func testSignallingParametersDisableNagleOnTheTransportLayer() {
        let parameters = SignallingParameters.make()

        guard let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options else {
            return XCTFail("expected TCP options on the transport protocol stack")
        }
        XCTAssertTrue(tcp.noDelay)
        XCTAssertEqual(parameters.serviceClass, .responsiveData)
        XCTAssertNil(parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options,
                     "the IP layer is not where TCP options live — that was the bug")
    }

    // MARK: - Cancellation while awaiting readiness

    func testSendThrowsCancellationErrorWhenCancelledWhileAwaitingReadiness() async throws {
        let transport = try NWStreamTransport(host: Self.unreachableHost, port: 8100)

        let sendTask = Task<Void, Error> {
            try await transport.send(Data([0x01, 0x02]))
        }

        // Let `send` reach `waitUntilReady` and park a waiter before cancelling.
        try await Task.sleep(for: .milliseconds(200))
        sendTask.cancel()

        let outcome = try await withTimeout(seconds: 5) {
            do {
                try await sendTask.value
                return "returned normally"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "threw \(error)"
            }
        }

        XCTAssertEqual(outcome, "cancelled", "a cancelled send must throw CancellationError promptly")
        await transport.close()
    }

    func testCancellingBeforeSendEverRunsStillThrowsCancellationPromptly() async throws {
        let transport = try NWStreamTransport(host: Self.unreachableHost, port: 8100)

        let sendTask = Task<Void, Error> {
            try await transport.send(Data([0x01]))
        }
        sendTask.cancel()

        let outcome = try await withTimeout(seconds: 5) {
            do {
                try await sendTask.value
                return "returned normally"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "threw \(error)"
            }
        }

        XCTAssertEqual(outcome, "cancelled")
        await transport.close()
    }

    // MARK: - `incoming` lifecycle

    func testIncomingFinishesWhenClosed() async throws {
        let transport = try NWStreamTransport(host: Self.unreachableHost, port: 8100)
        await transport.close()

        let sawEnd = try await withTimeout(seconds: 5) { () -> Bool in
            var iterator = transport.incoming.makeAsyncIterator()
            return await iterator.next() == nil
        }
        XCTAssertTrue(sawEnd, "incoming must finish once the transport is closed")
    }

    func testIncomingFinishesWhenTransportIsDroppedWithoutClose() async throws {
        var transport: NWStreamTransport? = try NWStreamTransport(
            host: Self.unreachableHost,
            port: 8100
        )
        let incoming = transport!.incoming

        transport = nil

        let sawEnd = try await withTimeout(seconds: 5) { () -> Bool in
            var iterator = incoming.makeAsyncIterator()
            return await iterator.next() == nil
        }
        XCTAssertTrue(sawEnd, "incoming must finish when the transport is dropped without close()")
    }

    func testSendAfterCloseThrowsClosed() async throws {
        let transport = try NWStreamTransport(host: Self.unreachableHost, port: 8100)
        await transport.close()

        let outcome = try await withTimeout(seconds: 5) { () -> String in
            do {
                try await transport.send(Data([0x01]))
                return "returned normally"
            } catch let error as StreamTransportError {
                return error.description
            } catch {
                return "threw \(error)"
            }
        }
        XCTAssertEqual(outcome, StreamTransportError.closed.description)
    }

    func testCloseIsIdempotent() async throws {
        let transport = try NWStreamTransport(host: Self.unreachableHost, port: 8100)
        await transport.close()
        await transport.close()
        await transport.close()
        // No crash, no hang.
    }
}

#endif
