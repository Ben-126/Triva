//
//  ChatViewModel+History.swift
//  Triva
//
//  Sorti de ChatViewModel.swift (mission C5) pour le garder sous les 800 lignes.
//

import Foundation

/// Écriture de la réponse (ou de l'état « Aucune source fiable ») dans l'historique, en fin d'échange.
/// Écrit dans la conversation CAPTURÉE à l'envoi (`Exchange.conversationID`), jamais dans le fil
/// affiché : c'est ce qui permet à une génération de finir en arrière-plan (`ChatViewModel+Background`).
extension ChatViewModel {
    /// Points 2 et 3 : réponse écrite AU PLUS UNE FOIS, en fin d'échange
    /// QUELLE QU'EN SOIT LA CAUSE (succès, erreur, annulation), texte partiel
    /// compris, jamais vide ; dans la conversation capturée à l'envoi.
    func persistAnswer(_ answer: AnswerDraft, exchange: Exchange) {
        guard let historyStore, let conversationID = exchange.conversationID,
              !answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            // Supprimée pendant la génération : rien à compléter.
            guard let conversation = try historyStore.conversation(with: conversationID) else { return }
            let stored = try historyStore.appendAssistantMessage(
                to: conversation, text: answer.text, sources: answer.sources, notes: answer.notes, now: now()
            )
            let storedID = stored.id
            updateMessage(id: exchange.answerID) { message in
                message.storedMessageID = storedID
                message.storedConversationID = conversationID
            }
        } catch {
            reportPersistenceFailure(error)
        }
    }

    /// Décision de Ben (2026-10-30) : l'état « Aucune source fiable » est
    /// persisté, pour qu'une conversation relue montre le message fixe et,
    /// sur la dernière réponse, le bouton de relance.
    func persistNoReliableSources(exchange: Exchange) {
        guard let historyStore, let conversationID = exchange.conversationID else { return }
        do {
            guard let conversation = try historyStore.conversation(with: conversationID) else { return }
            let stored = try historyStore.appendNoReliableSourcesMessage(
                to: conversation, text: Self.noReliableSourcesMessage, now: now()
            )
            let storedID = stored.id
            updateMessage(id: exchange.answerID) { message in
                message.storedMessageID = storedID
                message.storedConversationID = conversationID
            }
        } catch {
            reportPersistenceFailure(error)
        }
    }

    /// Relance : la réponse « Aucune source fiable » persistée est remplacée
    /// par la nouvelle, pas laissée devant elle dans la conversation relue.
    func deleteStoredMessage(id storedID: UUID?, conversationID: UUID?) {
        guard let historyStore, let storedID, let conversationID else { return }
        do {
            guard let conversation = try historyStore.conversation(with: conversationID),
                  let stored = conversation.messages.first(where: { $0.id == storedID }) else { return }
            try historyStore.delete(stored)
        } catch {
            reportPersistenceFailure(error)
        }
    }
}
