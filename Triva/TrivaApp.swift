//
//  TrivaApp.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import SwiftUI

@main
struct TrivaApp: App {
    /// Stores de sélection créés une seule fois pour toute la durée de vie de
    /// l'app et partagés par toutes les fenêtres (`WindowGroup` instancie un
    /// `ContentView` distinct par fenêtre sur macOS) — sans ce partage,
    /// changer de modèle MLX ou supprimer un fournisseur BYOK actif dans une
    /// fenêtre ne serait jamais vu par les autres fenêtres déjà ouvertes.
    @State private var mlxSelectionStore = MLXModelSelectionStore()
    @State private var cloudSelectionStore: CloudProviderSelectionStore
    @State private var customProviderStore: CustomProviderStore

    init() {
        // `CustomProviderStore` doit recevoir la MÊME instance de
        // `CloudProviderSelectionStore` que celle partagée ci-dessous (et non
        // son propre `CloudProviderSelectionStore()` par défaut) : c'est ce
        // qui permet à `remove(id:)` d'effacer la sélection active vue par
        // toutes les fenêtres, pas seulement la sienne.
        let cloudSelectionStore = CloudProviderSelectionStore()
        _cloudSelectionStore = State(initialValue: cloudSelectionStore)
        _customProviderStore = State(initialValue: CustomProviderStore(selectionStore: cloudSelectionStore))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                mlxSelectionStore: mlxSelectionStore,
                cloudSelectionStore: cloudSelectionStore,
                customProviderStore: customProviderStore
            )
        }
    }
}
