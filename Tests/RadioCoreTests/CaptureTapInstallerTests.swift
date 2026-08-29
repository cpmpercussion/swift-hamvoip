// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import XCTest

@testable import RadioCore

/// RC-15 — installing the capture tap must not depend on the input device
/// holding still, and must never be able to terminate the host process.
///
/// The crash this comes from (`BU-24` in Currawong, on air, 2026-08-29) was
/// `installTap(onBus:bufferSize:format:)` rejecting a format snapshotted a
/// moment earlier, as an Objective-C `NSException` that the app's own `do/catch`
/// could not see. Nothing here can assert "no exception was raised" — an
/// `NSException` would take the test process down with it, which is precisely
/// the complaint — so what these tests pin is the *sequence* that makes the
/// mismatch unreachable:
///
/// 1. the format is never passed to the install (structural: ``CaptureTapHost``
///    has nowhere to put it), and
/// 2. the chain is checked against the node's format **after** the install, so
///    a device that moved inside the window is retried rather than left driving
///    a tap it does not match.
///
/// A fake host gives the one thing a real `AVAudioEngine` will not: a format
/// that changes at a chosen point in the sequence, on demand, with no
/// microphone and no permission prompt (AU-5).
final class CaptureTapInstallerTests: XCTestCase {
    // MARK: Fake host

    /// An input node whose format can be made to change underneath an install.
    ///
    /// `formats` is consumed one entry per read, the last one repeating
    /// forever, so a test writes the sequence of answers it wants the node to
    /// give and the installer's own read pattern decides which it sees.
    private final class FakeTapHost: CaptureTapHost {
        private var formats: [AVAudioFormat]
        private(set) var reads = 0
        private(set) var installs = 0
        private(set) var removals = 0
        private(set) var reloads = 0

        /// What the hardware says, when a test wants it to differ from what the
        /// node says (RC-16). Consumed one entry per *reload*, not per read,
        /// because a reload is the only thing that can change the answer: it
        /// lets a test say "these disagree, and then they agree".
        ///
        /// `nil` — the default — is a hardware that always agrees with the
        /// node, which is every case written before RC-16.
        var hardwareFormats: [AVAudioFormat]?

        /// Whether a tap is live right now. The installer must leave this
        /// `false` on every throwing path: a tap whose chain is wrong is the
        /// out-of-bounds read RC-14 was about.
        private(set) var tapInstalled = false

        /// Formats the installed taps were given, newest last. Always empty of
        /// meaning here beyond its count — the host is never *told* a format,
        /// which is the fix.
        private(set) var installBodies: [(AVAudioPCMBuffer) -> Void] = []

        init(_ formats: [AVAudioFormat]) {
            precondition(!formats.isEmpty)
            self.formats = formats
        }

        /// The last answer ``currentInputFormat`` gave, which is what the
        /// hardware agrees with by default — see ``hardwareInputFormat``.
        private var lastRead: AVAudioFormat?

        var currentInputFormat: AVAudioFormat {
            defer {
                lastRead = formats[0]
                if formats.count > 1 { formats.removeFirst() }
            }
            reads += 1
            return formats[0]
        }

        var hardwareInputFormat: AVAudioFormat {
            // Two things this must not do. It must not consume a `formats`
            // entry — the installer reads it once per attempt alongside
            // `currentInputFormat`, and the sequences the other tests are
            // written around count node reads. And by default it must *agree*
            // with the node's last answer rather than with the queue's next
            // one, so that a test about the device moving after the install
            // (RC-15) is not also a test about the node lagging the hardware
            // before it (RC-16).
            hardwareFormats?.first ?? lastRead ?? formats[0]
        }

        func reloadInputFormat() {
            reloads += 1
            if let hardware = hardwareFormats, hardware.count > 1 {
                hardwareFormats = Array(hardware.dropFirst())
            }
        }

        func installTap(bufferSize: AVAudioFrameCount, body: @escaping (AVAudioPCMBuffer) -> Void) {
            XCTAssertFalse(tapInstalled, "AVAudioEngine treats a second tap on one bus as a hard error")
            installs += 1
            tapInstalled = true
            installBodies.append(body)
        }

        func removeTap() {
            removals += 1
            tapInstalled = false
        }
    }

    private func format(
        rate: Double, channels: AVAudioChannelCount = 1, interleaved: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> AVAudioFormat {
        try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels,
                interleaved: interleaved),
            file: file, line: line)
    }

    private func makeChain(_ format: AVAudioFormat) -> CaptureChain? {
        CaptureChain(
            inputFormat: format,
            wireSampleRate: AudioPipeline.wireSampleRate,
            maxInputFrames: 4_096,
            frameSize: AudioPipeline.captureFrameSize,
            ringCapacity: AudioPipeline.captureRingCapacityFrames
        )
    }

    private func install(
        _ host: FakeTapHost, attempts: Int = CaptureTapInstaller.maxAttempts
    ) throws -> CaptureChain {
        try CaptureTapInstaller.install(
            host: host, bufferSize: 1_024, makeChain: makeChain, attempts: attempts)
    }

    // MARK: The ordinary case

    func testAStableDeviceInstallsOnceAndKeepsTheChain() throws {
        let host = FakeTapHost([try format(rate: 48_000)])

        let chain = try install(host)

        XCTAssertEqual(host.installs, 1)
        XCTAssertEqual(host.removals, 0, "nothing went wrong, so nothing came back down")
        XCTAssertTrue(host.tapInstalled)
        XCTAssertEqual(chain.sourceSampleRate, 48_000)
    }

    func testTheFormatIsReadAgainAfterEveryInstall() throws {
        let host = FakeTapHost([try format(rate: 48_000)])

        _ = try install(host)

        XCTAssertEqual(
            host.reads, 2,
            "one read to build the chain, one after the install to check it against what the "
                + "node actually gave the tap — the second read is the whole of RC-15's fix"
        )
    }

    // MARK: The race

    /// The BU-24 sequence exactly: the format read to build the chain is 48 kHz,
    /// and by the time the tap is in, the device is the 16 kHz Q2L. Before
    /// RC-15 this was a fatal `NSException`; now it is a retry.
    func testADeviceThatChangesInsideTheWindowIsRetriedAgainstWhatItChangedTo() throws {
        let host = FakeTapHost([
            try format(rate: 48_000),   // read to build the first chain
            try format(rate: 16_000),   // the check after installing it: moved
            try format(rate: 16_000),   // read to build the second chain
            try format(rate: 16_000),   // the check after installing that: agrees
        ])

        let chain = try install(host)

        XCTAssertEqual(chain.sourceSampleRate, 16_000, "the chain is the device's, not the snapshot's")
        XCTAssertEqual(host.installs, 2)
        XCTAssertEqual(host.removals, 1, "the mismatched tap came down before its replacement went up")
        XCTAssertTrue(host.tapInstalled)
    }

    func testAStrideChangeInsideTheWindowIsCaughtToo() throws {
        let host = FakeTapHost([
            try format(rate: 48_000, channels: 2, interleaved: false),  // stride 1
            try format(rate: 48_000, channels: 2, interleaved: true),   // stride 2, same rate
            try format(rate: 48_000, channels: 2, interleaved: true),
            try format(rate: 48_000, channels: 2, interleaved: true),
        ])

        let chain = try install(host)

        XCTAssertEqual(
            chain.channelStride, 2,
            "a rate that did not move does not mean a chain that is still right: the stride is "
                + "the sharp end (RC-14)"
        )
        XCTAssertEqual(host.installs, 2)
    }

    func testAFlappingDeviceFailsBoundedAndLeavesNoTapBehind() throws {
        // Every read gives a different rate, so no attempt can ever verify.
        let host = FakeTapHost([
            try format(rate: 48_000), try format(rate: 16_000),
            try format(rate: 44_100), try format(rate: 16_000),
            try format(rate: 48_000), try format(rate: 32_000),
            try format(rate: 16_000), try format(rate: 48_000),
            try format(rate: 16_000),
        ])

        XCTAssertThrowsError(try install(host, attempts: 4)) { error in
            XCTAssertEqual(error as? AudioPipelineError, .inputFormatUnstable)
        }
        XCTAssertEqual(host.installs, 4, "bounded: a flapping device must not spin the connect path")
        XCTAssertEqual(host.removals, 4)
        XCTAssertFalse(
            host.tapInstalled,
            "a tap whose chain is known to be wrong must never be what is left running"
        )
    }

    func testAFailureIsAThrownSwiftErrorRatherThanSomethingUncatchable() throws {
        let host = FakeTapHost([try format(rate: 48_000), try format(rate: 16_000)])

        // The point of the whole task: a caller's `do/catch` gets to run. This
        // test asserting anything at all is the assertion.
        var caught: Error?
        do {
            _ = try install(host, attempts: 1)
        } catch {
            caught = error
        }
        XCTAssertEqual(caught as? AudioPipelineError, .inputFormatUnstable)
    }

    // MARK: A device the converter cannot serve

    /// A rate the down-converter refuses — 0 Hz is what an input node with no
    /// device behind it reports — is the pre-existing `converterUnavailable`
    /// condition. What matters here is that it is still reported as that, and
    /// still without a tap going in.
    func testARateCoreAudioWillNotConvertThrowsBeforeAnythingIsInstalled() throws {
        let host = FakeTapHost([try format(rate: 0)])

        XCTAssertThrowsError(try install(host)) { error in
            XCTAssertEqual(error as? AudioPipelineError, .converterUnavailable)
        }
        XCTAssertEqual(host.installs, 0)
        XCTAssertFalse(host.tapInstalled)
    }

    func testTheAttemptCountIsAlwaysAtLeastOne() throws {
        let host = FakeTapHost([try format(rate: 48_000)])
        _ = try install(host, attempts: 0)
        XCTAssertEqual(host.installs, 1, "a zero-attempt install would be a silent no-capture")
    }

    // MARK: RC-16 — the node and the hardware disagreeing

    /// The RC-16 shape: the node still carries the departed Bluetooth headset's
    /// 16 kHz while the hardware has already moved to the built-in microphone
    /// at 44.1 kHz. Installing in that state raises an `NSException` from the
    /// engine's graph initialisation, so nothing may be installed until the two
    /// agree.
    func testADisagreementBetweenTheNodeAndTheHardwareIsNotInstalledInto() throws {
        let host = FakeTapHost([try format(rate: 16_000)])
        host.hardwareFormats = [try format(rate: 44_100)]

        XCTAssertThrowsError(try install(host)) { error in
            XCTAssertEqual(error as? AudioPipelineError, .inputFormatUnstable)
        }
        XCTAssertEqual(
            host.installs, 0,
            "installTap raises while these disagree, and a raise is not something a caller can "
                + "catch — so the attempt is spent reconciling them instead"
        )
        XCTAssertEqual(host.reloads, CaptureTapInstaller.maxAttempts)
        XCTAssertFalse(host.tapInstalled)
    }

    func testTheNodeIsReReadUntilItAgreesAndThenInstalledInto() throws {
        // The node reports 44.1 kHz throughout; the hardware disagrees once and
        // then a reload brings the two into line.
        let host = FakeTapHost([try format(rate: 44_100)])
        host.hardwareFormats = [try format(rate: 16_000), try format(rate: 44_100)]

        let chain = try install(host)

        XCTAssertEqual(host.reloads, 1, "one attempt spent reconciling, and no more")
        XCTAssertEqual(host.installs, 1)
        XCTAssertEqual(chain.sourceSampleRate, 44_100)
        XCTAssertTrue(host.tapInstalled)
    }

    func testAnInputWithNoDeviceBehindItIsNotTreatedAsADisagreement() throws {
        // An input node with nothing behind it reports 0 Hz for the hardware.
        // That is no opinion rather than a mismatch, and the useful answer is
        // the converter's, not "unstable".
        let host = FakeTapHost([try format(rate: 0)])
        host.hardwareFormats = [try format(rate: 0)]

        XCTAssertThrowsError(try install(host)) { error in
            XCTAssertEqual(error as? AudioPipelineError, .converterUnavailable)
        }
        XCTAssertEqual(host.reloads, 0)
    }

    func testAgreementIgnoresInterleavingAndComparesWhatTheEngineCompares() throws {
        let node = try format(rate: 48_000, channels: 2, interleaved: true)
        let hardware = try format(rate: 48_000, channels: 2, interleaved: false)

        XCTAssertTrue(
            CaptureTapInstaller.agrees(node: node, hardware: hardware),
            "interleaving is a property of the buffers the tap is handed — the chain's problem, "
                + "checked after the install, not the graph's"
        )
        XCTAssertFalse(
            CaptureTapInstaller.agrees(
                node: node, hardware: try format(rate: 48_000, channels: 1)),
            "channel count is in the message the engine prints when it refuses"
        )
    }
}

/// RC-15, the other half: while a chain is briefly wrong for the buffers
/// arriving — between the install and the verifying read, or between a device
/// change and the notification announcing it — the tap body must still not read
/// outside the buffer it was handed.
///
/// This is the failure that cannot be allowed to depend on anything upstream
/// being timely: an out-of-bounds read on the real-time audio thread, which is
/// how RC-14's stale stride would have shown up (and, quite possibly, `BU-23`).
/// Worth running under AddressSanitizer, where an unclamped read fails at the
/// instant it happens:
///
/// ```sh
/// swift test -Xswiftc -sanitize=address --filter CaptureTapReadBoundsTests
/// ```
final class CaptureTapReadBoundsTests: XCTestCase {
    private func processor(stride: Int) throws -> CaptureTapProcessor {
        let converter = try XCTUnwrap(
            RealTimeDownConverter(sourceSampleRate: 48_000, wireSampleRate: 8_000, maxInputFrames: 4_096))
        return CaptureTapProcessor(
            converter: converter,
            ring: RealTimeRingBuffer(frameSize: AudioPipeline.captureFrameSize, capacity: 100),
            channelStride: stride
        )
    }

    private func monoBuffer(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<Int(frames) {
            samples[index] = Float(sin(2 * Double.pi * 440 * Double(index) / 48_000))
        }
        return buffer
    }

    /// The exact stale-chain shape: a chain built for an interleaved stereo
    /// device, handed the de-interleaved mono buffers of the device that
    /// replaced it. Striding by 2 over 1,024 mono samples would read 2,048.
    func testAStrideTooLargeForTheBufferReadsOnlyWhatIsThere() throws {
        let processor = try processor(stride: 2)
        let buffer = try monoBuffer(frames: 1_024)

        processor.process(buffer)

        // 1,024 floats at stride 2 is 512 readable frames, which at 48 k → 8 k
        // is ~85 wire samples: not a whole 160-sample frame, so what is checked
        // is that the read was bounded and the ring did not overrun.
        XCTAssertEqual(processor.ring.droppedFrameCount, 0)
        XCTAssertLessThanOrEqual(processor.ring.availableFrames, 1)
    }

    func testTheCorrectStrideStillReadsTheWholeBuffer() throws {
        let strided = try processor(stride: 2)
        let correct = try processor(stride: 1)
        let buffer = try monoBuffer(frames: 4_800)

        strided.process(buffer)
        correct.process(buffer)

        XCTAssertEqual(
            correct.ring.availableFrames, 5,
            "4,800 frames at 48 kHz is 100 ms, i.e. five 20 ms wire frames"
        )
        XCTAssertEqual(
            strided.ring.availableFrames, 2,
            "half the samples are readable at stride 2, so half the wire frames — clamped, not "
                + "truncated to nothing and not read past the end"
        )
    }

    func testAZeroLengthBufferIsStillIgnoredWithAnOversizedStride() throws {
        let processor = try processor(stride: 4)
        let buffer = try monoBuffer(frames: 0)

        processor.process(buffer)

        XCTAssertEqual(processor.ring.availableFrames, 0)
    }
}
