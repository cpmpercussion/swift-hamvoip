// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The seam between `AudioPipeline`'s microphone tap and `IAX2Client.send(pcm:)`.
///
/// ### Why anything sits here at all
///
/// `AudioPipeline.startCapture(onFrame:)` calls back on a real-time audio
/// thread, synchronously, fifty times a second. `IAX2Client.send(pcm:)` is an
/// `async` method on an actor. There is no way to call the second from the
/// first: `await` on the audio thread would block a real-time thread on an
/// actor's queue, which is the textbook way to produce dropouts that get
/// blamed on the network.
///
/// So the tap hands frames over and returns immediately, and an ordinary Task
/// picks them up on the other side. This type is that hand-off, and it is a
/// separate value precisely so the policy questions — how deep, what happens
/// when the consumer stalls, is anything lost silently — are decisions with
/// tests rather than accidents of whichever buffering `AsyncStream` defaulted
/// to.
///
/// ### The policy
///
/// **Bounded, dropping the oldest, and counting what it dropped.** A bounded
/// buffer is not optional: an unbounded one behind a stalled consumer grows
/// until the process dies, and the audio it accumulates is worthless anyway —
/// speech that is two seconds late is not speech, it is an artefact. Dropping
/// the *oldest* keeps the most recent audio, which is the audio the other
/// operator is waiting for.
///
/// Silent dropping is the part that would be unacceptable: dropouts that
/// nobody counts are exactly the fault RC-9 warns will "get blamed on the
/// network and chased for weeks". ``droppedFrameCount`` is surfaced on the
/// status line.
///
/// (This is a hand-off, not a fix for RC-9: `yield` still allocates, and RC-9
/// owns the allocation-free capture path. What this type guarantees is that
/// the tap never *blocks*.)
final class AudioFrameBridge: @unchecked Sendable {
    /// Frames buffered before the oldest starts being dropped. 25 frames is
    /// half a second at 20 ms — long enough to ride out a scheduling hiccup,
    /// short enough that a real stall is heard as a gap rather than as growing
    /// delay.
    static let defaultCapacity = 25

    /// Captured frames, oldest first, exactly as the tap produced them.
    let frames: AsyncStream<[Int16]>

    private let continuation: AsyncStream<[Int16]>.Continuation
    private let lock = NSLock()
    private var dropped = 0
    private var submitted = 0

    init(capacity: Int = AudioFrameBridge.defaultCapacity) {
        var escaped: AsyncStream<[Int16]>.Continuation!
        self.frames = AsyncStream<[Int16]>(bufferingPolicy: .bufferingNewest(capacity)) {
            escaped = $0
        }
        self.continuation = escaped
    }

    /// Hands one captured frame to the consumer. **Called on the audio thread**
    /// — it takes a short uncontended lock and never awaits.
    func submit(_ frame: [Int16]) {
        let result = continuation.yield(frame)
        lock.lock()
        submitted += 1
        if case .dropped = result { dropped += 1 }
        lock.unlock()
    }

    /// How many frames were discarded because the consumer was not keeping up.
    /// Anything but zero during a live test is a finding.
    var droppedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }

    /// How many frames the tap has produced. A capture path that is running
    /// increments this fifty times a second; one that never starts leaves it
    /// at zero, which is the difference between "no audio" and "no microphone".
    var submittedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return submitted
    }

    /// Ends ``frames``, so the consuming task's `for await` loop returns.
    func finish() {
        continuation.finish()
    }
}
