//
//  FileAttachmentController+Receive.swift
//  Triva
//
//  K2 : ce que fait le chat de ce qu'on lui apporte (dépôt, collage, photothèque) : UN seul chemin, pour que les
//  plafonds (200 Mo, 50 Mo pour une image) et les refus soient les mêmes partout.
//

import Foundation

extension FileAttachmentController {
    /// Applique un plan : fichiers et images mis en file (copies des dépôts du coffre), refus expliqués, texte coupé
    /// annoncé. Le texte à ajouter au brouillon est traité par l'appelant (`DropPlan.draftTexts`).
    func receive(_ plan: DropPlan) {
        enqueue(plan.attachableURLs, areDeposits: true)
        if let message = plan.refusalMessage {
            reportRefusal(message)
        }
        if plan.hasTruncatedText {
            reportTruncatedText()
        }
    }

    /// Dépôt, collage ou photothèque : pièces jointes à la conversation, texte ajouté au brouillon, rien n'est envoyé.
    /// - Returns: le plan appliqué, `nil` si rien n'était à faire.
    @discardableResult
    func receive(_ items: [DroppedItem], draft: inout String) -> DropPlan? {
        let plan = DropPlan(items: items)
        guard !plan.isEmpty else { return nil }
        receive(plan)
        if !plan.draftTexts.isEmpty {
            draft = DropPlan.appending(plan.draftTexts, to: draft)
        }
        return plan
    }
}
