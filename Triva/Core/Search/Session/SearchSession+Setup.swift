//
//  SearchSession+Setup.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import Foundation

/// Lecture de l'état de la session (modèle MLX validé, ce qui manque au moteur, attente du modèle local) et
/// choix du modèle MLX. Rangé à part de `SearchSession.swift` (rangement W4-R, code déplacé à l'identique).
extension SearchSession {
    /// Cette fenêtre attend qu'une autre ait fini avec le modèle local (mission M3).
    var isWaitingForLocalModel: Bool {
        guard engine == .mlxLocal else { return false }
        if stores.mlxProviderPool.isWaitingForAnotherWindow(mlxRequesterID) { return true }
        // Une réponse laissée en arrière-plan (« Nouvelle conversation ») écrit encore : le modèle ne sert qu'une
        // réponse à la fois, la question suivante attend la fin de la précédente (même ligne d'attente).
        let hasBackgroundAnswer = chatViewModel?.backgroundExchanges.isEmpty == false
        return hasBackgroundAnswer && stores.mlxProviderPool.isWaitingBehindOwnWork(mlxRequesterID)
    }

    /// Modèle MLX validé (0.5) pour la sélection courante, `nil` tant qu'aucun
    /// n'a été choisi — le chat MLX est inutilisable dans ce cas.
    ///
    /// DÉRIVÉ du store partagé à chaque lecture, et non plus copié dans la
    /// session : un modèle choisi dans une autre fenêtre (ou effacé par les
    /// Réglages, voir `MLXStorageView`) s'affiche donc ici aussitôt — la carte
    /// « Modèle actif » montre toujours le modèle que le prochain envoi
    /// utilisera, même logique que le badge.
    var validatedMLXModel: MLXModelCatalogEntry? {
        guard let id = stores.mlxSelection.selectedModelID else { return nil }
        return mlxCatalog?.first { $0.id == id }
    }
    /// Ce qui manque encore au moteur de la session pour répondre, `nil` si
    /// la Recherche est prête. Dérivé à chaque lecture des stores partagés :
    /// une clé configurée dans les Réglages (de cette fenêtre ou d'une autre)
    /// fait apparaître le chat dès le retour sur la Recherche.
    ///
    /// Cloud : seule la SÉLECTION est vérifiée, jamais la clé — la lire
    /// demanderait un accès au trousseau à chaque rendu. Une sélection sans
    /// clé reste possible (clé supprimée hors de l'app) ; l'envoi le dit
    /// alors avec un message actionnable.
    var setupRequirement: SearchSetupRequirement? {
        switch engine {
        case .appleIntelligence:
            guard let appleIntelligenceError else { return nil }
            return .appleIntelligenceUnavailable(appleIntelligenceError)
        case .mlxLocal:
            return validatedMLXModel == nil ? .mlxModel : nil
        case .cloudBYOK:
            return stores.cloudSelection.selection == nil ? .cloudProvider : nil
        }
    }
    /// Enregistre le modèle MLX que l'utilisateur vient de valider, dans le
    /// store PARTAGÉ (toutes les fenêtres le voient). Le pool MLX suit ce store
    /// et décharge l'ancien modèle aussitôt (à son tour dans la file) : c'est
    /// de la mémoire (plusieurs Go) rendue sans attendre le prochain envoi.
    func selectMLXModel(_ chosen: MLXModelCatalogEntry) {
        stores.mlxSelection.selectedModelID = chosen.id
        preparedMLXProvider = nil
        loadMLXCatalogIfNeeded()
    }
}
