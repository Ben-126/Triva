//
//  QuickSearchContent.swift
//  TrivaShared
//
//  Chantier 2.1 (mission C) : ce que le widget « Recherche rapide » doit montrer, et où mène chaque toucher.
//  Logique pure, compilée dans l'app (où elle est testée) et dans l'extension (où elle sert).
//

import Foundation

nonisolated enum QuickSearchContent: Equatable, Sendable {
    /// Aucun fichier dans l'App Group : réglage « Dernière question dans le widget » éteint (défaut), ou rien
    /// encore d'écrit. Le widget ne dit RIEN de l'historique (il ne sait pas s'il est vide) : seulement le geste.
    case neutral
    /// Réglage allumé, historique vide.
    case noHistory
    /// Réglage allumé, avec une dernière conversation.
    case conversation(id: UUID, title: String)

    init(snapshot: WidgetSnapshot?) {
        guard let snapshot else {
            self = .neutral
            return
        }
        guard let conversation = snapshot.conversation else {
            self = .noHistory
            return
        }
        self = .conversation(id: conversation.id, title: conversation.title)
    }

    /// Titre de la dernière conversation, s'il y en a une.
    var lastTitle: String? {
        guard case .conversation(_, let title) = self else { return nil }
        return title
    }

    /// `triva://new` : recherche vide, clavier ouvert.
    var newQuestionURL: URL? {
        TrivaURLRoute.url(for: .newQuestion(.keyboard))
    }

    /// `triva://conversation/<id>` : reprendre la dernière conversation. Seulement s'il y en a une.
    var resumeURL: URL? {
        guard case .conversation(let id, _) = self else { return nil }
        return TrivaURLRoute.url(for: .conversation(id))
    }
}
