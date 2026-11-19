//
//  ExternalQueryInbox.swift
//  Triva
//
//  Chantier 2.2 (M1) : boîte d'entrée des questions venues de l'extérieur.
//

import Foundation
import Observation

/// Remise d'une question reçue par un Service du Mac ou la barre des menus à la
/// fenêtre qui va l'afficher. Mémoire seulement : rien n'est écrit sur disque
/// (le texte vient de l'extérieur et peut être privé).
///
/// Déroulé : `deposit` renvoie l'identifiant de la future fenêtre ; l'app observe
/// `revision`, lit `lastDepositID` et ouvre `.newSearch(id)` ; la fenêtre neuve
/// appelle `take(for: id)` et place le texte dans son brouillon. Le texte doit
/// déjà être assaini (`ExternalQuerySanitizer`) par l'appelant.
@Observable
final class ExternalQueryInbox {
    /// Nombre de dépôts gardés au plus : si une fenêtre ne s'ouvre jamais, la
    /// boîte ne grossit pas, les plus anciens sont oubliés.
    static let defaultCapacity = 8

    /// Augmente à chaque dépôt (jamais à la lecture) : sert de déclencheur à `onChange`.
    private(set) var revision = 0
    /// Identifiant du dernier dépôt, à ouvrir en fenêtre.
    private(set) var lastDepositID: UUID?

    @ObservationIgnored private var entries: [(id: UUID, query: String)] = []
    @ObservationIgnored private let capacity: Int

    init(capacity: Int = ExternalQueryInbox.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    var pendingCount: Int { entries.count }

    @discardableResult
    func deposit(_ query: String) -> UUID {
        let id = UUID()
        entries.append((id, query))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        lastDepositID = id
        revision += 1
        return id
    }

    /// Rend le texte déposé pour cet identifiant, UNE seule fois.
    func take(for id: UUID) -> String? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return entries.remove(at: index).query
    }

    func discardAll() {
        entries.removeAll()
    }
}
