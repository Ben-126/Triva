//
//  MLXModelSelectionStore.swift
//  Triva
//
//  Created by ben podrojsky on 06/09/2026.
//

import Foundation

/// Persiste l'id du modèle MLX validé par l'utilisateur (0.5), pour que l'app
/// retrouve le même modèle actif d'un lancement à l'autre au lieu de
/// redemander le choix à chaque fois — même principe que
/// `AIEngineSettingsStore` (0.3) : métadonnée non sensible uniquement (l'id
/// du modèle, jamais son contenu téléchargé), un seul champ, persistance
/// directe via `didSet`.
@Observable
final class MLXModelSelectionStore {
    private static let storageKey = "mlx.selectedModelID"
    private let userDefaults: UserDefaults

    var selectedModelID: String? {
        didSet { persist() }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        // Une seule affectation à `selectedModelID` (pas nil puis rechargé) :
        // sinon le `didSet` du nil initial persisterait avant même d'avoir lu
        // la donnée existante et l'effacerait du UserDefaults.
        self.selectedModelID = userDefaults.string(forKey: Self.storageKey)
    }

    private func persist() {
        guard let selectedModelID else {
            userDefaults.removeObject(forKey: Self.storageKey)
            return
        }
        userDefaults.set(selectedModelID, forKey: Self.storageKey)
    }
}

/// Résout l'id de modèle persisté vers un `MLXProvider` prêt à préparer
/// (`prepare()` reste à appeler avant `generate(prompt:)`, comme pour tout
/// `MLXProvider` — voir son commentaire de tête). Logique pure, isolée du
/// chargement du catalogue depuis le bundle via `catalog` injecté, pour
/// rester testable sans dépendre du système de fichiers.
enum MLXModelSelectionResolver {
    /// `nil` si `modelID` ne correspond à aucune entrée de `catalog`.
    static func makeProvider(modelID: String, catalog: [MLXModelCatalogEntry]) -> MLXProvider? {
        guard let entry = catalog.first(where: { $0.id == modelID }) else { return nil }
        return MLXProvider(entry: entry)
    }
}
