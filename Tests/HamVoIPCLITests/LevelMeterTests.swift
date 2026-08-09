// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import hamvoip_cli

/// The level meter is the CLI's answer to "is audio flowing, and at a sane
/// level?" — one of the two questions M2 sign-off turns on. Getting the dBFS
/// arithmetic wrong would make the harness confidently report a level that is
/// not there, which is worse than reporting nothing.
final class LevelMeterTests: XCTestCase {

    // MARK: RMS

    func testSilenceIsZeroAmplitude() {
        XCTAssertEqual(LevelMeter.rms([Int16](repeating: 0, count: 160)), 0)
    }

    func testEmptyFrameIsSilenceRatherThanADivisionByZero() {
        XCTAssertEqual(LevelMeter.rms([]), 0)
        XCTAssertEqual(LevelMeter.decibels(of: []), LevelMeter.floorDB)
    }

    func testFullScaleSquareWaveIsUnityAmplitude() {
        let frame = (0..<160).map { $0.isMultiple(of: 2) ? Int16.max : Int16.min }
        // Int16.max is 32767 and Int16.min is -32768, so a full-scale square
        // wave is a hair under 1.0 by exactly half a quantisation step.
        XCTAssertEqual(LevelMeter.rms(frame), 1.0, accuracy: 0.0001)
    }

    func testIntegerMinimumDoesNotExceedFullScale() {
        // Int16.min has no positive counterpart; normalising by 32767 instead
        // of 32768 would push this above 1.0 and produce a positive dBFS,
        // which cannot happen in a 16-bit signal.
        let frame = [Int16](repeating: .min, count: 160)
        XCTAssertLessThanOrEqual(LevelMeter.rms(frame), 1.0)
        XCTAssertLessThanOrEqual(LevelMeter.decibels(of: frame), 0)
    }

    func testHalfScaleSquareWaveIsMinusSixDecibels() {
        let half = Int16(16384)
        let frame = (0..<160).map { $0.isMultiple(of: 2) ? half : -half }
        XCTAssertEqual(LevelMeter.decibels(of: frame), -6.02, accuracy: 0.05)
    }

    func testSineAtMinusTwentyDecibelsReadsBack() {
        // A −20 dBFS sine has RMS 0.1 of full scale, hence peak 0.1·√2.
        let peak = 0.1 * 2.0.squareRoot() * 32768
        let frame = (0..<160).map { index -> Int16 in
            let phase = 2 * Double.pi * 300 * Double(index) / 8000
            return Int16(max(-32768, min(32767, (peak * sin(phase)).rounded())))
        }
        XCTAssertEqual(LevelMeter.decibels(of: frame), -20, accuracy: 0.5)
    }

    // MARK: dBFS conversion

    func testZeroAmplitudeIsClampedToTheFloorRatherThanNegativeInfinity() {
        XCTAssertEqual(LevelMeter.decibels(amplitude: 0), LevelMeter.floorDB)
        XCTAssertTrue(LevelMeter.decibels(amplitude: 0).isFinite)
    }

    func testLevelsBelowTheFloorAreClampedToIt() {
        XCTAssertEqual(LevelMeter.decibels(amplitude: 1e-9), LevelMeter.floorDB)
    }

    func testUnityAmplitudeIsZeroDecibels() {
        XCTAssertEqual(LevelMeter.decibels(amplitude: 1), 0, accuracy: 0.0001)
    }

    // MARK: Bar rendering

    func testBarIsAlwaysExactlyTheRequestedWidth() {
        for db in stride(from: -80.0, through: 6.0, by: 1.0) {
            XCTAssertEqual(LevelMeter.bar(decibels: db, width: 12).count, 12, "at \(db) dBFS")
        }
    }

    func testBarIsEmptyAtTheFloorAndFullAtZero() {
        XCTAssertEqual(LevelMeter.bar(decibels: LevelMeter.floorDB, width: 10), "..........")
        XCTAssertEqual(LevelMeter.bar(decibels: 0, width: 10), "##########")
    }

    func testBarClampsRatherThanOverflowingOutOfRangeLevels() {
        XCTAssertEqual(LevelMeter.bar(decibels: -200, width: 8), "........")
        XCTAssertEqual(LevelMeter.bar(decibels: 40, width: 8), "########")
    }

    func testZeroWidthBarIsEmptyRatherThanACrash() {
        XCTAssertEqual(LevelMeter.bar(decibels: -12, width: 0), "")
    }

    func testBarFillsProportionallyBetweenFloorAndZero() {
        // Halfway from −60 to 0 is −30 dBFS.
        XCTAssertEqual(LevelMeter.bar(decibels: -30, width: 10), "#####.....")
    }

    // MARK: Formatting

    func testFloorFormatsAsMinusInfinityRatherThanANumber() {
        XCTAssertEqual(LevelMeter.format(decibels: LevelMeter.floorDB).trimmingCharacters(in: .whitespaces), "-inf")
    }

    func testFormattedLevelsAreFixedWidthSoTheStatusLineDoesNotJitter() {
        let widths = Set([-1.0, -12.5, -59.9, LevelMeter.floorDB].map { LevelMeter.format(decibels: $0).count })
        XCTAssertEqual(widths.count, 1, "every formatted level must occupy the same number of columns")
    }

    // MARK: Stateful metering

    func testPushTracksTheInstantaneousLevel() {
        var meter = LevelMeter()
        let half = Int16(16384)
        meter.push((0..<160).map { $0.isMultiple(of: 2) ? half : -half })
        XCTAssertEqual(meter.currentDB, -6.02, accuracy: 0.05)
        XCTAssertEqual(meter.frameCount, 1)
    }

    func testPeakHoldsAboveTheCurrentLevelThenDecays() {
        var meter = LevelMeter()
        let loud = [Int16](repeating: 16384, count: 160)
        let quiet = [Int16](repeating: 16, count: 160)
        meter.push(loud)
        let peakAfterLoud = meter.peakDB
        meter.push(quiet)
        XCTAssertLessThan(meter.currentDB, peakAfterLoud, "the current level must follow the quiet frame")
        XCTAssertGreaterThan(meter.peakDB, meter.currentDB, "the peak must be held above it")
        XCTAssertLessThan(meter.peakDB, peakAfterLoud, "and must decay")
    }

    func testPeakDecaysAllTheWayToTheFloorGivenEnoughSilence() {
        var meter = LevelMeter()
        meter.push([Int16](repeating: 32767, count: 160))
        for _ in 0..<500 { meter.idle() }
        XCTAssertEqual(meter.peakDB, LevelMeter.floorDB, accuracy: 0.5)
        XCTAssertEqual(meter.currentDB, LevelMeter.floorDB, accuracy: 0.5)
    }

    func testIsActiveDistinguishesSpeechFromSilence() {
        var meter = LevelMeter()
        meter.push([Int16](repeating: 0, count: 160))
        XCTAssertFalse(meter.isActive)
        meter.push([Int16](repeating: 8000, count: 160))
        XCTAssertTrue(meter.isActive)
    }

    func testRenderedFlagsClippingOnlyNearFullScale() {
        var loud = LevelMeter()
        loud.push([Int16](repeating: 32000, count: 160))
        XCTAssertTrue(loud.rendered().contains("CLIP"))

        var moderate = LevelMeter()
        moderate.push([Int16](repeating: 2000, count: 160))
        XCTAssertFalse(moderate.rendered().contains("CLIP"))
    }
}
