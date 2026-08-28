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
