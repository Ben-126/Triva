//
//  SpotlightIndexPlan.swift
//  Triva
//
//  Chantier 2.1 (mission F) : ce que l'app doit indexer ou retirer de la recherche de l'appareil (Spotlight), calculé
//  sans toucher au système : les différences entre l'historique actuel et ce qui a déjà été indexé.
//  Le titre et la date seulement : jamais le texte des réponses.
//

import Foundation

/// Une conversation telle qu'elle est donnée à Spotlight : identifiant, titre prêt à afficher, date.
nonisolated struct SpotlightEntry: Hashable, Sendable {
    let id: UUID
    let title: String
    let updatedAt: Date

    /// Titre nettoyé comme celui du widget (une seule ligne, coupé, repli « Conversation sans titre ») ; date arrondie
    /// à la seconde pour que deux lectures de la même conversation soient égales.
    init(id: UUID, title: String, updatedAt: Date) {
        self.id = id
        self.title = WidgetSnapshot.displayTitle(title)
        self.updatedAt = Date(timeIntervalSince1970: updatedAt.timeIntervalSince1970.rounded(.down))
    }
}

nonisolated enum SpotlightIndexPlan {
    /// Les conversations les plus récentes seulement : au-delà, Spotlight n'apporte plus rien.
    static let maxEntries = 500

    struct Plan: Equatable, Sendable {
        /// À indexer (nouvelles ou changées), dans l'ordre reçu.
        var toIndex: [SpotlightEntry]
        /// À retirer, par identifiant (ordre stable).
        var toDelete: [UUID]

        var isEmpty: Bool { toIndex.isEmpty && toDelete.isEmpty }
    }

    /// - Parameters:
    ///   - desired: l'historique, les plus récentes d'abord.
    ///   - previous: ce qui a été indexé pendant CE lancement ; `nil` au premier passage (on indexe tout : un
    ///     titre a pu changer pendant que l'app était fermée).
    ///   - indexedIDs: les identifiants indexés, gardés sur disque : ce qui a disparu de l'historique est retiré,
    ///     même d'un lancement précédent.
    static func make(desired: [SpotlightEntry], previous: [UUID: SpotlightEntry]?, indexedIDs: Set<UUID>) -> Plan {
        let wanted = capped(desired)
        let toIndex = wanted.filter { previous?[$0.id] != $0 }
        let keptIDs = Set(wanted.map(\.id))
        let toDelete = indexedIDs.subtracting(keptIDs).sorted { $0.uuidString < $1.uuidString }
        return Plan(toIndex: toIndex, toDelete: toDelete)
    }

    /// Les `maxEntries` premières conversations (les plus récentes), un identifiant en double une seule fois (la
    /// première gagne).
    static func capped(_ entries: [SpotlightEntry]) -> [SpotlightEntry] {
        var seen = Set<UUID>()
        var result: [SpotlightEntry] = []
        for entry in entries where seen.insert(entry.id).inserted {
            result.append(entry)
            if result.count == maxEntries { break }
        }
        return result
    }
}
