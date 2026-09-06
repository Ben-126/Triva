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
struct CloudProviderSelection: Sendable, Equatable, Codable {
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

    static func claudeModel(forID id: String) -> ClaudeModel? {
        knownClaudeModels.first { $0.id == id }
    }

    /// `nil` si `selection` ne correspond à aucun fournisseur connu (modèle
    /// Claude inconnu, ou `providerID` absent à la fois du catalogue
    /// générique et de `customPresets`).
    static func makeProvider(
        for selection: CloudProviderSelection,
        customPresets: [CloudProviderPreset],
        keyStore: any APIKeyStoring = KeychainAPIKeyStore()
    ) -> (any AIGenerating)? {
        if selection.providerID == claudeProviderID {
            guard let model = claudeModel(forID: selection.model) else { return nil }
            return CloudBYOKProvider(keyStore: keyStore, account: selection.providerID, model: model)
        }

        guard let preset = (CloudProviderCatalog.presets + customPresets).first(where: { $0.id == selection.providerID }) else {
            return nil
        }
        // Init memberwise volontairement, pas `init(preset:)` : ce dernier
        // fige `preset.defaultModel`, alors que le modèle choisi par
        // l'utilisateur (`selection.model`) doit toujours primer.
        return OpenAICompatibleProvider(
            account: preset.id,
            baseURL: preset.baseURL,
            model: selection.model,
            keyStore: keyStore
        )
    }
}
