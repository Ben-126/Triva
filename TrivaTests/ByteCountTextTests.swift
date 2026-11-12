//
//  ByteCountTextTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 12/11/2026.
//

import Testing
import Foundation
@testable import Triva

@Suite("ByteCountText — tailles en français")
struct ByteCountTextTests {
    @Test("Les unités sont françaises (Mo, Go), jamais MB ni GB")
    func unitsAreFrench() {
        let megabytes = ByteCountText.string(forByteCount: Int64(430_000_000))
        let gigabytes = ByteCountText.string(forByteCount: Int64(1_050_000_000))
        #expect(megabytes.contains("Mo"))
        #expect(gigabytes.contains("Go"))
        #expect(!megabytes.contains("MB"))
        #expect(!gigabytes.contains("GB"))
    }

    @Test("Virgule décimale française")
    func decimalSeparatorIsComma() {
        #expect(ByteCountText.string(forByteCount: Int64(1_050_000_000)).contains(","))
    }

    @Test("Une taille non signée géante ne plante pas")
    func hugeUnsignedValueIsClamped() {
        #expect(!ByteCountText.string(forByteCount: UInt64.max).isEmpty)
    }
}
