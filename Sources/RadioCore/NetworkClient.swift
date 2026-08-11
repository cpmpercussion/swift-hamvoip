// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Transmit state for a connected network.
public enum TransmitState: Sendable, Equatable {
    case receiving
    case transmitting(since: Date)
    case idle
}

/// Every mode conforms to this. The SwiftUI layer talks only to this protocol
/// and knows nothing about IAX2, M17 or EchoLink specifics.
public protocol NetworkClient: AnyObject, Sendable {
    associatedtype Destination

    var state: TransmitState { get }

    func connect(to destination: Destination) async throws
    func disconnect() async

    /// Begin transmitting. Implementations must honour the transmit watchdog
    /// (SF-1) and drop on interruption (SF-3).
    func startTransmit() async throws
    func stopTransmit() async
}

/// A lock-guarded ``TransmitState``, so an actor's ``NetworkClient/state`` can
/// satisfy the protocol's synchronous requirement.
///
/// Small and deliberate: an actor cannot satisfy a non-`async` protocol
/// requirement with an isolated property, and making the requirement `async`
/// would push an `await` into every SwiftUI body that wants to know whether it
/// is transmitting. Shared by `IAX2Client` and `M17Client`.
public final class TransmitStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: TransmitState = .idle

    public init() {}

    public var value: TransmitState {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
    }
}
