//
//  ChatViewModel+Favorites.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation
import os

/// Favoris du chat (1.10), sortis de `ChatViewModel.swift` pour le garder sous les 800 lignes
/// (tâche 1.16). Rien n'a changé : seuls quelques membres privés du ViewModel sont devenus internes
/// (`favoritesStore`, `favoritesCache`, `logger`, `now`, `reportPersistenceFailure`, `precedingQuestion`).
extension ChatViewModel {
    /// Étoile pleine ? Lit `favoritesStore.revision` : appelée dans un `body`,
    /// la vue se redessine quand un favori change ailleurs (écran Favoris à
    /// côté du chat sur iPad / Mac). Identifiants relus une fois par révision.
    func isFavorite(_ message: Message) -> Bool {
        guard let storedID = message.storedMessageID else { return false }
        return favoritedStoredMessageIDs().contains(storedID)
    }

    /// Réponse terminée ET persistée : le favori porte l'`id` du
    /// `StoredMessage`, jamais l'UUID éphémère de la bulle. Donc jamais
    /// pendant le streaming, ni sans historique.
    func canToggleFavorite(_ message: Message) -> Bool {
        favoritesStore != nil && message.role == .assistant && !message.isStreaming
            && message.status != .noReliableSources && message.storedMessageID != nil
    }

    /// Marque ou retire une réponse : question = celle qui la précède, réponse
    /// = texte brut et sources dans l'ordre de citation.
    func toggleFavorite(messageID: UUID) {
        guard let favoritesStore,
              let index = messages.firstIndex(where: { $0.id == messageID }),
              canToggleFavorite(messages[index]),
              let storedID = messages[index].storedMessageID else { return }
        let message = messages[index]
        do {
            if favoritedStoredMessageIDs().contains(storedID) {
                try favoritesStore.unmark(messageID: storedID)
            } else {
                try favoritesStore.mark(
                    messageID: storedID,
                    conversationID: message.storedConversationID,
                    question: precedingQuestion(beforeIndex: index) ?? "",
                    answer: message.text,
                    sources: message.sources,
                    uncitableSourceNumbers: message.uncitableSourceNumbers,
                    now: now()
                )
            }
        } catch {
            reportPersistenceFailure(error)
        }
    }

    private func favoritedStoredMessageIDs() -> Set<UUID> {
        guard let favoritesStore else { return [] }
        let revision = favoritesStore.revision
        if let favoritesCache, favoritesCache.revision == revision {
            return favoritesCache.ids
        }
        do {
            let ids = try favoritesStore.favoritedMessageIDs()
            favoritesCache = (revision, ids)
            return ids
        } catch {
            // Appelée depuis un `body` : aucune écriture d'état observé ici.
            Self.logger.error("Lecture des favoris impossible : \(String(describing: error), privacy: .private)")
            return favoritesCache?.ids ?? []
        }
    }
}
