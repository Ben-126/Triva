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
    /// Échec TYPÉ (bug 6) — clé refusée, débit, contexte, réseau — classé par
    /// `CloudBYOKProvider.mapGenerationError`. `provider` = nom des Réglages.
    case providerFailure(provider: String, reason: CloudProviderFailure)
    /// Échec non classé. Ne porte jamais le texte d'un serveur (voir
    /// `mapGenerationError`), seulement un nom de type ou une erreur locale.
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
        } catch {
            throw Self.mapGenerationError(error)
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
                } catch {
                    continuation.finish(throwing: Self.mapGenerationError(error))
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

    // MARK: - Erreurs typées (bug 6)

    /// Nom affiché dans les messages d'erreur : celui des Réglages.
    nonisolated static let providerName = "Claude"

    /// Erreur du package `ClaudeForFoundationModels` → erreur de ce provider.
    /// L'annulation ressort INTACTE (critère de `CloudProviderFailure.isCancellation`) ;
    /// une `CloudBYOKError` déjà formée passe telle quelle.
    ///
    /// Le repli ne garde que le NOM DU TYPE, jamais `String(describing:)` : la
    /// description d'un `APIError` du package porte le message du serveur.
    nonisolated static func mapGenerationError(_ error: any Error) -> any Error {
        if error is CloudBYOKError || CloudProviderFailure.isCancellation(error) { return error }
        if let reason = failureReason(for: error) {
            return CloudBYOKError.providerFailure(provider: providerName, reason: reason)
        }
        return CloudBYOKError.generationFailed(description: String(reflecting: type(of: error)))
    }

    /// Correspondances lues dans l'`ErrorMapper` du package (version épinglée
    /// par le projet) : 429 et surcharge 529 → `LanguageModelError.rateLimited` ;
    /// 413 ou requête invalide « context » → `.contextSizeExceeded` ;
    /// `URLError.timedOut` → `.timeout` ; 401 → `ClaudeError.missingCredential`,
    /// qui veut dire « clé refusée » puisque `readAPIKey()` a déjà écarté la
    /// clé absente ; les autres `URLError` passent tels quels. Les 403, 5xx,
    /// 400 et 404 restent un `APIError` de visibilité `package`, impossible à
    /// reconnaître ici sans lire son texte : `nil`, repli générique.
    nonisolated static func failureReason(for error: any Error) -> CloudProviderFailure? {
        if case .missingCredential? = error as? ClaudeError { return .apiKeyRejected(statusCode: nil) }
        if error is URLError { return .unreachable }
        guard let modelError = error as? LanguageModelError else { return nil }
        switch modelError {
        case .rateLimited: return .rateLimited
        case .contextSizeExceeded: return .contextWindowExceeded
        case .timeout: return .unreachable
        default: return nil
        }
    }
}
