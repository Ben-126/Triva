//
//  SearchSession+Offline.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation

/// Mode hors connexion de la session de recherche (tâche 1.16).
extension SearchSession {
    /// Ce que l'envoi doit faire quand l'appareil est hors connexion, `nil` quand il est connecté (ou
    /// que le système ne sait pas encore : `.unknown` n'est jamais traité comme « hors connexion »,
    /// voir `ConnectivityStatus`). Appelée à chaque envoi et à chaque rendu de l'écran de recherche :
    /// elle lit l'état observable du moniteur, la vue suit donc le réseau.
    ///
    /// Le moteur est celui de la session (figé, bug 10) ; pour MLX, `localModelAvailable` dit si
    /// `prepare()` peut charger sans réseau :
    /// - aucun modèle choisi : vrai. L'erreur d'origine (« Aucun modèle local choisi », actionnable) est
    ///   plus juste qu'un message sur la connexion ;
    /// - modèle déjà en mémoire (provider préparé pour CE modèle) : vrai, sans toucher au disque ;
    /// - sinon : poids entièrement présents sur le disque (`MLXProvider.hasDownloadedWeights`).
    func resolveOfflinePlan() -> OfflinePlan? {
        guard connectivity.isOffline else { return nil }
        return OfflinePlan.resolve(engine: engine, localModelAvailable: isMLXModelAvailableOffline())
    }

    private func isMLXModelAvailableOffline() -> Bool {
        guard let modelID = stores.mlxSelection.selectedModelID else { return true }
        if preparedMLXProvider?.modelID == modelID { return true }
        return hasMLXWeights(modelID)
    }
}
