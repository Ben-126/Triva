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
    private let baseURL: URL
    /// Non-`private` pour permettre à `CloudProviderSelectionResolverTests` (0.6
    /// élargi) de vérifier que le modèle résolu vient bien de la sélection de
    /// l'utilisateur, pas de `preset.defaultModel`.
    let model: String
    private let keyStore: any APIKeyStoring
    private let client: any OpenAICompatibleRequesting

    init(
        account: String,
        baseURL: URL,
        model: String,
        keyStore: any APIKeyStoring = KeychainAPIKeyStore(),
        client: any OpenAICompatibleRequesting = OpenAICompatibleClient()
    ) {
        self.account = account
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
        } catch let error as OpenAICompatibleProviderError {
            throw error
        } catch {
            throw OpenAICompatibleProviderError.generationFailed(description: String(describing: error))
        }
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

    init(baseURL: URL, model: String, client: any OpenAICompatibleRequesting = OpenAICompatibleClient()) {
        self.baseURL = baseURL
        self.model = model
        self.client = client
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
