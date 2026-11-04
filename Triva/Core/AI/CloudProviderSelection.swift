//
//  CloudProviderSelection.swift
//  Triva
//
//  Created by ben podrojsky on 05/09/2026.
//

import Foundation
import ClaudeForFoundationModels

/// Le fournisseur + modèle cloud BYOK actuellement choisis par l'utilisateur
/// (0.6 élargi — sélection de fournisseur/modèle). `providerID` vaut soit
/// `CloudProviderSelectionResolver.claudeProviderID` ("claude"), soit l'`id`
/// d'un preset de `CloudProviderCatalog`, soit l'`id` d'un fournisseur
/// personnalisé créé via `CustomProviderStore` — les trois espaces d'id ne se
/// recoupent jamais (voir leurs préfixes/valeurs respectifs).
/// `nonisolated` pour la même raison que les modèles SearXNG : porteur de
/// données pur, déjà `Sendable`, comparé et décodé depuis des contextes non
/// isolés. Sans ce marqueur, sa conformité à `Equatable` reste isolée au main
/// actor et le mode de langage Swift 6 refuse de l'utiliser ailleurs
/// (« main actor-isolated conformance ... cannot be used in nonisolated context »).
nonisolated struct CloudProviderSelection: Sendable, Equatable, Codable {
    let providerID: String
    let model: String
}

/// Résout une `CloudProviderSelection` vers un `AIGenerating` concret. Logique
/// pure, testable sans Keychain réel via `keyStore` (défaut = vrai Keychain).
enum CloudProviderSelectionResolver {
    static let claudeProviderID = CloudBYOKProviderKind.claude.rawValue

    /// Modèles Claude connus de Triva, du plus capable au moins capable —
    /// `ClaudeModel` (package `ClaudeForFoundationModels`) est une struct à
    /// constantes statiques, pas un `CaseIterable`, cette liste est donc
    /// maintenue à la main ici.
    static let knownClaudeModels: [ClaudeModel] = [
        .opus5,
        .sonnet5,
        .opus4_8,
        .opus4_7,
        .opus4_6,
        .sonnet4_6,
        .haiku4_5
    ]

    /// Modèle connu correspondant à `id`, y compris sous sa forme datée
    /// renvoyée par `GET /v1/models` (`claude-haiku-4-5-20251001` → alias
    /// `claude-haiku-4-5` du package). `nil` si l'id n'est pas compilé ici.
    static func claudeModel(forID id: String) -> ClaudeModel? {
        knownClaudeModels.first { $0.id == id || isDatedVariant(id, of: $0.id) }
    }

    /// Capacités prêtées à un modèle Claude que Triva ne connaît pas encore
    /// (sorti après cette version, choisi dans la liste de l'API). Le package
    /// refuse volontairement de les deviner : un champ envoyé à un modèle qui
    /// le rejette est une erreur 400. D'où le principe « requête minimale » :
    /// - `samplingParams` et `adaptiveThinking` à faux, `effortLevels` vide :
    ///   ce sont les seuls champs ajoutés d'office à la requête, et Sonnet 5 /
    ///   Opus 4.7+ rejettent déjà les paramètres d'échantillonnage. Sans eux,
    ///   la requête est un appel Messages simple, accepté par tout modèle
    ///   Claude — au prix d'une réflexion étendue non demandée.
    /// - `structuredOutput` et `imageInput` à vrai : n'ajoutent rien tant que
    ///   l'appelant ne fournit ni schéma ni image, et tous les modèles Claude
    ///   actuels les acceptent (les mettre à faux ferait échouer localement
    ///   une génération guidée que le modèle sait faire).
    static let unknownClaudeModelCapabilities = ClaudeModel.Capabilities(
        samplingParams: false,
        effortLevels: [],
        adaptiveThinking: false,
        structuredOutput: true,
        imageInput: true
    )

    /// Toujours un modèle : connu (capacités précises) sinon construit avec
    /// `unknownClaudeModelCapabilities`.
    static func resolvedClaudeModel(forID id: String) -> ClaudeModel {
        claudeModel(forID: id) ?? ClaudeModel(id: id, capabilities: unknownClaudeModelCapabilities)
    }

    /// `id` = `knownID` suivi d'une date `-AAAAMMJJ`.
    static func isDatedVariant(_ id: String, of knownID: String) -> Bool {
        guard id.hasPrefix(knownID + "-") else { return false }
        let suffix = id.dropFirst(knownID.count + 1)
        return suffix.count == 8 && suffix.allSatisfy(\.isNumber)
    }

    /// `nil` si `selection` ne correspond à aucun fournisseur connu
    /// (`providerID` absent à la fois du catalogue générique et de
    /// `customPresets`) ou si son modèle Claude est vide. Un modèle Claude
    /// inconnu est accepté, voir `unknownClaudeModelCapabilities`.
    static func makeProvider(
        for selection: CloudProviderSelection,
        customPresets: [CloudProviderPreset],
        keyStore: any APIKeyStoring = KeychainAPIKeyStore()
    ) -> (any AIGenerating)? {
        if selection.providerID == claudeProviderID {
            guard !selection.model.isEmpty else { return nil }
            return CloudBYOKProvider(
                keyStore: keyStore,
                account: selection.providerID,
                model: resolvedClaudeModel(forID: selection.model)
            )
        }

        guard let preset = (CloudProviderCatalog.presets + customPresets).first(where: { $0.id == selection.providerID }) else {
            return nil
        }
        // Perplexity : Agent API (Sonar Chat Completions arrêté), pas /chat/completions.
        if PerplexityAgentClient.handles(baseURL: preset.baseURL) {
            return PerplexityAgentProvider(
                account: preset.id,
                baseURL: preset.baseURL,
                model: selection.model,
                keyStore: keyStore
            )
        }
        // Init memberwise volontairement, pas `init(preset:)` : ce dernier
        // fige `preset.defaultModel`, alors que le modèle choisi par
        // l'utilisateur (`selection.model`) doit toujours primer. Le nom suit
        // le preset, personnalisé compris, pour les messages d'erreur (bug 6).
        return OpenAICompatibleProvider(
            account: preset.id,
            providerName: preset.displayName,
            baseURL: preset.baseURL,
            model: selection.model,
            keyStore: keyStore
        )
    }
}
