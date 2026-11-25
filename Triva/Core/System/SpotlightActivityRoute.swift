//
//  SpotlightActivityRoute.swift
//  Triva
//
//  Chantier 2.1 (mission F) : toucher un résultat Spotlight peut arriver comme activité (`CSSearchableItemActionType`)
//  au lieu de lancer l'intent d'ouverture. Entrée EXTERNE : on ne sait que naviguer vers une conversation.
//

import Foundation

nonisolated enum SpotlightActivityRoute {
    /// L'identifiant de l'élément touché : un UUID de conversation, éventuellement précédé d'un type (`…/<UUID>` ou
    /// `…:<UUID>`). Tout le reste (adresse, texte libre, UUID incomplet) vaut `nil`.
    static func route(forIdentifier identifier: String?) -> SystemRoute? {
        guard let raw = identifier?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let id = UUID(uuidString: raw) { return .conversation(id) }
        guard let separator = raw.lastIndex(where: { $0 == "/" || $0 == ":" }) else { return nil }
        let tail = String(raw[raw.index(after: separator)...])
        return UUID(uuidString: tail).map(SystemRoute.conversation)
    }

    /// Depuis l'activité reçue (`userInfo[CSSearchableItemActivityIdentifier]`).
    static func route(forUserInfo userInfo: [AnyHashable: Any]?, identifierKey: String) -> SystemRoute? {
        route(forIdentifier: userInfo?[identifierKey] as? String)
    }
}
