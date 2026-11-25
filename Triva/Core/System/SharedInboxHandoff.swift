//
//  SharedInboxHandoff.swift
//  Triva
//
//  Chantier 2.1 (mission E) : la reprise de la boîte de partage par l'app. Le plus récent est repris ; ce qu'il
//  contient passe dans l'app (le fichier dans les dépôts de l'app, là où le glisser-déposer met les siens). Rien
//  n'est envoyé : ce qui sort d'ici est un texte pour la barre de saisie et un fichier à joindre.
//
//  Mission X1 : l'entrée la plus récente n'est effacée de l'App Group QUE quand l'app a vraiment repris son contenu
//  (`commit`, appelé quand une fenêtre a pris la route). Une copie qui échoue (disque plein, fichier protégé) la
//  laisse en place (elle expire seule au bout de 24 h) et le dit ; une app tuée avant l'application ne perd rien.
//  Les entrées plus anciennes, remplacées par la plus récente, partent dès que la copie a réussi.
//

import Foundation

/// Ce que l'app reprend d'un partage.
nonisolated struct SharedHandoff: Sendable, Equatable {
    /// L'entrée de la boîte dont ceci est issu (`SharedInboxHandoff.commit` l'efface).
    let entryID: UUID
    /// Question à placer dans la barre de saisie (déjà assainie), ou `nil`.
    let text: String?
    /// La question a été coupée aux 2 000 premiers caractères : l'utilisateur doit le savoir.
    let textWasTruncated: Bool
    /// Fichier à joindre, déjà dans les dépôts de l'app (`<racine>/_deposits/<id>/<nom>`), ou `nil`.
    let depositURL: URL?
    /// Un fichier était partagé mais n'a pas pu être copié dans l'app : l'entrée est gardée, l'utilisateur est prévenu.
    let fileCopyFailed: Bool
}

nonisolated enum SharedInboxHandoff {
    /// Reprend l'entrée la plus récente de la boîte. `nil` s'il n'y a rien (ou rien d'exploitable, ou si la plus
    /// récente est déjà prise en charge : `skipping`).
    ///
    /// `@concurrent` : la copie d'un PDF de 200 Mo ne doit pas se faire sur le thread principal.
    ///
    /// - Parameter skipping: entrées déjà reprises dont la route attend encore une fenêtre, ou dont la copie a déjà
    ///   échoué pendant ce lancement : on ne les reprend pas une seconde fois.
    @concurrent
    static func takeLatest(from inbox: SharedInbox, depositRoot: URL, skipping: Set<UUID> = []) async -> SharedHandoff? {
        let entries = inbox.validEntries()
        guard let latest = entries.first, !skipping.contains(latest.id) else { return nil }

        var depositURL: URL?
        var fileCopyFailed = false
        if let file = latest.file {
            depositURL = copiedDeposit(of: latest, file: file, from: inbox, depositRoot: depositRoot)
            fileCopyFailed = depositURL == nil
        }
        guard latest.text != nil || depositURL != nil || fileCopyFailed else { return nil }
        // Les partages plus anciens sont remplacés par celui-ci. Si la copie a échoué, on ne touche à rien.
        if !fileCopyFailed { entries.dropFirst().forEach(inbox.remove) }
        return SharedHandoff(
            entryID: latest.id,
            text: latest.text,
            textWasTruncated: latest.textWasTruncated == true,
            depositURL: depositURL,
            fileCopyFailed: fileCopyFailed
        )
    }

    /// L'app a repris le contenu : la copie de l'App Group peut partir.
    static func commit(_ entryID: UUID, in inbox: SharedInbox) {
        inbox.remove(id: entryID)
    }

    /// Copie (jamais déplacement : l'App Group et le dossier temporaire de l'app sont deux conteneurs), puis
    /// revérifie la COPIE : un fichier remplacé entre le contrôle et la copie (autre app du groupe) est refusé.
    private static func copiedDeposit(
        of entry: SharedInboxEntry,
        file: SharedInboxEntry.File,
        from inbox: SharedInbox,
        depositRoot: URL
    ) -> URL? {
        guard let deposit = try? AttachmentFileVault.stageDeposit(
            of: inbox.payloadURL(of: entry),
            named: file.displayName,
            rootDirectory: depositRoot
        ) else {
            return nil
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: deposit.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular,
              attributes?[.size] as? Int == file.byteCount,
              SharedFileType.detect(fileAt: deposit) == file.type else {
            AttachmentFileVault.discardDeposit(deposit, rootDirectory: depositRoot)
            return nil
        }
        return deposit
    }
}
