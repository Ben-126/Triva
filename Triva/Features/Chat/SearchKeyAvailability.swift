//
//  SearchKeyAvailability.swift
//  Triva
//
//  Created by ben podrojsky on 12/11/2026.
//

import Foundation
import Observation

/// « L'utilisateur a-t-il une clé de recherche (Brave / Tavily) ? », sous forme observable pour
/// l'écran vide du chat (`ChatEmptyStateView`, exemples qui dépendent de la réponse).
///
/// Le trousseau est lu UNE fois, à la première demande, puis la valeur est gardée. Elle est
/// invalidée quand `SearchKeyStore` poste `didChangeNotification` (clé ajoutée ou retirée, dans
/// cette fenêtre ou une autre) : la lecture suivante relit le trousseau. L'init ne lit rien :
/// SwiftUI recrée la valeur par défaut à chaque rendu du parent, seule la première est gardée.
@Observable
final class SearchKeyAvailability {
    @ObservationIgnored private let store: SearchKeyStore
    @ObservationIgnored private var cached: Bool?
    /// Observé : sa seule raison d'être est de faire relire `hasKey` à la vue après `invalidate()`.
    private var revision = 0

    init(store: SearchKeyStore = SearchKeyStore()) {
        self.store = store
    }

    var hasKey: Bool {
        _ = revision
        if let cached { return cached }
        let value = store.hasConfiguredKey
        cached = value
        return value
    }

    func invalidate() {
        cached = nil
        revision += 1
    }
}
