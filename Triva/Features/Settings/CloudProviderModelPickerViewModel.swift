//
//  CloudProviderModelPickerViewModel.swift
//  Triva
//
//  Created by ben podrojsky on 06/09/2026.
//

import Foundation
import ClaudeForFoundationModels

/// Un fournisseur BYOK pour lequel une clé API est déjà enregistrée en
/// Keychain — la seule forme éligible à apparaître dans
/// `CloudProviderModelPickerView` (voir `CloudProviderModelPickerViewModel`).
struct ConfiguredCloudProvider: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
}

/// Logique de `CloudProviderModelPickerView` (0.6 élargi — sélection de
/// fournisseur/modèle), isolée de `KeychainAPIKeyStore` via `APIKeyStoring`
/// pour rester testable sans vrai Keychain. Ne construit aucun
/// `AIGenerating` — ça reste le rôle de `CloudProviderSelectionResolver`,
/// utilisé plus tard par le pipeline (0.7, hors scope ici).
@Observable
final class CloudProviderModelPickerViewModel {
    private let keyStore: any APIKeyStoring
    private let customPresets: [CloudProviderPreset]
    private let selectionStore: CloudProviderSelectionStore

    /// Calculée une seule fois à l'initialisation : la liste des clés
    /// enregistrées ne change pas pendant la durée de vie de cet écran (les
    /// clés se gèrent depuis `BYOKProvidersView`, un écran distinct).
    let configuredProviders: [ConfiguredCloudProvider]

    var selectedProviderID: String? {
        selectionStore.selection?.providerID
    }

    var selectedModel: String? {
        selectionStore.selection?.model
    }

    /// `selectedProviderID`, mais seulement s'il correspond encore à un
    /// fournisseur de `configuredProviders` — sinon la sélection est orpheline
    /// (clé supprimée ou preset personnalisé supprimé depuis `BYOKProvidersView`
    /// sans passer par cet écran) et ne doit pas piloter l'affichage de la
    /// section MODÈLE. `nil` dans ce cas.
    var selectedConfiguredProviderID: String? {
        guard let id = selectionStore.selection?.providerID,
              configuredProviders.contains(where: { $0.id == id }) else {
            return nil
        }
        return id
    }

    init(
        keyStore: any APIKeyStoring = KeychainAPIKeyStore(),
        customPresets: [CloudProviderPreset] = [],
        selectionStore: CloudProviderSelectionStore = CloudProviderSelectionStore()
    ) {
        self.keyStore = keyStore
        self.customPresets = customPresets
        self.selectionStore = selectionStore

        var providers: [ConfiguredCloudProvider] = []
        if Self.hasStoredKey(keyStore: keyStore, account: CloudProviderSelectionResolver.claudeProviderID) {
            providers.append(
                ConfiguredCloudProvider(id: CloudProviderSelectionResolver.claudeProviderID, displayName: "Claude")
            )
        }
        for preset in CloudProviderCatalog.presets where Self.hasStoredKey(keyStore: keyStore, account: preset.id) {
            providers.append(ConfiguredCloudProvider(id: preset.id, displayName: preset.displayName))
        }
        for preset in customPresets where Self.hasStoredKey(keyStore: keyStore, account: preset.id) {
            providers.append(ConfiguredCloudProvider(id: preset.id, displayName: preset.displayName))
        }
        configuredProviders = providers
    }

    /// Sélectionne `id` comme fournisseur actif. Si c'était déjà le
    /// fournisseur sélectionné, son modèle actuel est conservé ; sinon un
    /// modèle par défaut sensé est choisi (`.sonnet5` pour Claude,
    /// `defaultModel` du preset pour les autres). Ne fait rien si `id` ne
    /// correspond à aucun fournisseur connu.
    func selectProvider(id: String) {
        if selectionStore.selection?.providerID == id, let currentModel = selectionStore.selection?.model {
            selectionStore.selection = CloudProviderSelection(providerID: id, model: currentModel)
            return
        }

        if id == CloudProviderSelectionResolver.claudeProviderID {
            selectionStore.selection = CloudProviderSelection(providerID: id, model: ClaudeModel.sonnet5.id)
            return
        }

        guard let preset = allPresets.first(where: { $0.id == id }) else { return }
        selectionStore.selection = CloudProviderSelection(providerID: id, model: preset.defaultModel)
    }

    /// Met à jour le modèle du fournisseur actuellement sélectionné. Ne fait
    /// rien si aucun fournisseur n'est sélectionné.
    func updateModel(to model: String) {
        guard let providerID = selectionStore.selection?.providerID else { return }
        selectionStore.selection = CloudProviderSelection(providerID: providerID, model: model)
    }

    private var allPresets: [CloudProviderPreset] {
        CloudProviderCatalog.presets + customPresets
    }

    private static func hasStoredKey(keyStore: any APIKeyStoring, account: String) -> Bool {
        ((try? keyStore.apiKey(account: account)) ?? nil)?.isEmpty == false
    }

    /// Nom lisible d'un modèle Claude dérivé de son id (ex.
    /// "claude-sonnet-5" → "Sonnet 5", "claude-opus-4-8" → "Opus 4.8") — pas
    /// de table de correspondance à maintenir séparément.
    static func claudeModelDisplayName(for model: ClaudeModel) -> String {
        var id = model.id
        if id.hasPrefix("claude-") {
            id.removeFirst("claude-".count)
        }
        let parts = id.split(separator: "-")
        guard let first = parts.first else { return id }

        let name = first.prefix(1).uppercased() + first.dropFirst()
        let versionParts = parts.dropFirst()
        guard !versionParts.isEmpty else { return name }
        return "\(name) \(versionParts.joined(separator: "."))"
    }
}
