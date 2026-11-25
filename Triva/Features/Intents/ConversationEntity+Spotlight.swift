//
//  ConversationEntity+Spotlight.swift
//  Triva
//
//  Chantier 2.1 (mission F) : une conversation dans la recherche de l'appareil. Le TITRE et la DATE seulement :
//  jamais le texte des questions ni des réponses. Toucher un résultat lance `OpenConversationIntent` (iOS et Mac).
//

import AppIntents
import CoreSpotlight
import Foundation

nonisolated extension ConversationEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = title
        attributes.displayName = title
        attributes.contentModificationDate = updatedAt
        // Aucun contenu de conversation : seulement ce qui sert à la retrouver.
        attributes.textContent = nil
        return attributes
    }
}

/// Le système peut demander de reconstruire l'index (index invalidé, changement de schéma) : l'app le refait depuis
/// l'historique, si le réglage est allumé.
extension ConversationQuery: IndexedEntityQuery {
    func reindexEntities(for identifiers: [UUID], indexDescription: CSSearchableIndexDescription) async throws {
        await MainActor.run { SystemIntegrations.shared.reindexSpotlight() }
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await MainActor.run { SystemIntegrations.shared.reindexSpotlight() }
    }
}
