//
//  MLXDeviceCapabilityTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 13/09/2026.
//

import Foundation
import Testing
@testable import Triva

@Suite("ChipSpeedTier.parse")
struct ChipSpeedTierParseTests {
    @Test(
        "Détecte le bon tier à partir d'un nom de device Metal",
        arguments: [
            ("Apple M1", ChipSpeedTier.base),
            ("Apple M4 Pro", ChipSpeedTier.pro),
            ("Apple M2 Max", ChipSpeedTier.max),
            ("Apple M3 Ultra", ChipSpeedTier.ultra),
            ("Apple A17 Pro GPU", ChipSpeedTier.pro),
            ("Apple M4 GPU", ChipSpeedTier.base),
            ("APPLE M3 ULTRA", ChipSpeedTier.ultra),
            ("apple m4 pro", ChipSpeedTier.pro),
            ("", ChipSpeedTier.base),
        ]
    )
    func parsesDeviceName(name: String, expectedTier: ChipSpeedTier) {
        #expect(ChipSpeedTier.parse(deviceName: name) == expectedTier)
    }

    @Test("Un nom contenant à la fois 'ultra' et 'max' privilégie ultra (ordre d'évaluation)")
    func prioritizesUltraOverMax() {
        #expect(ChipSpeedTier.parse(deviceName: "Apple M3 Max Ultra Edition") == .ultra)
    }

    @Test("Un nom contenant à la fois 'max' et 'pro' privilégie max (ordre d'évaluation)")
    func prioritizesMaxOverPro() {
        #expect(ChipSpeedTier.parse(deviceName: "Apple M2 Pro Max") == .max)
    }
}
