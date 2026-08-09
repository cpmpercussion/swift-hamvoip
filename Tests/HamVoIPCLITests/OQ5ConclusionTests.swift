// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import hamvoip_cli

/// Reading the experiment's result.
///
/// The probe itself needs a live node. Turning a set of per-candidate outcomes
/// into a conclusion does not, and it is where the experiment could most
/// easily lie: "all four rejected" means "check your password", not "the
/// encoding is exotic", and a tool that says the second sends a maintainer
/// somewhere useless.
final class OQ5ConclusionTests: XCTestCase {

    private func accepted(_ challenge: String = "abc") -> OQ5Probe.Outcome {
        .accepted(challenge: challenge)
    }

    private func rejected() -> OQ5Probe.Outcome {
        .rejected(challenge: "abc", cause: "No such user", causeCode: 21)
    }

    func testASingleAcceptanceNamesTheAnswer() {
        let text = OQ5Probe.conclusion(for: [
            (.lowercaseHex, rejected()),
            (.uppercaseHex, accepted()),
        ])
        XCTAssertTrue(text.contains("uppercase-hex"))
        XCTAssertTrue(text.contains("NOT what IAX2Kit ships"),
            "an answer that differs from the shipped assumption has to say so loudly")
        XCTAssertTrue(text.contains("IAX2Call"), "and has to say where to change it")
    }

    func testConfirmingTheShippedAssumptionSaysNoCodeChangeIsNeeded() {
        let text = OQ5Probe.conclusion(for: [(.lowercaseHex, accepted())])
        XCTAssertTrue(text.contains("lowercase-hex"))
        XCTAssertTrue(text.contains("no code changes"))
        XCTAssertFalse(text.contains("NOT what IAX2Kit ships"))
    }

    /// Observed against a live ASL3 node on 2026-08-09: both hex renderings
    /// accepted, base64 and raw bytes refused. Reporting that as a broken run
    /// would have thrown away the answer, so it is pinned here.
    func testBothHexCasesAcceptedWithANonHexRefusalIsAnAnswerNotAFailedRun() {
        let text = OQ5Probe.conclusion(for: [
            (.lowercaseHex, accepted()),
            (.uppercaseHex, accepted()),
            (.base64, rejected()),
            (.rawBytes, rejected()),
        ])
        XCTAssertTrue(text.contains("hexadecimal"))
        XCTAssertTrue(text.contains("does not care about case"))
        XCTAssertTrue(text.contains("no code changes"))
        XCTAssertFalse(text.contains("should not be possible"),
            "a case-insensitive node is an ordinary node, not an unreliable run")
    }

    /// The same two acceptances without a non-hex refusal prove much less: a
    /// node that accepts everything looks identical from here.
    func testBothHexCasesAcceptedWithNothingRefusedAsksForTheFullRun() {
        let text = OQ5Probe.conclusion(for: [
            (.lowercaseHex, accepted()),
            (.uppercaseHex, accepted()),
        ])
        XCTAssertTrue(text.contains("cannot tell"))
        XCTAssertTrue(text.contains("--encoding"))
        XCTAssertFalse(text.contains("no code changes"),
            "this run has not established that the shipped encoding is checked at all")
    }

    /// A pair that no digest check can produce still has to read as broken.
    func testAnImpossiblePairOfAcceptancesIsStillReportedAsUnreliable() {
        let text = OQ5Probe.conclusion(for: [
            (.lowercaseHex, accepted()),
            (.base64, accepted()),
            (.uppercaseHex, rejected()),
        ])
        XCTAssertTrue(text.contains("should not be possible"))
        XCTAssertTrue(text.contains("repeat it"))
    }

    func testAnUnchallengedNodeIsReportedAsUnableToAnswer() {
        let text = OQ5Probe.conclusion(for: [(.lowercaseHex, .noChallengeIssued)])
        XCTAssertTrue(text.contains("did not challenge"))
    }

    func testSilenceIsReportedAsReachabilityRatherThanAsAResult() {
        let text = OQ5Probe.conclusion(for: MD5ResultEncoding.allCases.map { ($0, .timedOut) })
        XCTAssertTrue(text.contains("nothing answered") || text.contains("Nothing answered"))
        XCTAssertTrue(text.contains("no encoding was actually tested"))
    }

    func testUniversalRejectionPointsAtTheCredentialsFirst() {
        let text = OQ5Probe.conclusion(for: MD5ResultEncoding.allCases.map { ($0, rejected()) })
        XCTAssertTrue(text.contains("wrong secret") || text.contains("secret"))
        XCTAssertTrue(text.contains("check those first"))
    }

    // MARK: Outcome reporting

    func testOnlyAcceptanceCountsAsAcceptance() {
        XCTAssertTrue(accepted().isAccepted)
        XCTAssertFalse(rejected().isAccepted)
        XCTAssertFalse(OQ5Probe.Outcome.timedOut.isAccepted)
        XCTAssertFalse(OQ5Probe.Outcome.noChallengeIssued.isAccepted)
        XCTAssertFalse(OQ5Probe.Outcome.failed("boom").isAccepted)
    }

    func testTheChallengeIsCarriedThroughSoAHumanCanSeeIt() {
        XCTAssertEqual(accepted("chal-1").challenge, "chal-1")
        XCTAssertEqual(rejected().challenge, "abc")
        XCTAssertNil(OQ5Probe.Outcome.timedOut.challenge)
    }

    func testARejectionSummaryCarriesTheNodesOwnReason() {
        let summary = rejected().summary
        XCTAssertTrue(summary.contains("No such user"))
        XCTAssertTrue(summary.contains("21"))
    }

    func testEveryOutcomeHasANonEmptySummary() {
        let outcomes: [OQ5Probe.Outcome] = [
            accepted(), rejected(), .noChallengeIssued, .timedOut,
            .unexpected("INVAL"), .failed("no route to host"),
        ]
        for outcome in outcomes {
            XCTAssertFalse(outcome.summary.isEmpty)
        }
    }
}
