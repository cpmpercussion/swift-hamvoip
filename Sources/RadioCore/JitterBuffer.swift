// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Adaptive jitter buffer (AU-3). Target depth 60–200 ms, adjusting to
/// measured inter-arrival variance.
///
/// Must be exercisable from recorded frame sequences with no socket present
/// (AU-5) — this is where most perceived audio quality is won or lost, and it
/// needs to be testable in isolation.
public struct JitterBuffer {
    public let minDepth: Duration
    public let maxDepth: Duration

    public init(
        minDepth: Duration = .milliseconds(60),
        maxDepth: Duration = .milliseconds(200)
    ) {
        self.minDepth = minDepth
        self.maxDepth = maxDepth
    }

    // TODO: ring buffer, sequence reordering, loss concealment,
    // arrival-variance estimator driving target depth.
}
