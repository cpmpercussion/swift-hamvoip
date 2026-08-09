// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Loads hex-dump fixtures from a test target's resource bundle (RC-8).
///
/// Fixture format — one datagram per line, hex bytes with optional whitespace
/// between them, `#` starts a comment that runs to end of line, blank lines
/// ignored:
///
///     # NEW frame, call 1 -> 0
///     8001 0000 00000000 00 00 06 01
///     # ACK
///     8001 8002 00000000 01 01 06 04
///
/// Provenance rules (LP-1) live in `Tests/FIXTURES.md`. In short: fixtures are
/// hand-built from the specification or captured from our own sessions, never
/// copied out of another project.
public enum FixtureLoader {
    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case notFound(name: String)
        case malformedHex(name: String, line: Int, text: String)

        public var description: String {
            switch self {
            case .notFound(let name):
                return "fixture '\(name)' not found in bundle"
            case .malformedHex(let name, let line, let text):
                return "fixture '\(name)' line \(line): not valid hex: '\(text)'"
            }
        }
    }

    /// Every datagram in the named fixture, in file order.
    ///
    /// - Parameters:
    ///   - name: File name including extension, e.g. `"new-frame.hex"`.
    ///   - bundle: Pass `Bundle.module` from the calling test target.
    public static func datagrams(_ name: String, in bundle: Bundle) throws -> [Data] {
        try lines(name, in: bundle).map { Data($0) }
    }

    /// The single datagram in a fixture that contains exactly one.
    public static func datagram(_ name: String, in bundle: Bundle) throws -> Data {
        let all = try datagrams(name, in: bundle)
        precondition(all.count == 1, "fixture '\(name)' holds \(all.count) datagrams, expected 1")
        return all[0]
    }

    /// Every datagram as a byte array, for parsers that prefer `[UInt8]`.
    public static func bytes(_ name: String, in bundle: Bundle) throws -> [[UInt8]] {
        try lines(name, in: bundle)
    }

    private static func lines(_ name: String, in bundle: Bundle) throws -> [[UInt8]] {
        // `.copy("Fixtures")` preserves the directory, so resources land under
        // a "Fixtures" subdirectory of the bundle.
        let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: nil)
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw Error.notFound(name: name)
        }

        var result: [[UInt8]] = []
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let stripped = rawLine.prefix { $0 != "#" }
            let hex = stripped.filter { !$0.isWhitespace }
            if hex.isEmpty { continue }
            guard hex.count % 2 == 0 else {
                throw Error.malformedHex(name: name, line: index + 1, text: String(stripped))
            }
            var datagram: [UInt8] = []
            datagram.reserveCapacity(hex.count / 2)
            var iterator = hex.startIndex
            while iterator < hex.endIndex {
                let next = hex.index(iterator, offsetBy: 2)
                guard let byte = UInt8(hex[iterator..<next], radix: 16) else {
                    throw Error.malformedHex(name: name, line: index + 1, text: String(stripped))
                }
                datagram.append(byte)
                iterator = next
            }
            result.append(datagram)
        }
        return result
    }
}
