//
//  TrivaRootCoordinator+Presentations.swift
//  Triva
//
//  Mission X2 : ce qu'une fenêtre fait quand une route ou une autre fenêtre lui demande d'afficher quelque chose
//  (présentations à fermer, conversation à montrer).
//

import Foundation
import SwiftUI

extension TrivaRootCoordinator {
    /// Ferme tout ce que la fenêtre présente par-dessus son contenu : feuille des Réglages, choix du modèle local, choix du
    /// moteur (coquille), Coup d'œil et autres présentations locales (`PresentationDismissal`), Safari intégré (iPhone, iPad).
    ///
    /// La feuille d'accord « IA cloud » n'est PAS fermée ici : c'est une décision de l'utilisateur, les routes l'attendent
    /// (`consumeSystemRoutes`).
    func closePresentations() {
        settingsSheet = nil
        session.isChoosingMLXModel = false
        dismissShellPresentations?()
        presentationDismissal.dismissAll()
        #if os(iOS)
        BrowserPresenter.dismissPresented()
        #endif
    }

    /// Cette fenêtre tient `id` (affichée, ou écrite en arrière-plan pendant qu'elle montre un autre fil) et une autre
    /// fenêtre vient de la ramener devant : elle l'affiche sur la Recherche. Sans cela, la fenêtre revenait telle quelle,
    /// sur la Bibliothèque ou sur l'autre fil, et la conversation demandée ne s'affichait jamais (R2-03).
    func revealConversation(_ id: UUID) {
        closePresentations()
        session.ensureChatViewModel()
        if session.chatViewModel?.currentConversationID == id {
            selection = .search
            syncWindowTarget()
        } else {
            openConversation(id: id)
        }
    }
}
