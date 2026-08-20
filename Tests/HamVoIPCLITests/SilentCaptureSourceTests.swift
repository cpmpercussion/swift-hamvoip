// SPDX-License-Identifier: Apache-2.0

import RadioCore
import XCTest

@testable import hamvoip_cli

/// `--no-audio` used to print "PTT will send silence" and send nothing at all,
/// because the only frame source lived inside the branch the flag switches off.
/// These tests are the difference between a message and a behaviour.
final class SilentCaptureSourceTests: XCTestCase {

    func testAFrameIsOneCaptureFrameOfSilence() {
        XCTAssertEqual(SilentCaptureSource.frame.count, AudioPipeline.captureFrameSize)
        XCTAssertEqual(
            SilentCaptureSource.frame.count, 160,
            "20 ms at 8 kHz — the size the microphone tap produces")
        XCTAssertTrue(SilentCaptureSource.frame.allSatisfy { $0 == 0 })
    }

    func testTheIntervalIsOneFrameOfWallClock() {
        XCTAssertEqual(SilentCaptureSource.interval, .milliseconds(20))
    }

    /// The one that would have caught the bug: frames actually arrive.
    func testItProducesTheFramesItPromises() async {
        let counter = FrameCounter()
        await SilentCaptureSource.start(limit: 3) { frame in counter.record(frame) }.value

        XCTAssertEqual(counter.count, 3)
        XCTAssertEqual(counter.lastFrameSize, AudioPipeline.captureFrameSize)
    }

    /// It stands in for a device, so it runs until it is switched off rather
    /// than until some internal count runs out.
    func testCancellationStopsIt() async {
        let counter = FrameCounter()
        let task = SilentCaptureSource.start { frame in counter.record(frame) }

        // One frame is emitted before the first sleep, so this is settled the
        // moment the task starts; the point is that cancelling ends it rather
        // than that any particular number arrived.
        try? await Task.sleep(for: .milliseconds(60))
        task.cancel()
        await task.value

        let afterCancel = counter.count
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(counter.count, afterCancel, "frames kept coming after cancellation")
    }

    /// A frame goes to the same bridge the microphone tap feeds, which is the
    /// whole point: the transmit loop cannot tell the two apart.
    func testFramesReachTheTransmitBridge() async {
        let bridge = AudioFrameBridge()
        await SilentCaptureSource.start(limit: 2) { frame in bridge.submit(frame) }.value

        var received: [[Int16]] = []
        for await frame in bridge.frames {
            received.append(frame)
            if received.count == 2 { break }
        }
        XCTAssertEqual(received.count, 2)
        XCTAssertTrue(received.allSatisfy { $0.allSatisfy { $0 == 0 } })
    }
}

/// Counts frames from the producing task's context without tripping the
/// concurrency checker.
private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var lastSize = 0

    func record(_ frame: [Int16]) {
        lock.lock()
        frames += 1
        lastSize = frame.count
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    var lastFrameSize: Int {
        lock.lock()
        defer { lock.unlock() }
        return lastSize
    }
}
