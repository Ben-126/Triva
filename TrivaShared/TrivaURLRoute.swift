//
//  TrivaURLRoute.swift
//  TrivaShared
//
//  Chantier 2.1 (mission A) : schéma d'URL `triva://`, utilisé par les touchers du widget et de l'activité en
//  direct. C'est une entrée EXTERNE : n'importe quelle app peut ouvrir une URL `triva://`. Elle ne fait que
//  naviguer, n'envoie jamais rien, ne porte jamais de texte libre, et refuse tout ce qu'elle ne connaît pas.
//
//  Formes acceptées, et elles seules :
//    triva://new
//    triva://conversation/<UUID>
//  Schéma et hôte ne distinguent pas majuscules et minuscules (RFC 3986), l'UUID non plus.
//

import Foundation

nonisolated enum TrivaURLRoute {
    static let scheme = "triva"
    /// Plus long que la plus longue forme valide (`triva://conversation/` + 36 caractères) avec une marge : au-delà,
    /// ce n'est pas une de nos URL.
    static let maxLength = 80

    private static let prefix = "\(scheme)://"
    private static let newHost = "new"
    private static let conversationHost = "conversation"
    private static let uuidLength = 36

    /// La route demandée par cette URL, ou `nil` si ce n'en est pas une des nôtres.
    ///
    /// Analyse du texte de l'URL plutôt que de ses composants : on refuse tout caractère qui ouvrirait une autre
    /// forme (`?`, `#`, `@`, `:`, `%`, `\`) AVANT de lire quoi que ce soit, donc aucune requête, aucun fragment,
    /// aucun identifiant, aucun port et aucun encodage ne peut passer.
    static func parse(_ url: URL) -> SystemRoute? {
        let text = url.absoluteString
        guard text.count <= maxLength, text.lowercased().hasPrefix(prefix) else { return nil }
        let rest = String(text.dropFirst(prefix.count))
        guard !rest.contains(where: { forbiddenCharacters.contains($0) }) else { return nil }

        let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1 where parts[0].lowercased() == newHost:
            return .newQuestion(.keyboard)
        case 2 where parts[0].lowercased() == conversationHost:
            guard parts[1].count == uuidLength, let id = UUID(uuidString: parts[1]) else { return nil }
            return .conversation(id)
        default:
            return nil
        }
    }

    /// L'URL qui provoque cette route (widget, activité en direct), ou `nil` quand la route ne s'exprime pas en
    /// URL : un brouillon (un texte libre ne voyage jamais dans une URL), un fichier partagé et la saisie vocale (chantier 2.7).
    static func url(for route: SystemRoute) -> URL? {
        switch route {
        case .newQuestion(.keyboard):
            URL(string: "\(prefix)\(newHost)")
        case .conversation(let id):
            URL(string: "\(prefix)\(conversationHost)/\(id.uuidString)")
        case .newQuestion(.voice), .draft, .attachment, .notice:
            nil
        }
    }

    private static let forbiddenCharacters: Set<Character> = ["?", "#", "@", ":", "%", "\\", " "]
}
