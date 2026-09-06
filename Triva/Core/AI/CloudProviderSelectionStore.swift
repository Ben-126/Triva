//
//  CloudProviderSelectionStore.swift
//  Triva
//
//  Created by ben podrojsky on 05/09/2026.
//

import Foundation

/// Persiste le fournisseur/modèle cloud BYOK actuellement choisi par
/// l'utilisateur (0.6 élargi — sélection de fournisseur/modèle), pour que
/// `CloudProviderModelPickerView` et le futur pipeline (0.7) puissent
/// résoudre le bon `AIGenerating` sans re-demander le choix à chaque lancement.
/// Ne stocke que `providerID` + nom de modèle, jamais de clé API — même
/// principe que `CustomProviderStore` (métadonnées uniquement, la clé reste
/// exclusivement dans le Keychain).
@Observable
final class CloudProviderSelectionStore {
    private static let storageKey = "byok.activeSelection"
    private let userDefaults: UserDefaults

    /// Settable directement (comme `AIEngineSettingsStore.selectedOption`) —
    /// contrairement à `CustomProviderStore.customPresets`, il n'y a ici qu'une
    /// seule valeur remplacée en bloc, pas une collection à faire évoluer par
    /// petites opérations (`add`/`remove`), donc pas besoin de méthodes dédiées.
    var selection: CloudProviderSelection? {
        didSet { persist() }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        // Une seule affectation à `selection` (pas nil puis rechargée) : sinon
        // le `didSet` du nil initial persisterait avant même d'avoir lu la
        // donnée existante et l'effacerait du UserDefaults.
        self.selection = Self.load(from: userDefaults)
    }

    private static func load(from userDefaults: UserDefaults) -> CloudProviderSelection? {
        guard let data = userDefaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(CloudProviderSelection.self, from: data)
    }

    private func persist() {
        guard let selection else {
            userDefaults.removeObject(forKey: Self.storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(selection) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }
}
