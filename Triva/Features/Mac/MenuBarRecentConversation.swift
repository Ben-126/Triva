//
//  MenuBarRecentConversation.swift
//  Triva
//
//  Chantier 2.2 (M7) : lignes « récentes » du panneau de la barre des menus.
//

import Foundation

/// Une conversation récente telle que le panneau de la barre des menus l'affiche. Valeur pure (identifiant et
/// titre) : le panneau ne garde jamais les objets de la base.
nonisolated struct MenuBarRecentConversation: Identifiable, Equatable, Sendable {
    /// Nombre de conversations proposées.
    static let maxCount = 5
    /// Titre quand la conversation n'en a pas.
    static let untitled = "Conversation sans titre"

    let id: UUID
    let title: String

    init(id: UUID, title: String) {
        self.id = id
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = trimmed.isEmpty ? Self.untitled : trimmed
    }

    /// Les `maxCount` premières de la liste donnée (déjà triée de la plus récente à la plus ancienne).
    @MainActor
    static func recent(from conversations: [StoredConversation]) -> [MenuBarRecentConversation] {
        conversations.prefix(maxCount).map { MenuBarRecentConversation(id: $0.id, title: $0.title) }
    }
}
