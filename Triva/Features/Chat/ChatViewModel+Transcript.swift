//
//  ChatViewModel+Transcript.swift
//  Triva
//
//  Created by ben podrojsky on 07/09/2026.
//

import Foundation

/// Lecture et reconstitution du fil (message relu de l'historique, fichiers joints, historique du classifieur,
/// mode mémorisé). Rangé à part de `ChatViewModel.swift` (rangement W4-R, code déplacé ; seul changement : `private` retiré sur `restoredMessage` et `newlyAttachedFiles`).
extension ChatViewModel {
    /// Message relu : terminé par construction (rien n'est persisté avant la
    /// fin du flux), sources dans l'ordre de citation, fichiers joints
    /// recomptés depuis leur URL synthétique, médias à `.idle`.
    static func restoredMessage(_ stored: StoredMessage, conversationID: UUID) -> Message {
        let sources = stored.orderedSources.map { source in
            SearXNGSearchResult(
                title: source.title, url: source.url, content: source.snippet,
                imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
            )
        }
        if stored.role == .assistant && stored.reportsNoReliableSources {
            var message = Message(role: .assistant)
            message.finish(.noReliableSources, at: stored.createdAt)
            message.storedMessageID = stored.id
            message.storedConversationID = conversationID
            return message
        }
        var message = Message(role: stored.role == .user ? .user : .assistant, text: stored.text, sources: sources)
        message.attachmentSourceCount = sources.prefix { UploadsSearchResultBuilder.attachmentID(fromSourceURL: $0.url) != nil }.count
        if message.role == .assistant {
            message.storedMessageID = stored.id
            message.storedConversationID = conversationID
            message.restore(stored.answerNotes)
        }
        return message
    }

    /// Fichiers apparus depuis la question précédente : un fichier reste
    /// attaché à toute la conversation, il ne s'affiche que sous la question
    /// avec laquelle il est parti.
    func newlyAttachedFiles() -> [Message.AttachedFile] {
        let alreadyShown = Set(messages.flatMap(\.attachedFiles).map(\.id))
        return attachmentController.attachments
            .filter { !alreadyShown.contains($0.id) }
            .map { Message.AttachedFile(id: $0.id, fileName: $0.fileName, kind: $0.kind) }
    }

    /// Instantané `Sendable` pour le pipeline, `nil` sans fichier joint.
    func attachmentSnapshot() -> AttachmentSearchIndex? {
        attachmentController.attachments.isEmpty ? nil : attachmentController.store.searchIndex
    }

    func precedingQuestion(beforeIndex index: Int) -> String? {
        messages[..<index].last { $0.role == .user }?.text
    }

    /// Historique du classifieur ET du prompt final (bug 1) : les tours
    /// PRÉCÉDENTS seulement (sinon la question serait dupliquée dans
    /// `<conversation_history>` en plus de `<user_query>`). Une réponse y
    /// entre par son texte VISIBLE — sans `<think>` ni `<tldr>`, contrat
    /// d'I1a — et seulement terminée et non vide : un échange en échec,
    /// interrompu, sans source fiable ou sans réponse est retiré EN ENTIER,
    /// question comprise — le modèle ne l'a jamais vu aboutir.
    static func classifierHistory(from messages: [Message]) -> [ClassifierChatMessage] {
        var history: [ClassifierChatMessage] = []
        var pendingQuestion: String?
        for message in messages {
            guard message.role == .assistant else {
                pendingQuestion = message.text
                continue
            }
            let answer = message.status == .completed ? visibleText(of: message.segments) : ""
            if let question = pendingQuestion, !answer.isEmpty {
                history.append(ClassifierChatMessage(role: .user, content: question))
                history.append(ClassifierChatMessage(role: .assistant, content: answer))
            }
            pendingQuestion = nil
        }
        return history
    }

    /// Ce que l'utilisateur lit : le corps, ou le TL;DR seul sans corps —
    /// même règle que `SearchOrchestrator.suggestionsHistory`.
    static func visibleText(of segments: ReasoningSegments) -> String {
        segments.body.isEmpty ? (segments.tldr ?? "") : segments.body
    }

    /// Mode MÉMORISÉ (1.13), relu à chaque envoi : `ResponseModeSettingsStore`
    /// ne lit `UserDefaults` qu'à son init, une instance gardée ici ne verrait
    /// pas ce que le sélecteur écrit. Rapide par défaut (décision 6 de Ben).
    static func persistedResponseMode(in userDefaults: UserDefaults = .standard) -> ResponseMode {
        ResponseModeSettingsStore(userDefaults: userDefaults).selectedMode
    }
}
