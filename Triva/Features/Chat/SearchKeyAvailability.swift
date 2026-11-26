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
/// cette fenêtre ou une autre) : la lecture suivante relit le trousseau. Une lecture EN ÉCHEC (trousseau fermé) n'est pas gardée. L'init ne lit rien :
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
        do {
            let value = try !store.configuredSources().isEmpty
            cached = value
            return value
        } catch {
            // Trousseau illisible (appareil verrouillé…) : « pas de clé » pour cet affichage, mais SANS le garder, sinon
            // les exemples « sans clé » resteraient après le déverrouillage (mission F2). Prudent, comme `hasConfiguredKey`.
            return false
        }
    }

    func invalidate() {
        cached = nil
        revision += 1
    }
}
