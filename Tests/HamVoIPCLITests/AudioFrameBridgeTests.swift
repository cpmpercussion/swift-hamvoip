// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import hamvoip_cli

/// The hand-off between the real-time capture callback and the actor that
/// sends frames. No audio hardware is involved in any of this — the whole
/// point of isolating it as a value is that its policy (bounded, drop-oldest,
/// count the drops) is testable without a microphone.
final class AudioFrameBridgeTests: XCTestCase {

    private func frame(_ marker: Int16) -> [Int16] {
        [Int16](repeating: marker, count: 160)
    }

    func testFramesArriveInOrderWhenTheConsumerKeepsUp() async {
        let bridge = AudioFrameBridge(capacity: 8)
        for index in 0..<5 { bridge.submit(frame(Int16(index))) }
        bridge.finish()

        var received: [Int16] = []
        for await frame in bridge.frames { received.append(frame[0]) }

        XCTAssertEqual(received, [0, 1, 2, 3, 4])
        XCTAssertEqual(bridge.droppedFrameCount, 0)
        XCTAssertEqual(bridge.submittedFrameCount, 5)
    }

    func testFrameContentsSurviveTheHandOffUnchanged() async {
        let bridge = AudioFrameBridge(capacity: 4)
        let original = (0..<160).map { Int16($0 - 80) }
        bridge.submit(original)
        bridge.finish()

        var received: [[Int16]] = []
        for await frame in bridge.frames { received.append(frame) }
        XCTAssertEqual(received, [original])
    }

    func testAStalledConsumerLosesTheOldestFramesAndTheLossIsCounted() async {
        // A bounded buffer must be bounded: capacity 3, ten frames pushed, and
        // nobody reading. The newest three survive, seven are counted lost.
        let bridge = AudioFrameBridge(capacity: 3)
        for index in 0..<10 { bridge.submit(frame(Int16(index))) }
        bridge.finish()

        var received: [Int16] = []
        for await frame in bridge.frames { received.append(frame[0]) }

        XCTAssertEqual(received, [7, 8, 9], "the most recent audio is what is worth keeping")
        XCTAssertEqual(bridge.droppedFrameCount, 7)
        XCTAssertEqual(bridge.submittedFrameCount, 10)
    }

    func testNoFramesAreDroppedRightUpToCapacity() async {
        let bridge = AudioFrameBridge(capacity: 25)
        for index in 0..<25 { bridge.submit(frame(Int16(index))) }
        XCTAssertEqual(bridge.droppedFrameCount, 0)
        bridge.finish()
    }

    func testFinishEndsTheConsumingLoop() async {
        let bridge = AudioFrameBridge(capacity: 4)
        bridge.submit(frame(1))
        bridge.finish()

        var count = 0
        for await _ in bridge.frames { count += 1 }
        // The loop returning at all is the assertion; a bridge that never
        // finished would hang this test rather than fail it, so the count is
        // just a sanity check on what came through first.
        XCTAssertEqual(count, 1)
    }

    func testSubmittingFromManyThreadsLosesNothingUncounted() async {
        // The real submitter is an audio render thread, and the counters are
        // read from the status ticker on another. Every frame must be either
        // delivered or counted as dropped — never neither.
        let bridge = AudioFrameBridge(capacity: 64)
        let total = 400
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<total {
                group.addTask { bridge.submit([Int16](repeating: Int16(index % 100), count: 160)) }
            }
        }
        bridge.finish()

        var delivered = 0
        for await _ in bridge.frames { delivered += 1 }

        XCTAssertEqual(bridge.submittedFrameCount, total)
        XCTAssertEqual(delivered + bridge.droppedFrameCount, total)
    }
}
