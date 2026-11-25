//
//  SharedInboxConsumer.swift
//  Triva
//
//  Chantier 2.1 (mission E) puis mission P : à chaque passage de l'app au premier plan, reprend TOUS les partages que
//  l'extension a déposés dans l'App Group (8 au plus, dans l'ordre d'arrivée). Une extension de partage ne peut pas ouvrir l'app (limite Apple) : c'est l'app qui vient
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

    /// Reprend tous les partages en attente, du plus ancien au plus récent. Sans effet si une reprise est déjà en cours.
    ///
    /// Chaque entrée de l'App Group n'est effacée qu'une fois SES routes prises par une fenêtre (voir `SharedInboxHandoff`) :
    /// une entrée dont la copie du fichier a échoué sans texte à livrer reste, pour un nouvel essai au prochain lancement.
    func takeOver() async {
        guard let inbox, !isTakingOver else { return }
        isTakingOver = true
        defer { isTakingOver = false }
        let generation = eraseGeneration
        let handoffs = await SharedInboxHandoff.takeAll(from: inbox, depositRoot: depositRoot, skipping: skippedEntryIDs)
        guard !handoffs.isEmpty else { return }
        // « Tout effacer » est passé pendant la reprise : ni brouillon, ni fichier ne doivent réapparaître.
        guard generation == eraseGeneration else {
            for handoff in handoffs {
                if let deposit = handoff.depositURL { AttachmentFileVault.discardDeposit(deposit, rootDirectory: depositRoot) }
                SharedInboxHandoff.commit(handoff.entryID, in: inbox)
            }
            return
        }
        skippedEntryIDs.formUnion(handoffs.map(\.entryID))
        let submissions = Self.submissions(for: handoffs)
        // Chaque entrée compte ses propres routes : elle part de l'App Group quand elles sont toutes prises.
        let remaining = Dictionary(grouping: submissions.compactMap(\.entryID), by: { $0 }).mapValues { Remaining(count: $0.count) }
        for submission in submissions {
            guard let entryID = submission.entryID, let counter = remaining[entryID] else {
                center.submit(submission.route)
                continue
            }
            center.submit(submission.route) { [weak self] in
                guard counter.finishOne() else { return }
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

    /// Une route à déposer, et l'entrée qui en dépend (`nil` : une information commune à tous les partages).
    private struct Submission {
        let route: SystemRoute
        let entryID: UUID?
    }

    /// Les fichiers d'abord, TOUS (ils arrivent dans la même fenêtre, d'un seul bloc : la fenêtre dit d'un coup lesquels
    /// dépassent la limite) ; puis les textes, dans l'ordre d'arrivée, ajoutés à la suite du brouillon ; les informations
    /// en dernier, une fois chacune (texte coupé, fichier non copié), après le brouillon : un dépôt de fichier efface
    /// les informations déjà affichées.
    private static func submissions(for handoffs: [SharedHandoff]) -> [Submission] {
        var submissions: [Submission] = []
        for handoff in handoffs {
            if let deposit = handoff.depositURL { submissions.append(Submission(route: .attachment(deposit), entryID: handoff.entryID)) }
        }
        for handoff in handoffs {
            if let text = handoff.text { submissions.append(Submission(route: .draft(text), entryID: handoff.entryID)) }
        }
        if handoffs.contains(where: \.textWasTruncated) { submissions.append(Submission(route: .notice(.truncatedText), entryID: nil)) }
        if handoffs.contains(where: \.fileCopyFailed) { submissions.append(Submission(route: .notice(.fileNotCopied), entryID: nil)) }
        return submissions
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
