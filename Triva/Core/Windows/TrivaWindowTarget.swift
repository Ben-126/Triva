//
//  TrivaWindowTarget.swift
//  Triva
//
//  Chantier 2.2 (M1) : valeur de scène de « une recherche = une fenêtre » (Mac, iPad).
//

import Foundation

/// Ce que montre une fenêtre de recherche : une recherche neuve ou une
/// conversation enregistrée. Valeur de `WindowGroup(for:)` : SwiftUI l'écrit
/// sur disque pour restaurer les fenêtres au relancement.
///
/// CONFIDENTIALITÉ : jamais de texte de question ici, uniquement des
/// identifiants. Le texte d'une conversation vit dans `ChatHistoryStore`.
///
/// L'UUID de `.newSearch` est OBLIGATOIRE : `openWindow(value:)` ramène au
/// premier plan la fenêtre qui présente déjà une valeur ÉGALE ; sans UUID,
/// un deuxième « Nouvelle recherche » n'ouvrirait jamais de fenêtre.
nonisolated enum TrivaWindowTarget: Codable, Hashable, Sendable {
    case newSearch(UUID)
    case conversation(UUID)

    /// Recherche vide, toujours distincte de toutes les autres. Valeur par
    /// défaut de la scène et cible de « Nouvelle recherche ».
    static func freshSearch() -> TrivaWindowTarget {
        .newSearch(UUID())
    }

    /// Identifiant de la conversation affichée, `nil` pour une recherche neuve.
    var conversationID: UUID? {
        switch self {
        case .newSearch: return nil
        case .conversation(let id): return id
        }
    }

    /// Cible à utiliser au relancement : une conversation supprimée entre-temps
    /// (ou perdue) redevient une recherche neuve, avec un identifiant neuf.
    /// `makeID` est injectable pour les tests.
    static func restored(
        _ target: TrivaWindowTarget,
        existingIDs: Set<UUID>,
        makeID: () -> UUID = UUID.init
    ) -> TrivaWindowTarget {
        switch target {
        case .newSearch:
            return target
        case .conversation(let id):
            return existingIDs.contains(id) ? target : .newSearch(makeID())
        }
    }
}
