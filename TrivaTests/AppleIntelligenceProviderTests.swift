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

    /// Même limite que `ActiveAIProviderResolverTests.appleIntelligenceUnavailable` :
    /// pas de seam pour forcer `SystemLanguageModel.availability` à
    /// `.unavailable` depuis un test — on vérifie donc le guard de
    /// `streamGenerate(prompt:)` conditionnellement à l'état réel de la
    /// machine de test, et on signale explicitement (sévérité `.warning`)
    /// quand la branche n'est pas exercée plutôt que de la sauter en silence.
    @Test("streamGenerate() finish immédiatement avec l'erreur mappée quand Apple Intelligence est indisponible, sans yield")
    func streamGenerateFinishesImmediatelyWhenUnavailable() async throws {
        let provider = AppleIntelligenceProvider()
        guard let expectedError = provider.availabilityError else {
            Issue.record(
                "Apple Intelligence est disponible sur cette machine : la branche streamGenerateFinishesImmediatelyWhenUnavailable n'est pas exercée par ce test.",
                severity: .warning
            )
            return
        }

        var received: [String] = []
        await #expect(throws: expectedError) {
            for try await chunk in provider.streamGenerate(prompt: "Bonjour") {
                received.append(chunk)
            }
        }
        #expect(received.isEmpty)
    }
}
