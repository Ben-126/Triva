//
//  SharedInboxHandoff.swift
//  Triva
//
//  Chantier 2.1 (mission E) : la reprise de la boîte de partage par l'app. Le plus récent est repris ; ce qu'il
//  contient passe dans l'app (le fichier dans les dépôts de l'app, là où le glisser-déposer met les siens) ; la copie
//  de l'App Group est effacée DÈS la reprise, ainsi que toutes les autres entrées. Rien n'est envoyé : ce qui sort
//  d'ici est un texte pour la barre de saisie et un fichier à joindre.
//

import Foundation

/// Ce que l'app reprend d'un partage.
nonisolated struct SharedHandoff: Sendable, Equatable {
    /// Question à placer dans la barre de saisie (déjà assainie), ou `nil`.
    let text: String?
    /// Fichier à joindre, déjà dans les dépôts de l'app (`<racine>/_deposits/<id>/<nom>`), ou `nil`.
    let depositURL: URL?
}

nonisolated enum SharedInboxHandoff {
    /// Reprend l'entrée la plus récente de la boîte, efface toutes les autres. `nil` s'il n'y a rien (ou rien d'exploitable).
    ///
    /// `@concurrent` : la copie d'un PDF de 200 Mo ne doit pas se faire sur le thread principal.
    @concurrent
    static func takeLatest(from inbox: SharedInbox, depositRoot: URL) async -> SharedHandoff? {
        let entries = inbox.validEntries()
        guard let latest = entries.first else { return nil }
        defer { entries.forEach(inbox.remove) }

        var depositURL: URL?
        if let file = latest.file {
            // Copie (jamais déplacement) : l'App Group et le dossier temporaire de l'app sont deux conteneurs.
            depositURL = try? AttachmentFileVault.stageDeposit(
                of: inbox.payloadURL(of: latest),
                named: file.displayName,
                rootDirectory: depositRoot
            )
        }
        guard latest.text != nil || depositURL != nil else { return nil }
        return SharedHandoff(text: latest.text, depositURL: depositURL)
    }
}
