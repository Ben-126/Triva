//
//  ChatViewModel+SharedConversation.swift
//  Triva
//
//  Mission F2 (26/11) : une conversation affichée dans une fenêtre B pendant qu'une autre fenêtre (ou Siri) y répond
//  montre la question puis la réponse quand elles arrivent, sans qu'il faille la rouvrir. Mac, iPad à plusieurs fenêtres.
//

import Foundation
import os

extension ChatViewModel {
    /// Le fil affiché est-il plus COURT que l'historique ? Seuls les messages réellement écrits comptent : la « Réponse
    /// interrompue » reconstruite à l'ouverture (`markingUnansweredQuestions`) n'y est jamais.
    ///
    /// Jamais « en retard » quand le fil est plus LONG : une réponse en échec ou non enregistrée n'est pas dans
    /// l'historique, et la recharger la ferait disparaître. C'est aussi ce qui laisse en paix la fenêtre qui vient de
    /// répondre elle-même (fil et historique ont alors la même longueur).
    static func isBehindHistory(displayed: [Message], storedCount: Int) -> Bool {
        let shown = displayed.filter { !$0.isRebuiltInterruptionMarker }.count
        return storedCount > shown
    }

    /// Une réponse commence ou finit dans `conversationID` (cette fenêtre, une autre, Siri : `ActiveExchangeRegistry`).
    /// Si cette fenêtre affiche cette conversation, au repos, et qu'elle est en retard sur l'historique, le fil est relu.
    /// Rien n'est touché d'autre : ni le brouillon, ni les fichiers joints, ni les bandeaux.
    ///
    /// Pas au repos = pas touchée : une fenêtre qui génère elle-même garde sa bulle en direct, et n'est pas prévenue de
    /// SA propre réponse (`ActiveExchangeRegistry.begin(_:by:)`). Si une autre fenêtre a répondu en même temps dans la
    /// même conversation, elle ne montre cette autre réponse qu'à la réouverture. Une réponse refaite ailleurs (« Réessayer », « Lire cette page ») remplace un
    /// message sans changer le nombre : elle n'est pas reprise ici, la conversation rouverte la montre à jour.
    func refreshAfterExchange(in conversationID: UUID) {
        guard conversationID == currentConversationID,
              !isGenerating,
              backgroundExchanges[conversationID] == nil,
              let historyStore else { return }
        do {
            guard let conversation = try historyStore.conversation(with: conversationID) else { return }
            let stored = conversation.orderedMessages
            guard Self.isBehindHistory(displayed: messages, storedCount: stored.count) else { return }
            let restored = Self.markingUnansweredQuestions(
                stored.map { Self.restoredMessage($0, conversationID: conversationID) },
                isAnswerComing: ActiveExchangeRegistry.shared.isAnswering(conversationID),
                at: now()
            )
            displayThread(restored, conversationID: conversationID, isGenerating: false)
        } catch {
            // Une lecture manquée ne casse rien : le fil reste tel quel, la conversation rouverte le rattrapera.
            Self.logger.error("Fil non actualisé après une réponse d'une autre fenêtre : \(String(describing: error), privacy: .public)")
        }
    }
}

extension ChatViewModel.Message {
    /// « Réponse interrompue » fabriquée à l'ouverture d'une question sans réponse : vide, jamais écrite dans l'historique.
    fileprivate var isRebuiltInterruptionMarker: Bool {
        role == .assistant && status == .interrupted && text.isEmpty && storedMessageID == nil
    }
}
