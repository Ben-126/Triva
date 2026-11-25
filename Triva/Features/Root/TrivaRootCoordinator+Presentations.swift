//
//  TrivaRootCoordinator+Presentations.swift
//  Triva
//
//  Mission X2 : ce qu'une fenêtre fait quand une route ou une autre fenêtre lui demande d'afficher quelque chose
//  (présentations à fermer, conversation à montrer) et quand l'app quitte le premier plan.
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

    /// L'app change de phase. Sur iPhone et iPad, un modèle MLX ne peut pas travailler pour le GPU en arrière-plan : la réponse
    /// en cours est arrêtée AVANT (partie déjà écrite gardée, marquée interrompue) plutôt que de laisser MLX faire planter
    /// l'app (R2-01). Voir `BackgroundGPUPolicy`.
    /// - Returns: `true` si l'arrêt a été demandé.
    @discardableResult
    func scenePhaseDidChange(_ phase: ScenePhase, restrictsGPU: Bool = BackgroundGPUPolicy.platformRestrictsGPU) -> Bool {
        guard BackgroundGPUPolicy.shouldStopGeneration(phase: phase, engine: session.engine, restrictsGPU: restrictsGPU),
              let chat = session.chatViewModel else { return false }
        chat.stop()
        return true
    }
}
