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

    /// `SystemLanguageModel` conforme nativement au protocole `LanguageModel`
    /// de Foundation Models (voir `extension SystemLanguageModel : LanguageModel`
    /// dans le SDK) : `AppleIntelligenceProvider` utilise donc déjà le mécanisme
    /// officiel via `LanguageModelSession(model:)`, sans wrapper supplémentaire.
    /// Cette contrainte générique fait échouer la compilation si ce n'est plus
    /// le cas, garantissant que les autres providers (Cloud BYOK, MLX) pourront
    /// s'aligner sur le même contrat.
    @Test("SystemLanguageModel conforme au protocole LanguageModel")
    func systemLanguageModelConformsToLanguageModel() {
        func accepts<M: LanguageModel>(_ model: M) {}
        accepts(SystemLanguageModel.default)
    }
}
