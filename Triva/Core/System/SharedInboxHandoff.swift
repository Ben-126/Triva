//
//  SharedInboxHandoff.swift
//  Triva
//
//  Chantier 2.1 (mission E) puis mission P : la reprise de la boîte de partage par l'app. TOUS les partages en
//  attente (10 au plus : la boîte n'en garde pas davantage) sont repris, dans l'ordre d'arrivée ; ce qu'ils contiennent
//  passe dans l'app (le fichier dans les dépôts de l'app, là où le glisser-déposer met les siens). Rien n'est envoyé :
//  ce qui sort d'ici est un texte pour la barre de saisie et un fichier à joindre, par partage.
//
//  Mission X1 : une entrée n'est effacée de l'App Group QUE quand l'app a vraiment repris son contenu (`commit`,
//  appelé quand une fenêtre a pris la route). Une copie qui échoue (disque plein, fichier protégé) la laisse en place
//  (elle expire seule au bout de 24 h) et le dit ; une app tuée avant l'application ne perd rien. Une entrée expirée
//  ou abîmée est ignorée (et effacée par la boîte) sans gêner les autres.
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
    /// Reprend tous les partages valides de la boîte, du plus ancien au plus récent (ordre d'arrivée). Vide s'il n'y
    /// a rien (ou rien d'exploitable, ou si tout est déjà pris en charge : `skipping`).
    ///
    /// `@concurrent` : la copie d'un PDF de 200 Mo ne doit pas se faire sur le thread principal.
    ///
    /// Deux fichiers de même nom (casse ignorée) venus de deux partages reçoivent des noms différents (« Cours.pdf »,
    /// « Cours (2).pdf ») : la fenêtre refuse un second fichier de même nom comme « déjà joint », et un fichier
    /// DIFFÉRENT ne doit pas être perdu pour cette raison.
    ///
    /// - Parameter skipping: entrées déjà reprises dont la route attend encore une fenêtre, ou dont la copie a déjà
    ///   échoué pendant ce lancement : on ne les reprend pas une seconde fois.
    @concurrent
    static func takeAll(from inbox: SharedInbox, depositRoot: URL, skipping: Set<UUID> = []) async -> [SharedHandoff] {
        // `validEntries()` rend le plus récent d'abord et efface au passage l'expiré, l'abîmé et l'excédent.
        let entries = Array(inbox.validEntries().reversed())
        // Un partage déjà repris, dont la route attend encore une fenêtre, garde son nom : on ne le réutilise pas.
        var takenNames = Set(entries.filter { skipping.contains($0.id) }.compactMap { $0.file?.displayName.lowercased() })
        var handoffs: [SharedHandoff] = []
        for entry in entries where !skipping.contains(entry.id) {
            var depositURL: URL?
            if let file = entry.file {
                let name = uniqueName(file.displayName, among: &takenNames)
                depositURL = copiedDeposit(of: entry, file: file, named: name, from: inbox, depositRoot: depositRoot)
            }
            let fileCopyFailed = entry.file != nil && depositURL == nil
            guard entry.text != nil || depositURL != nil || fileCopyFailed else { continue }
            handoffs.append(SharedHandoff(
                entryID: entry.id,
                text: entry.text,
                textWasTruncated: entry.textWasTruncated == true,
                depositURL: depositURL,
                fileCopyFailed: fileCopyFailed
            ))
        }
        return handoffs
    }

    /// Partages retirés de la boîte faute de place depuis la dernière reprise (F3), à annoncer une fois. `@concurrent` : lecture
    /// de dossier, jamais sur le fil principal.
    @concurrent
    static func takeDroppedCount(from inbox: SharedInbox) async -> Int {
        inbox.takeDroppedCount()
    }

    /// `name` si personne ne l'a pris (casse ignorée, comme la règle « déjà joint » de la fenêtre), sinon « base (2).ext »,
    /// « base (3).ext »… Le nom rendu est noté comme pris.
    static func uniqueName(_ name: String, among taken: inout Set<String>) -> String {
        if taken.insert(name.lowercased()).inserted { return name }
        let base = (name as NSString).deletingPathExtension
        let fileExtension = (name as NSString).pathExtension
        var counter = 2
        while true {
            let candidate = fileExtension.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(fileExtension)"
            if taken.insert(candidate.lowercased()).inserted { return candidate }
            counter += 1
        }
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
        named name: String,
        from inbox: SharedInbox,
        depositRoot: URL
    ) -> URL? {
        guard let deposit = try? AttachmentFileVault.stageDeposit(
            of: inbox.payloadURL(of: entry),
            named: name,
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
