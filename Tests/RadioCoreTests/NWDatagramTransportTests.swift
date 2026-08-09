// SPDX-License-Identifier: Apache-2.0

#if canImport(Network)

import XCTest
@testable import RadioCore

/// Cancellation and lifecycle tests for `NWDatagramTransport`.
///
/// AU-5 forbids network access in unit tests, so every test here uses
/// `unreachableHost` — an address reserved by RFC 2606 to never resolve —
/// and never asserts on whether the connection *succeeds*. What is under
/// test is purely local: does a cancelled `send` come back promptly, and
/// does `incoming` finish when it should. Both matter without a single byte
/// ever needing to reach a real host: the connection sits in `.waiting`
/// (DNS never resolves, exactly as RC-1's note describes for any
/// unreachable peer) for as long as the test runs, and cleanup timing is
/// what is exercised.
final class NWDatagramTransportTests: XCTestCase {
    /// RFC 2606 reserves the `.invalid` TLD as permanently unresolvable, so
    /// this never contacts a real host, on or off a network.
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

    // MARK: - Defect 1: cancellation while awaiting readiness

    func testSendThrowsCancellationErrorWhenCancelledWhileAwaitingReadiness() async throws {
        let transport = try NWDatagramTransport(host: Self.unreachableHost, port: 4569)

        let sendTask = Task<Void, Error> {
            try await transport.send(Data([0x01, 0x02]))
        }

        // Give `send` a moment to actually reach `waitUntilReady` and park a
        // waiter before we cancel, matching the reviewer's "cancel after the
        // connection attempt is under way" repro rather than a cancel that
        // beats the call to `send` entirely.
        try await Task.sleep(for: .milliseconds(200))
        sendTask.cancel()

        // Bounded well under the 7s hang the reviewer observed; a correct
        // fix resolves this in well under a second.
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
        // The other race: cancellation lands before `waitUntilReady` even
        // registers a waiter. This must not register a waiter that then sits
        // forever, either.
        let transport = try NWDatagramTransport(host: Self.unreachableHost, port: 4569)

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

    // MARK: - Defect 2: `incoming` lifecycle

    func testIncomingFinishesWhenClosed() async throws {
        let transport = try NWDatagramTransport(host: Self.unreachableHost, port: 4569)
        await transport.close()

        let sawEnd = try await withTimeout(seconds: 5) { () -> Bool in
            var iterator = transport.incoming.makeAsyncIterator()
            return await iterator.next() == nil
        }
        XCTAssertTrue(sawEnd, "incoming must finish once the transport is closed")
    }

    func testIncomingFinishesWhenTransportIsDroppedWithoutClose() async throws {
        var transport: NWDatagramTransport? = try NWDatagramTransport(
            host: Self.unreachableHost,
            port: 4569
        )
        let incoming = transport!.incoming

        // Release the sole reference without ever calling close() — the
        // reviewer's exact repro for defect 2.
        transport = nil

        let sawEnd = try await withTimeout(seconds: 5) { () -> Bool in
            var iterator = incoming.makeAsyncIterator()
            return await iterator.next() == nil
        }
        XCTAssertTrue(sawEnd, "incoming must finish when the transport is dropped without close()")
    }

    func testCloseIsIdempotent() async throws {
        let transport = try NWDatagramTransport(host: Self.unreachableHost, port: 4569)
        await transport.close()
        await transport.close()
        await transport.close()
        // No crash, no hang: closing an already-closed transport is a no-op.
    }
}

#endif
