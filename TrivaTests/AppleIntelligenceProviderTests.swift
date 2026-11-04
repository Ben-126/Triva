//
//  AppleIntelligenceProviderTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 27/08/2026.
//

import Testing
import Foundation
import FoundationModels
@testable import Triva

@MainActor
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

// MARK: - Erreurs de génération typées (bug 6)

/// Erreurs du SDK OS27 construites par leurs inits PUBLICS : aucune
/// `LanguageModelSession` n'est ouverte (sur Mac, Foundation Models tournerait
/// vraiment). Constantes de fichier, non isolées : utilisables comme arguments.
private let typedFoundationModelsErrors: [(LanguageModelError, AppleIntelligenceGenerationError)] = [
    (.contextSizeExceeded(.init(contextSize: 4_096, tokenCount: 5_120, debugDescription: "test")), .contextWindowExceeded),
    (.guardrailViolation(.init(debugDescription: "test")), .guardrailViolation),
    (.refusal(.init(explanation: "Je ne peux pas répondre.", debugDescription: "test")), .refusal),
    (.rateLimited(.init(resetDate: nil, debugDescription: "test")), .rateLimited),
    (.unsupportedLanguageOrLocale(.init(languageCode: Locale.LanguageCode("tlh"), debugDescription: "test")), .unsupportedLanguage),
    (.timeout(.init(debugDescription: "test")), .timeout),
]

/// Cas sans objet pour un prompt texte sans outil, image ni schéma.
private let inapplicableFoundationModelsErrors: [LanguageModelError] = [
    .unsupportedCapability(.init(capability: .toolCalling, debugDescription: "test")),
    .unsupportedTranscriptContent(.init(unsupportedContent: [], debugDescription: "test")),
    .unsupportedGenerationGuide(.init(schemaName: nil, debugDescription: "test")),
]

private struct UnknownEngineError: Error {}

/// Vrai si `error` est le repli générique `AppleIntelligenceError.generationFailed`.
private func isGenerationFailed(_ error: any Error) -> Bool {
    if case .generationFailed? = error as? AppleIntelligenceError { return true }
    return false
}

@MainActor
@Suite("AppleIntelligenceProvider.mapGenerationError (bug 6)")
struct AppleIntelligenceGenerationErrorMappingTests {
    @Test("Chaque cause typée du SDK OS27 devient son cas explicite", arguments: typedFoundationModelsErrors)
    func typedCauseBecomesExplicitCase(error: LanguageModelError, expected: AppleIntelligenceGenerationError) {
        let mapped = AppleIntelligenceProvider.mapGenerationError(error)
        #expect(mapped as? AppleIntelligenceGenerationError == expected)
    }

    @Test("Un cas sans objet pour un prompt texte retombe sur generationFailed", arguments: inapplicableFoundationModelsErrors)
    func inapplicableCaseFallsBackToGenerationFailed(error: LanguageModelError) {
        #expect(AppleIntelligenceProvider.generationError(for: error) == nil)
        #expect(isGenerationFailed(AppleIntelligenceProvider.mapGenerationError(error)))
    }

    @Test("Ressources du modèle absentes : modelNotReady, la même situation que la disponibilité")
    func assetsUnavailableBecomesModelNotReady() {
        let error = SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "test"))
        #expect(AppleIntelligenceProvider.mapGenerationError(error) as? AppleIntelligenceError == .modelNotReady)
    }

    @Test("L'annulation ressort intacte, jamais emballée en échec de génération")
    func cancellationPassesThroughUntouched() {
        #expect(AppleIntelligenceProvider.mapGenerationError(CancellationError()) is CancellationError)
    }

    @Test("Erreur de session ou inconnue : repli generationFailed")
    func sessionOrUnknownErrorFallsBack() {
        #expect(isGenerationFailed(AppleIntelligenceProvider.mapGenerationError(LanguageModelSession.Error.concurrentRequests)))
        #expect(isGenerationFailed(AppleIntelligenceProvider.mapGenerationError(UnknownEngineError())))
    }
}
