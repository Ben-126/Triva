//
//  CloudBYOKProvider.swift
//  Triva
//
//  Created by ben podrojsky on 31/08/2026.
//

import Foundation
import FoundationModels
import ClaudeForFoundationModels

/// Fournisseurs cloud BYOK supportés par Triva (0.6). Un seul cas pour
/// l'instant : ni OpenAI, ni Groq, ni Gemini n'ont à ce jour de package
/// Foundation Models officiel aussi léger que ClaudeForFoundationModels —
/// décision volontaire de Ben, pas un oubli. Ajouter un cas ici (et son
/// propre provider) le jour où un équivalent existera.
enum CloudBYOKProviderKind: String, Sendable, CaseIterable, Equatable {
    case claude
}

enum CloudBYOKError: Error, Sendable, Equatable {
    /// Aucune clé API trouvée en Keychain pour ce fournisseur.
    case missingAPIKey
    case generationFailed(description: String)
}

/// Génération de texte via une clé API Claude personnelle (BYOK cloud, 0.6).
/// La clé est lue uniquement depuis le Keychain local (jamais UserDefaults,
/// jamais en clair) et ne quitte l'appareil que pour l'appel à l'API
/// Anthropic elle-même — conforme à la règle "zéro backend" du projet.
struct CloudBYOKProvider: AIGenerating {
    private let keyStore: any APIKeyStoring
    private let account: String
    /// Non-`private` uniquement pour permettre à `CloudProviderSelectionResolverTests`
    /// (0.6 élargi) de vérifier que le modèle résolu correspond bien à la sélection de
    /// l'utilisateur — même pattern que `OpenAICompatibleProvider.account`/`.model`.
    let model: ClaudeModel

    init(
        keyStore: any APIKeyStoring = KeychainAPIKeyStore(),
        account: String = CloudBYOKProviderKind.claude.rawValue,
        model: ClaudeModel = .sonnet5
    ) {
        self.keyStore = keyStore
        self.account = account
        self.model = model
    }

    func generate(prompt: String) async throws -> String {
        let apiKey = try readAPIKey()

        let languageModel = ClaudeLanguageModel(name: model, auth: .apiKey(apiKey))
        do {
            // No-op pour `.apiKey` (seul le mode App Attest fait un vrai
            // aller-retour ici) — appelé quand même pour rester correct si
            // le mode d'auth change un jour.
            try await languageModel.authenticateIfNeeded()
            let session = LanguageModelSession(model: languageModel)
            let response = try await session.respond(to: prompt)
            return response.content
        } catch let error as CloudBYOKError {
            throw error
        } catch {
            throw CloudBYOKError.generationFailed(description: String(describing: error))
        }
    }

    /// Vrai streaming token-par-token, même principe qu'
    /// `AppleIntelligenceProvider.streamGenerate(prompt:)`. La clé API est lue
    /// AVANT toute construction de session (comme `readAPIKey()` dans
    /// `generate()`) : si absente, le flux `finish()` immédiatement avec
    /// l'erreur, sans jamais construire de `ClaudeLanguageModel`.
    func streamGenerate(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let apiKey: String
            do {
                apiKey = try readAPIKey()
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let languageModel = ClaudeLanguageModel(name: model, auth: .apiKey(apiKey))
            let task = Task {
                do {
                    try await languageModel.authenticateIfNeeded()
                    let session = LanguageModelSession(model: languageModel)
                    for try await snapshot in session.streamResponse(to: prompt) {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch let error as CloudBYOKError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: CloudBYOKError.generationFailed(description: String(describing: error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Logique pure isolée du Keychain réel via `APIKeyStoring`, pour rester
    /// testable sans vraie clé API.
    private func readAPIKey() throws -> String {
        let storedKey: String?
        do {
            storedKey = try keyStore.apiKey(account: account)
        } catch {
            throw CloudBYOKError.generationFailed(description: String(describing: error))
        }

        guard let apiKey = storedKey, !apiKey.isEmpty else {
            throw CloudBYOKError.missingAPIKey
        }
        return apiKey
    }
}
