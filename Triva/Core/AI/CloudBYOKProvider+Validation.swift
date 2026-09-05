//
//  CloudBYOKProvider+Validation.swift
//  Triva
//
//  Created by ben podrojsky on 03/09/2026.
//

import Foundation
import FoundationModels
import ClaudeForFoundationModels

/// Vérifie qu'une clé API Claude est valide avant qu'elle soit enregistrée en
/// Keychain (0.6) — utilisé depuis `APIKeysViewModel`, jamais depuis
/// `CloudBYOKProvider` lui-même (qui suppose une clé déjà validée/stockée).
protocol APIKeyValidating: Sendable {
    func validate(apiKey: String) async throws
}

enum APIKeyValidationError: Error, Sendable, Equatable {
    case invalidKey(description: String)
}

/// Implémentation réelle : fait un tout petit appel à l'API Claude avec la
/// clé fournie pour confirmer qu'elle est acceptée par le fournisseur. Pas de
/// test unitaire dessus (vrai appel réseau) — à valider en conditions
/// réelles, comme les autres moteurs IA du projet (0.4, 0.5).
struct ClaudeAPIKeyValidator: APIKeyValidating {
    private let model: ClaudeModel

    init(model: ClaudeModel = .sonnet5) {
        self.model = model
    }

    func validate(apiKey: String) async throws {
        let languageModel = ClaudeLanguageModel(name: model, auth: .apiKey(apiKey))
        do {
            try await languageModel.authenticateIfNeeded()
            let session = LanguageModelSession(model: languageModel)
            _ = try await session.respond(to: "Réponds uniquement par \"OK\".")
        } catch {
            throw APIKeyValidationError.invalidKey(description: String(describing: error))
        }
    }
}
