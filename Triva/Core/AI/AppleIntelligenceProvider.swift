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
    case generationFailed(description: String)
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
            throw AppleIntelligenceError.generationFailed(description: String(describing: error))
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
                    continuation.finish(throwing: AppleIntelligenceError.generationFailed(description: String(describing: error)))
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
}
