//
//  TrivaRootCoordinator+ExternalQuery.swift
//  Triva
//
//  Chantier 2.2 (M7) : une fenêtre ouverte par le Service « Rechercher avec Triva » ou la barre des menus
//  reprend la question qui l'attend.
//

import Foundation

extension TrivaRootCoordinator {
    /// Si la cible de la fenêtre est une recherche neuve dont la question attend dans la boîte d'entrée, la place
    /// dans le brouillon et affiche la Recherche. La question n'est PAS envoyée : elle quitterait l'appareil sans
    /// que l'utilisateur ait relu ce qu'il avait sélectionné.
    ///
    /// La boîte rend le texte une seule fois : une fenêtre restaurée au relancement (identifiant ancien) ou
    /// une seconde fenêtre sur la même cible n'obtient rien.
    ///
    /// - Returns: `true` si un brouillon a été posé (pour les tests).
    @discardableResult
    func receiveExternalQuery(from inbox: ExternalQueryInbox?) -> Bool {
        guard let inbox,
              case .newSearch(let id) = windowTarget,
              let question = inbox.take(for: id) else { return false }
        session.draft.text = question
        selection = .search
        return true
    }
}
