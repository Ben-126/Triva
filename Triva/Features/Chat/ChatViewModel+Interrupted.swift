//
//  ChatViewModel+Interrupted.swift
//  Triva
//
//  Mission M (25/11) : une réponse interrompue se voit, et se relance.
//
//  Deux cas : la réponse arrêtée dans cette session (Stop, app passée en arrière-plan avec le modèle local), et la
//  question relue de l'historique sans réponse (plantage, app fermée, arrêt forcé). La seconde n'existe pas dans
//  l'historique : rien n'y est écrit avant la fin du flux. Elle est reconstruite à l'ouverture, jamais enregistrée,
//  et rien ne part tout seul.
//

import Foundation

extension ChatViewModel {
    /// Textes « à valider par Ben ».
    static let interruptedAnswerMessage = "Réponse interrompue"
    static let retryInterruptedTitle = "Réessayer"

    /// Le fil relu, avec une réponse interrompue (vide) après chaque question restée sans réponse. `isAnswerComing` : on
    /// est en train de répondre à la dernière (autre fenêtre, Siri), elle n'est donc pas interrompue.
    static func markingUnansweredQuestions(_ thread: [Message], isAnswerComing: Bool, at date: Date) -> [Message] {
        thread.indices.flatMap { index -> [Message] in
            let message = thread[index]
            guard message.role == .user else { return [message] }
            let isLast = index == thread.index(before: thread.endIndex)
            let isAnswered = isLast ? isAnswerComing : thread[index + 1].role == .assistant
            return isAnswered ? [message] : [message, interruptedAnswer(at: date)]
        }
    }

    private static func interruptedAnswer(at date: Date) -> Message {
        var answer = Message(role: .assistant)
        answer.finish(.interrupted, at: date)
        return answer
    }

    /// « Réessayer » n'est proposé que sous la DERNIÈRE réponse du fil (même raison que `canRetryInQuickMode`), hors
    /// génération, et si personne d'autre ne répond dans cette conversation.
    func canRetryInterrupted(_ message: Message) -> Bool {
        !isGenerating
            && message.role == .assistant
            && message.status == .interrupted
            && messages.last?.id == message.id
            && messages.dropLast().contains { $0.role == .user }
            && !ActiveExchangeRegistry.shared.isAnswering(currentConversationID)
    }

    /// Refait la réponse interrompue : MÊME question, même bulle, mode mémorisé. Le début déjà écrit est remplacé.
    func retryInterrupted(messageID: UUID) async {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              canRetryInterrupted(messages[index]),
              let questionIndex = messages[..<index].lastIndex(where: { $0.role == .user }) else { return }
        await rerunAnswer(at: index, questionIndex: questionIndex, mode: readResponseMode())
    }

    /// Voir `retryInterrupted(messageID:)`. Lancée par l'utilisateur seulement (bouton, après l'accord IA cloud).
    func startRetryInterrupted(messageID: UUID) {
        guard !isGenerating else { return }
        sendTask = Task { await self.retryInterrupted(messageID: messageID) }
    }
}
