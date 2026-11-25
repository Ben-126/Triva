//
//  TrivaRootCoordinator+Drop.swift
//  Triva
//
//  Chantier 2.2 (M5) : ce que fait la fenêtre de ce qu'on y dépose. La logique (classement, texte à ajouter)
//  est dans `DropPlan` ; ici, seulement l'application à la conversation de la fenêtre.
//

import Foundation

extension TrivaRootCoordinator {
    /// Applique un dépôt à CETTE fenêtre : fichiers joints à la conversation, texte ajouté au brouillon, refus
    /// expliqués sous les capsules. Rien n'est envoyé : l'utilisateur relit puis valide (comme « Rechercher avec
    /// Triva »). Un dépôt sur une autre destination ramène d'abord à la Recherche, seul endroit où ils servent.
    /// - Returns: le plan appliqué, `nil` si le dépôt était vide (pour les tests).
    @discardableResult
    func receiveDrop(_ items: [DroppedItem]) -> DropPlan? {
        let plan = DropPlan(items: items)
        guard !plan.isEmpty else { return nil }
        session.ensureChatViewModel()
        guard let controller = session.chatViewModel?.attachmentController else {
            discard(plan)
            return plan
        }
        selection = .search

        // Fichiers ET images : le texte d'une image est lu en local (Vision) par la file de lecture.
        controller.receive(plan)
        if !plan.draftTexts.isEmpty {
            session.draft.text = DropPlan.appending(plan.draftTexts, to: session.draft.text)
        }
        return plan
    }

    /// Aucun fil de discussion pour recevoir : rien ne doit rester dans les dépôts.
    private func discard(_ plan: DropPlan) {
        plan.attachableURLs.forEach { AttachmentFileVault.discardDeposit($0) }
    }
}
