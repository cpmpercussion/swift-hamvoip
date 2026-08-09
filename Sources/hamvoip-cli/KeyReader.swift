// SPDX-License-Identifier: Apache-2.0

import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Keystrokes, one byte at a time, as an `AsyncStream`.
///
/// A `DispatchSource` rather than a thread parked in a blocking `read(2)`:
/// a blocked read cannot be cancelled, so a session that quits would leave a
/// thread stuck on the terminal until the process exited — which mostly works,
/// right up until something wants to run after the session ends.
///
/// Bytes, not characters, deliberately. In raw mode a keystroke is not
/// necessarily a Unicode scalar: an arrow key is three bytes, a paste is
/// however many arrive at once. The key handler is a byte-level state machine,
/// which is the only shape that does not desynchronise on input it did not
/// expect.
final class KeyReader: @unchecked Sendable {
    /// Bytes as they arrive from the terminal. Finishes on ``cancel()`` or on
    /// end-of-file.
    let keys: AsyncStream<UInt8>

    private let source: DispatchSourceRead
    private let continuation: AsyncStream<UInt8>.Continuation

    init(descriptor: Int32 = STDIN_FILENO, queue: DispatchQueue = DispatchQueue(label: "hamvoip-cli.keys")) {
        var escaped: AsyncStream<UInt8>.Continuation!
        self.keys = AsyncStream<UInt8>(bufferingPolicy: .bufferingNewest(256)) { escaped = $0 }
        self.continuation = escaped

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        self.source = source

        source.setEventHandler { [continuation] in
            var buffer = [UInt8](repeating: 0, count: 64)
            let count = buffer.withUnsafeMutableBytes { raw in
                read(descriptor, raw.baseAddress, raw.count)
            }
            guard count > 0 else {
                // 0 is end-of-file; negative with EAGAIN is a spurious wakeup
                // and must not be mistaken for one.
                if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    continuation.finish()
                }
                return
            }
            for index in 0..<count {
                continuation.yield(buffer[index])
            }
        }
        source.setCancelHandler { [continuation] in
            continuation.finish()
        }
        source.resume()
    }

    /// Stops reading and finishes ``keys``.
    func cancel() {
        source.cancel()
    }
}
