//
//  TrivaRootCoordinator+HandoffPlacement.swift
//  Triva
//
//  Chantier 2.3 (mission H2) : une fenêtre « vide » reçoit la discussion Handoff (Mac) à la place d'une nouvelle fenêtre.
//

import Foundation

extension TrivaRootCoordinator {
    /// Aucune conversation affichée, aucun message, rien dans la barre de saisie : on peut y poser une discussion reçue sans
    /// rien remplacer de ce que l'utilisateur lit ou écrit.
    var isEmptyForHandoff: Bool {
        let chat = session.chatViewModel
        return chat?.currentConversationID == nil
            && (chat?.messages.isEmpty ?? true)
            && session.draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
