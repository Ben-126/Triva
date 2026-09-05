//
//  CustomProviderStore.swift
//  Triva
//
//  Created by ben podrojsky on 05/09/2026.
//

import Foundation

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

    private(set) var customPresets: [CloudProviderPreset] = []

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
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

    func remove(id: String) {
        customPresets.removeAll { $0.id == id }
        persist()
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
