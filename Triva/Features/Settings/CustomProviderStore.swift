//
//  CustomProviderStore.swift
//  Triva
//
//  Created by ben podrojsky on 05/09/2026.
//

import Foundation

/// Échec de suppression d'un fournisseur personnalisé : sa clé n'a pas pu être
/// retirée du Trousseau. Le fournisseur est alors CONSERVÉ : le retirer quand
/// même laisserait une clé orpheline dans le Trousseau, sans plus aucun moyen
/// de l'atteindre depuis l'app.
nonisolated enum CustomProviderStoreError: Error, Sendable, Equatable {
    case keyNotDeleted

    /// Message court pour l'écran. **À VALIDER PAR BEN.**
    var userFacingMessage: String {
        switch self {
        case .keyNotDeleted:
            "La clé n'a pas pu être supprimée du Trousseau, le fournisseur est conservé. Réessaie."
        }
    }
}

/// Persiste les fournisseurs BYOK "personnalisés" créés par l'utilisateur
/// (0.6 élargi, en complément du catalogue générique `CloudProviderCatalog`)
/// — uniquement les métadonnées non sensibles (nom, URL de base, modèle). La
/// clé API elle-même reste exclusivement dans le Keychain (`KeychainAPIKeyStore`,
/// account = `id` du preset), jamais ici, conformément à la règle BYOK du
/// projet. Même pattern de persistance que `AIEngineSettingsStore` (0.3).
@Observable
final class CustomProviderStore {
    private static let storageKey = "byok.customProviders"
    private let userDefaults: UserDefaults
    private let selectionStore: CloudProviderSelectionStore
    private let keyStore: any APIKeyStoring

    private(set) var customPresets: [CloudProviderPreset] = []

    init(
        userDefaults: UserDefaults = .standard,
        selectionStore: CloudProviderSelectionStore = CloudProviderSelectionStore(),
        keyStore: any APIKeyStoring = KeychainAPIKeyStore()
    ) {
        self.userDefaults = userDefaults
        self.selectionStore = selectionStore
        self.keyStore = keyStore
        load()
    }

    @discardableResult
    func add(displayName: String, baseURL: URL, model: String) -> CloudProviderPreset {
        let preset = CloudProviderPreset(
            id: "custom:\(UUID().uuidString)",
            displayName: displayName,
            baseURL: baseURL,
            defaultModel: model
        )
        customPresets.append(preset)
        persist()
        return preset
    }

    /// Supprime le fournisseur personnalisé `id`. S'il était le fournisseur
    /// BYOK actuellement sélectionné (`CloudProviderSelectionStore`), la
    /// sélection est aussi effacée — sinon elle resterait orpheline
    /// indéfiniment, sans preset pour la résoudre. La clé API associée
    /// (compte Keychain = `id`, voir `OpenAICompatibleProvider.init(preset:)`)
    /// est aussi supprimée, sinon elle resterait dans le Keychain sans plus
    /// aucun moyen de l'atteindre depuis l'app.
    ///
    /// La clé part EN PREMIER : si le Trousseau refuse, rien d'autre ne change
    /// (fournisseur et sélection conservés) et `CustomProviderStoreError` remonte
    /// jusqu'à l'écran, qui peut proposer de réessayer.
    func remove(id: String) throws {
        do {
            try keyStore.deleteAPIKey(account: id)
        } catch {
            throw CustomProviderStoreError.keyNotDeleted
        }
        customPresets.removeAll { $0.id == id }
        persist()

        if selectionStore.selection?.providerID == id {
            selectionStore.selection = nil
        }
    }

    private func load() {
        guard let data = userDefaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([CloudProviderPreset].self, from: data) else {
            return
        }
        customPresets = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(customPresets) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }
}
