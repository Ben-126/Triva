//
//  AppleIntelligenceProviderTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 27/08/2026.
//

import Testing
import FoundationModels
@testable import Triva

@Suite("AppleIntelligenceProvider.mapAvailability")
struct AppleIntelligenceProviderTests {
    @Test("Aucune erreur quand le modèle est disponible")
    func noErrorWhenAvailable() {
        let error = AppleIntelligenceProvider.mapAvailability(.available)
        #expect(error == nil)
    }

    @Test("Signale un appareil non éligible")
    func deviceNotEligible() {
        let error = AppleIntelligenceProvider.mapAvailability(.unavailable(.deviceNotEligible))
        #expect(error == .deviceNotEligible)
    }

    @Test("Signale Apple Intelligence désactivé dans les Réglages")
    func appleIntelligenceNotEnabled() {
        let error = AppleIntelligenceProvider.mapAvailability(.unavailable(.appleIntelligenceNotEnabled))
        #expect(error == .appleIntelligenceNotEnabled)
    }

    @Test("Signale un modèle pas encore prêt (téléchargement en cours)")
    func modelNotReady() {
        let error = AppleIntelligenceProvider.mapAvailability(.unavailable(.modelNotReady))
        #expect(error == .modelNotReady)
    }
}
