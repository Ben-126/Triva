//
//  OpenAICompatibleProvider.swift
//  Triva
//
//  Created by ben podrojsky on 05/09/2026.
//

import Foundation

enum OpenAICompatibleProviderError: Error, Sendable, Equatable {
    /// Aucune clé API trouvée en Keychain pour ce fournisseur.
    case missingAPIKey
    /// Échec TYPÉ (bug 6), déduit du statut HTTP ou de l'erreur réseau du
    /// client — jamais de son corps. `provider` = nom des Réglages.
    case providerFailure(provider: String, reason: CloudProviderFailure)
    /// Échec non classé. Ne porte JAMAIS le corps d'une réponse serveur (voir
    /// `OpenAICompatibleProvider.mapClientError`).
    case generationFailed(description: String)
}

/// Génération de texte via un fournisseur cloud BYOK compatible OpenAI (0.6
/// élargi) : couvre tout preset de `CloudProviderCatalog` (Groq, OpenRouter,
/// Mistral, DeepSeek, etc.) ainsi que les entrées "Personnalisé" saisies par
/// l'utilisateur — un seul provider générique plutôt qu'un provider dédié
/// par fournisseur, puisqu'ils partagent tous le même contrat HTTP (voir
/// `OpenAICompatibleClient`). Claude reste sur son propre chemin
/// (`CloudBYOKProvider`), pas géré ici.
///
/// La clé est lue uniquement depuis le Keychain local et ne quitte
/// l'appareil que pour l'appel au fournisseur choisi lui-même — conforme à
/// la règle "zéro backend" du projet.
struct OpenAICompatibleProvider: AIGenerating {
    let account: String
    /// Nom affiché dans les messages d'erreur (bug 6) : celui des Réglages,
    /// porté par `OpenAICompatibleProviderError.providerFailure`.
    let providerName: String
    private let baseURL: URL
    /// Non-`private` pour permettre à `CloudProviderSelectionResolverTests` (0.6
    /// élargi) de vérifier que le modèle résolu vient bien de la sélection de
    /// l'utilisateur, pas de `preset.defaultModel`.
    let model: String
    private let keyStore: any APIKeyStoring
    private let client: any OpenAICompatibleRequesting

    /// `providerName` optionnel pour ne casser aucun appelant : sans lui, nom
    /// du preset du catalogue, sinon hôte de l'URL (voir `fallbackName`).
    init(
        account: String,
        providerName: String? = nil,
        baseURL: URL,
        model: String,
        keyStore: any APIKeyStoring = KeychainAPIKeyStore(),
        client: any OpenAICompatibleRequesting = OpenAICompatibleClient()
    ) {
        self.account = account
        let trimmedName = providerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.providerName = trimmedName.isEmpty ? Self.fallbackName(account: account, baseURL: baseURL) : trimmedName
        self.baseURL = baseURL
        self.model = model
        self.keyStore = keyStore
        self.client = client
    }

    /// Construit un provider pour un preset connu du catalogue générique
    /// (ou une entrée "Personnalisé", qui a la même forme — voir
    /// `CustomProviderStore`).
    init(
        preset: CloudProviderPreset,
        keyStore: any APIKeyStoring = KeychainAPIKeyStore(),
        client: any OpenAICompatibleRequesting = OpenAICompatibleClient()
    ) {
        self.init(
            account: preset.id,
            providerName: preset.displayName,
            baseURL: preset.baseURL,
            model: preset.defaultModel,
            keyStore: keyStore,
            client: client
        )
    }

    func generate(prompt: String) async throws -> String {
        let apiKey = try readAPIKey()
        do {
            return try await client.generate(baseURL: baseURL, apiKey: apiKey, model: model, prompt: prompt)
        } catch {
            throw Self.mapClientError(error, provider: providerName)
        }
    }

    /// Erreur du client HTTP → erreur de ce provider (bug 6). Logique pure,
    /// testable sans réseau.
    ///
    /// - Annulation INTACTE (`CloudProviderFailure.isCancellation`) ; une
    ///   `OpenAICompatibleProviderError` déjà formée passe telle quelle.
    /// - `requestFailed(statusCode:)` → `CloudProviderFailure(statusCode:)` ;
    ///   `transportError` (délai dépassé compris) → `.unreachable`.
    /// - `apiError(message:)` → `generationFailed`, SANS le message : le client
    ///   ne garde pas le statut quand le corps d'erreur JSON se décode, et le
    ///   classer en lisant ce texte serait fragile et risqué (un serveur
    ///   « Personnalisé » peut y renvoyer la clé). LIMITE CONNUE : c'est le cas
    ///   le plus fréquent (OpenAI, Groq, OpenRouter, DeepSeek… renvoient tous
    ///   `{"error":{"message":…}}`) ; il restera au message neutre tant que
    ///   `OpenAICompatibleClient` ne transmettra pas le statut.
    /// - Autre erreur : nom du type seulement, jamais sa description.
    nonisolated static func mapClientError(_ error: any Error, provider: String) -> any Error {
        if error is OpenAICompatibleProviderError || CloudProviderFailure.isCancellation(error) { return error }
        guard let clientError = error as? OpenAICompatibleClientError else {
            return OpenAICompatibleProviderError.generationFailed(description: String(reflecting: type(of: error)))
        }
        switch clientError {
        case .requestFailed(let statusCode):
            return OpenAICompatibleProviderError.providerFailure(provider: provider, reason: CloudProviderFailure(statusCode: statusCode))
        case .transportError:
            return OpenAICompatibleProviderError.providerFailure(provider: provider, reason: .unreachable)
        case .apiError:
            return OpenAICompatibleProviderError.generationFailed(description: "apiError")
        case .decodingFailed:
            return OpenAICompatibleProviderError.generationFailed(description: "decodingFailed")
        }
    }

    /// Nom de secours : preset du catalogue, sinon hôte de l'URL (saisie par
    /// l'utilisateur, pas un texte de serveur), sinon l'identifiant du compte.
    private static func fallbackName(account: String, baseURL: URL) -> String {
        CloudProviderCatalog.presets.first { $0.id == account }?.displayName ?? baseURL.host() ?? account
    }

    private func readAPIKey() throws -> String {
        let storedKey: String?
        do {
            storedKey = try keyStore.apiKey(account: account)
        } catch {
            throw OpenAICompatibleProviderError.generationFailed(description: String(describing: error))
        }

        guard let apiKey = storedKey, !apiKey.isEmpty else {
            throw OpenAICompatibleProviderError.missingAPIKey
        }
        return apiKey
    }
}

/// Valide une clé BYOK compatible OpenAI avant enregistrement en Keychain
/// (même rôle que `ClaudeAPIKeyValidator`, mais générique) : un tout petit
/// appel réel au fournisseur pour confirmer que la clé est acceptée. Pas de
/// test unitaire dessus (vrai appel réseau) — à valider en conditions
/// réelles, comme les autres validateurs du projet.
struct OpenAICompatibleAPIKeyValidator: APIKeyValidating {
    private let baseURL: URL
    private let model: String
    private let client: any OpenAICompatibleRequesting

    init(baseURL: URL, model: String, client: (any OpenAICompatibleRequesting)? = nil) {
        self.baseURL = baseURL
        self.model = model
        self.client = client ?? CloudChatClientFactory.client(forBaseURL: baseURL)
    }

    func validate(apiKey: String) async throws {
        do {
            _ = try await client.generate(
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                prompt: "Réponds uniquement par \"OK\"."
            )
        } catch {
            throw APIKeyValidationError.invalidKey(description: String(describing: error))
        }
    }
}
