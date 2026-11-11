//
//  ChatViewModel+Offline.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation

/// Un envoi arrêté parce que l'appareil est hors connexion (tâche 1.16) : ce que le bandeau dit
/// (`reason.message`) et la réponse vide à relancer (`messageID`).
struct OfflineNotice: Sendable, Equatable {
    let reason: OfflineBlockReason
    let messageID: UUID
}

/// Mode hors connexion du chat (tâche 1.16).
///
/// TROIS issues d'un envoi hors connexion, décidées par `OfflinePlan` puis par les artefacts :
/// 1. moteur local (Apple Intelligence, MLX avec modèle présent) : le modèle répond sans recherche,
///    `Message.answeredOffline` porte la mention « Hors connexion, sans source » ;
/// 2. envoi impossible (clé cloud, modèle MLX absent, mode Fiable sans source, météo) : AUCUNE
///    tentative réseau, un `OfflineNotice` explique, un bouton relance au retour de la connexion ;
/// 3. connecté : rien ne change.
///
/// La réponse d'un envoi bloqué reste une bulle `.failed` VIDE (non dessinée, voir
/// `MessageBubblePresentation.showsBubble`) et n'est pas persistée : la question l'est (politique de
/// `ChatHistoryStore`), la relance écrira la réponse. L'historique du classifieur retire l'échange
/// entier (`classifierHistory`), comme tout échec.
extension ChatViewModel {
    /// Plan hors connexion du moment, `nil` si connecté. Lu dans un `body`, il rend la vue sensible à
    /// l'état du `ConnectivityMonitor` (observable) : bandeau et bouton suivent le réseau.
    var offlinePlan: OfflinePlan? { resolveOfflinePlan() }

    var isOffline: Bool { offlinePlan != nil }

    /// Bouton « Relancer » actif : un envoi bloqué attend, rien ne tourne, et le système annonce une
    /// connexion. Si elle échoue quand même, l'envoi suivant remontera l'erreur réseau habituelle.
    var canRelaunchAfterReconnect: Bool {
        offlineNotice != nil && !isGenerating && !isOffline
    }

    /// Bouton « Répondre sans source » du mode Fiable bloqué : seulement hors connexion et seulement
    /// pour ce motif (`OfflineBlockReason.offersQuickModeAnswer`).
    var canAnswerWithoutSourceOffline: Bool {
        guard let notice = offlineNotice else { return false }
        return notice.reason.offersQuickModeAnswer && !isGenerating
    }

    /// Relance la MÊME question à la place de la réponse bloquée. `quickMode` : en mode Rapide (réponse
    /// sans source du modèle local), seul choix possible tant que la connexion manque. Sans effet si la
    /// relance normale est demandée alors que le système annonce encore l'absence de connexion.
    func retryAfterOffline(quickMode: Bool = false) async {
        guard let notice = offlineNotice, !isGenerating, messages.last?.id == notice.messageID,
              quickMode ? canAnswerWithoutSourceOffline : canRelaunchAfterReconnect,
              let questionIndex = messages.dropLast().lastIndex(where: { $0.role == .user }) else { return }
        let question = messages[questionIndex].text
        let answerID = notice.messageID
        updateMessage(id: answerID) { $0 = Message(id: answerID, role: .assistant, isStreaming: true) }
        await runExchange(Exchange(
            question: question,
            history: Self.classifierHistory(from: Array(messages[..<questionIndex])),
            mode: quickMode ? .quick : readResponseMode(),
            attachments: attachmentSnapshot(),
            conversationID: currentConversationID,
            answerID: answerID
        ))
    }

    /// Termine l'échange sans rien générer : bulle vide `.failed`, bandeau. Seul l'échange actif écrit
    /// le bandeau (un échange remplacé ne touche pas à l'état du suivant, comme `fail`).
    func blockOffline(_ exchange: Exchange, exchangeID: UUID, reason: OfflineBlockReason) {
        if activeExchangeID == exchangeID {
            setOfflineNotice(OfflineNotice(reason: reason, messageID: exchange.answerID))
        }
        finishAnswer(exchange.answerID, as: .failed)
    }

    /// MLX : le chargement a échoué alors que le moteur annonçait un modèle disponible. Hors connexion,
    /// c'est « modèle absent ou incomplet » (voir `MLXProvider.hasDownloadedWeights`).
    static func isLocalModelDownloadFailure(_ error: any Error) -> Bool {
        guard case .downloadFailed? = error as? MLXProviderError else { return false }
        return true
    }
}
