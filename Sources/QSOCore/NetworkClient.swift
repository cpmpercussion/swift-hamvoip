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
