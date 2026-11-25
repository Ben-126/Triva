//
//  SharedInboxConsumer.swift
//  Triva
//
//  Chantier 2.1 (mission E) : à chaque passage de l'app au premier plan, reprend ce que l'extension de partage a
//  déposé dans l'App Group. Une extension de partage ne peut pas ouvrir l'app (limite Apple) : c'est l'app qui vient
//  chercher. Le texte devient un BROUILLON (`SystemRoute.draft`), le fichier une pièce jointe (`SystemRoute.attachment`) :
//  JAMAIS envoyés, l'utilisateur relit puis valide lui-même.
//

import Foundation

@MainActor
final class SharedInboxConsumer {
    static let shared = SharedInboxConsumer(inbox: SharedInbox.live())

    private let inbox: SharedInbox?
    private let center: SystemRouteCenter
    private let depositRoot: URL
    /// Deux scènes (iPad) peuvent devenir actives presque ensemble : une seule reprise à la fois.
    private var isTakingOver = false
    /// Compte les « Tout effacer » : une reprise commencée avant un effacement ne dépose rien après lui.
    private var eraseGeneration = 0
    /// Entrées déjà reprises dont la route attend encore une fenêtre, ou dont la copie a échoué pendant CE lancement :
    /// on ne les reprend pas deux fois.
    private var skippedEntryIDs: Set<UUID> = []

    /// - Parameters:
    ///   - inbox: la boîte de l'App Group, `nil` quand le groupe n'est pas disponible (rien à reprendre).
    ///   - depositRoot: racine du coffre de pièces jointes (celle du contrôleur de pièces jointes de la fenêtre).
    init(
        inbox: SharedInbox?,
        center: SystemRouteCenter = .shared,
        depositRoot: URL = AttachmentFileVault.defaultRootDirectory
    ) {
        self.inbox = inbox
        self.center = center
        self.depositRoot = depositRoot
    }

    /// Reprend le partage le plus récent, s'il y en a un. Sans effet si une reprise est déjà en cours.
    ///
    /// L'entrée de l'App Group n'est effacée qu'une fois les routes prises par une fenêtre (voir `SharedInboxHandoff`).
    func takeOver() async {
        guard let inbox, !isTakingOver else { return }
        isTakingOver = true
        defer { isTakingOver = false }
        let generation = eraseGeneration
        guard let handoff = await SharedInboxHandoff.takeLatest(from: inbox, depositRoot: depositRoot, skipping: skippedEntryIDs) else { return }
        // « Tout effacer » est passé pendant la reprise : ni brouillon, ni fichier ne doivent réapparaître.
        guard generation == eraseGeneration else {
            if let deposit = handoff.depositURL { AttachmentFileVault.discardDeposit(deposit, rootDirectory: depositRoot) }
            SharedInboxHandoff.commit(handoff.entryID, in: inbox)
            return
        }
        skippedEntryIDs.insert(handoff.entryID)
        if handoff.fileCopyFailed && handoff.text == nil {
            // Rien d'autre à livrer : l'entrée reste (24 h) pour un nouvel essai au prochain lancement.
            center.submit(.notice(.fileNotCopied))
            return
        }
        let routes = Self.routes(for: handoff)
        let remaining = Remaining(count: routes.count)
        let entryID = handoff.entryID
        for route in routes {
            center.submit(route) { [weak self] in
                guard remaining.finishOne() else { return }
                self?.entryTaken(entryID, in: inbox)
            }
        }
    }

    /// « Tout effacer » : vide la boîte (entrées, fichiers, copies en cours d'écriture) et jette ce qui attend une
    /// fenêtre. Appelé par l'étape « intégrations système » de l'effacement.
    ///
    /// - Returns: `false` si quelque chose est resté dans l'App Group (suppression refusée, extension en train d'écrire).
    @discardableResult
    func eraseAll() -> Bool {
        eraseGeneration += 1
        skippedEntryIDs.removeAll()
        center.discardPending()
        return inbox?.removeAll() ?? true
    }

    // MARK: Privé

    /// Le fichier d'abord : le brouillon qui l'accompagne arrive dans la même fenêtre. Les informations (texte coupé,
    /// fichier non copié) viennent en dernier, une fois le brouillon posé.
    private static func routes(for handoff: SharedHandoff) -> [SystemRoute] {
        var routes: [SystemRoute] = []
        if let deposit = handoff.depositURL { routes.append(.attachment(deposit)) }
        if let text = handoff.text { routes.append(.draft(text)) }
        if handoff.textWasTruncated { routes.append(.notice(.truncatedText)) }
        if handoff.fileCopyFailed { routes.append(.notice(.fileNotCopied)) }
        return routes
    }

    /// Toutes les routes de l'entrée ont été prises : la copie de l'App Group peut partir. (Si le fichier n'a pas pu
    /// être copié mais qu'un texte l'accompagnait, le texte est livré, l'utilisateur est prévenu pour le fichier, et
    /// l'entrée part aussi : la garder referait arriver le même texte à chaque passage au premier plan.)
    private func entryTaken(_ entryID: UUID, in inbox: SharedInbox) {
        SharedInboxHandoff.commit(entryID, in: inbox)
        skippedEntryIDs.remove(entryID)
    }

    /// Compte les routes d'une entrée encore en attente.
    @MainActor
    private final class Remaining {
        private var count: Int
        init(count: Int) { self.count = count }
        /// `true` quand c'était la dernière.
        func finishOne() -> Bool {
            count -= 1
            return count == 0
        }
    }
}
