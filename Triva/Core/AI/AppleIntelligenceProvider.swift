//
//  AppleIntelligenceProvider.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import Foundation
import FoundationModels

/// Interface commune à tous les moteurs de génération de texte (Apple
/// Intelligence, MLX local — 0.5, clé API perso — 0.6), pour que le pipeline
/// de recherche (0.7) puisse appeler le moteur choisi sans connaître son type.
protocol AIGenerating: Sendable {
    func generate(prompt: String) async throws -> String

    /// Génération en streaming (0.8) : un yield par étape de génération. Les
    /// providers basés sur `LanguageModelSession` (`AppleIntelligenceProvider`,
    /// `MLXProvider`, `CloudBYOKProvider`) renvoient un vrai flux
    /// token-par-token ; tout autre provider hérite de l'implémentation par
    /// défaut (un seul yield du texte complet, voir l'extension ci-dessous).
    func streamGenerate(prompt: String) -> AsyncThrowingStream<String, Error>
}

/// Implémentation par défaut de `streamGenerate` pour tout provider qui ne
/// sait pas streamer nativement (ex. `OpenAICompatibleProvider`, dont le
/// client HTTP ne gère pas le SSE en 0.8) : un seul yield contenant le texte
/// complet renvoyé par `generate(prompt:)`, puis `finish()`. Garantit aussi
/// que les mocks de test existants qui n'implémentent que `generate(prompt:)`
/// continuent de compiler sans changement.
extension AIGenerating {
    func streamGenerate(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let text = try await generate(prompt: prompt)
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum AppleIntelligenceError: Error, Sendable, Equatable {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unavailableForOtherReason
    /// Échec de génération NON classé par `AppleIntelligenceProvider.mapGenerationError`
    /// (les causes reconnues sont des `AppleIntelligenceGenerationError`).
    case generationFailed(description: String)
}

/// Cause TYPÉE d'un échec de génération d'Apple Intelligence (bug 6), lue sur
/// les erreurs du SDK OS27 (`LanguageModelError`, voir
/// `AppleIntelligenceProvider.mapGenerationError`) — jamais déduite du texte
/// d'une description. Avant, tout échec devenait `generationFailed` et
/// l'utilisateur lisait « generationFailed(description: …) ».
///
/// Type SÉPARÉ d'`AppleIntelligenceError`, à dessein : ce dernier décrit la
/// DISPONIBILITÉ du modèle, que `SearchSetupRequirement` (ContentView) traite
/// par un `switch` exhaustif. Y ajouter ces cas forcerait l'écran de
/// configuration à gérer des échecs qu'il ne reçoit jamais (la disponibilité
/// est vérifiée avant toute session).
///
/// `nonisolated` : donnée pure, levée depuis la tâche de streaming et comparée
/// hors du main actor.
nonisolated enum AppleIntelligenceGenerationError: Error, Sendable, Equatable, CaseIterable {
    /// Instructions + prompt (question, sources, historique) au-delà de la
    /// fenêtre de contexte du modèle (`LanguageModelError.contextSizeExceeded`).
    /// Possible dès le premier tour : sources longues, texte CJK.
    case contextWindowExceeded
    /// Garde-fous de sécurité d'Apple (`.guardrailViolation`). Ils lisent tout
    /// le prompt : le texte d'une source peut les déclencher, pas seulement la
    /// question — d'où « choisis un autre moteur » dans le message.
    case guardrailViolation
    /// Le modèle décline de lui-même, sans garde-fou en cause (`.refusal`).
    case refusal
    /// Limite de débit du système (`.rateLimited`).
    case rateLimited
    /// Langue ou locale non prise en charge (`.unsupportedLanguageOrLocale`).
    case unsupportedLanguage
    /// Délai dépassé (`.timeout`, nouveau en OS27).
    case timeout

    /// Message français fixe et actionnable, affiché par
    /// `ChatViewModel.userFacingMessage(for:)` (même principe que
    /// `ChatHistoryStoreError.userFacingMessage`).
    var userFacingMessage: String {
        switch self {
        case .contextWindowExceeded:
            "La conversation et ses sources sont trop longues pour Apple Intelligence. Commence une nouvelle conversation ou choisis un autre moteur dans les Réglages."
        case .guardrailViolation:
            "Les garde-fous d'Apple Intelligence ont bloqué cette réponse. Reformule ta question ou choisis un autre moteur dans les Réglages."
        case .refusal:
            "Apple Intelligence a refusé de répondre. Reformule ta question ou choisis un autre moteur dans les Réglages."
        case .rateLimited:
            "Apple Intelligence limite temporairement les requêtes. Réessaie dans un instant."
        case .unsupportedLanguage:
            "Apple Intelligence ne prend pas en charge la langue de cette demande. Écris dans une autre langue ou choisis un autre moteur dans les Réglages."
        case .timeout:
            "Apple Intelligence a mis trop de temps à répondre. Réessaie."
        }
    }
}

/// Génération de texte via Apple Intelligence (Foundation Models), 100% sur
/// l'appareil. Port du besoin décrit en 0.4 du plan : vérifier la
/// disponibilité avant tout appel, pour permettre à l'appelant (0.3) de
/// renvoyer vers l'écran de sélection du moteur IA si indisponible.
struct AppleIntelligenceProvider: AIGenerating {
    private let model: SystemLanguageModel

    init(model: SystemLanguageModel = .default) {
        self.model = model
    }

    /// `nil` si le modèle est utilisable, sinon la raison précise de
    /// l'indisponibilité (à afficher à l'utilisateur avant de renvoyer vers 0.3).
    var availabilityError: AppleIntelligenceError? {
        Self.mapAvailability(model.availability)
    }

    func generate(prompt: String) async throws -> String {
        if let error = availabilityError {
            throw error
        }

        let session = LanguageModelSession(model: model)
        do {
            let response = try await session.respond(to: prompt)
            return response.content
        } catch {
            throw Self.mapGenerationError(error)
        }
    }

    /// Vrai streaming token-par-token via `LanguageModelSession.streamResponse(to:)` :
    /// chaque `Snapshot.content` reçu est déjà le texte cumulatif généré
    /// jusque-là (pas un delta), donc chaque yield du flux renvoyé ici l'est
    /// aussi — à l'appelant (0.8, affichage) de gérer ce cumul comme il
    /// l'entend. Même vérification de disponibilité qu'`generate(prompt:)`,
    /// faite AVANT toute construction de `LanguageModelSession` : si
    /// indisponible, le flux `finish()` immédiatement avec l'erreur, sans
    /// toucher à `LanguageModelSession`.
    func streamGenerate(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            if let error = availabilityError {
                continuation.finish(throwing: error)
                return
            }

            let session = LanguageModelSession(model: model)
            let task = Task {
                do {
                    for try await snapshot in session.streamResponse(to: prompt) {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapGenerationError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Logique pure de correspondance `Availability` -> erreur applicative,
    /// isolée pour rester testable sans dépendre d'un appareil réel.
    static func mapAvailability(_ availability: SystemLanguageModel.Availability) -> AppleIntelligenceError? {
        switch availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady):
            return .modelNotReady
        case .unavailable:
            return .unavailableForOtherReason
        }
    }

    /// Erreur levée par `LanguageModelSession` → erreur de ce provider (bug 6).
    /// Logique pure, testable avec les inits publics des erreurs du SDK, sans
    /// jamais ouvrir de session.
    ///
    /// - L'annulation ressort INTACTE : emballée dans `generationFailed`, elle
    ///   passerait pour un échec auprès de `SearchOrchestrator.isCancellation`.
    /// - `SystemLanguageModel.Error.assetsUnavailable` (ressources du modèle
    ///   absentes de l'appareil) → `.modelNotReady` : c'est la situation de
    ///   `Availability.modelNotReady`, téléchargement géré par le système.
    /// - `LanguageModelSession.GenerationError` (iOS 26) n'est PAS lu, sur la
    ///   foi de la note de dépréciation d'Apple (documentation du type, lue le
    ///   2026-11-03) : « When your app is built against Xcode 27 or later, the
    ///   framework throws `LanguageModelError`, `SystemLanguageModel.Error`, or
    ///   `LanguageModelSession.Error` instead. […] Apps built against Xcode 26
    ///   continues to receive `LanguageModelSession.GenerationError`. » Triva,
    ///   compilée avec Xcode 27 et réservée à OS27, ne reçoit donc jamais
    ///   l'ancien type : le lire serait du code mort, source d'avertissements,
    ///   qui casserait le build le jour où il deviendra indisponible. Le
    ///   « exceededContextWindowSize » du rapport du bug 6 est le nom iOS 26 du
    ///   cas (audit du code), pas une erreur observée sur un build Xcode 27.
    ///   Arrivait-il malgré tout, il tomberait dans `generationFailed` : le
    ///   message générique d'avant, pas une régression.
    nonisolated static func mapGenerationError(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let modelError = error as? LanguageModelError, let cause = generationError(for: modelError) {
            return cause
        }
        if let systemError = error as? SystemLanguageModel.Error, case .assetsUnavailable = systemError {
            return AppleIntelligenceError.modelNotReady
        }
        // Erreur locale (modèle sur l'appareil) : sa description ne porte aucun
        // texte de serveur, elle reste utile au diagnostic et n'est jamais affichée.
        return AppleIntelligenceError.generationFailed(description: String(describing: error))
    }

    /// Correspondance des cas du SDK OS27 (vérifiés dans
    /// `FoundationModels.swiftinterface`). `nil` pour les cas sans objet avec un
    /// prompt texte sans outil, image ni schéma (`unsupportedCapability`,
    /// `unsupportedTranscriptContent`, `unsupportedGenerationGuide`) et pour un
    /// cas ajouté par un futur SDK : repli générique, jamais de crash.
    nonisolated static func generationError(for error: LanguageModelError) -> AppleIntelligenceGenerationError? {
        switch error {
        case .contextSizeExceeded: .contextWindowExceeded
        case .guardrailViolation: .guardrailViolation
        case .refusal: .refusal
        case .rateLimited: .rateLimited
        case .unsupportedLanguageOrLocale: .unsupportedLanguage
        case .timeout: .timeout
        case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide: nil
        @unknown default: nil
        }
    }
}
