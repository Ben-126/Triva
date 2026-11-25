//
//  TrivaShortcuts.swift
//  Triva
//
//  Chantier 2.1 (mission A) : raccourcis proposés sans configuration (Raccourcis, Siri, Spotlight). Les phrases
//  sont à valider par Ben. Une phrase ne peut pas contenir de texte libre : seulement le nom de l'app.
//

import AppIntents

nonisolated struct TrivaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskTrivaIntent(),
            phrases: [
                "Demande à \(.applicationName)",
                "Pose une question à \(.applicationName)",
            ],
            shortTitle: "Poser une question",
            systemImageName: "questionmark.bubble"
        )
        AppShortcut(
            intent: OpenComposerIntent(target: .keyboard),
            phrases: [
                "Nouvelle recherche dans \(.applicationName)",
            ],
            shortTitle: "Nouvelle recherche",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: SearchHistoryIntent(),
            phrases: [
                "Cherche dans l'historique de \(.applicationName)",
            ],
            shortTitle: "Chercher dans l'historique",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: OpenConversationIntent(),
            phrases: [
                "Ouvre une conversation \(.applicationName)",
            ],
            shortTitle: "Ouvrir une conversation",
            systemImageName: "clock"
        )
    }
}
