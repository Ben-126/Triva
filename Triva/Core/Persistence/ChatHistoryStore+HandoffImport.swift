//
//  ChatHistoryStore+HandoffImport.swift
//  Triva
//
//  Chantier 2.3 (mission H2) : enregistre une discussion reçue par Handoff comme une conversation locale.
//    - inconnue ici : créée avec son identifiant, ses dates, ses messages, sources et mentions ;
//    - même identifiant ici : FUSION. Seuls les messages absents (par identifiant) s'ajoutent, à la suite ; rien n'est
//      écrasé, le titre local reste ; recevoir deux fois la même discussion n'ajoute rien ;
//    - même identifiant ici ET une fenêtre l'affiche (ou y écrit encore) : COPIE sous un autre identifiant. Fusionner dans
//      ce que la fenêtre montre la laisserait avec un fil périmé, ou ferait écrire deux fenêtres dans la même conversation.
//  La discussion arrive déjà vérifiée par `HandoffSnapshotCodec.decode` (entrée externe).
//

import Foundation
import SwiftData

nonisolated enum HandoffImportDisposition: Equatable, Sendable {
    case created
    case merged(added: Int)
    case createdAsCopy
}

nonisolated struct HandoffImportResult: Equatable, Sendable {
    let conversationID: UUID
    let disposition: HandoffImportDisposition
}

extension ChatHistoryStore: HandoffConversationImporting {
    @discardableResult
    func importHandoff(_ snapshot: HandoffConversationSnapshot, isHeldByAWindow: Bool = false) throws -> HandoffImportResult {
        let context = try readyContext()
        let existing = try conversation(with: snapshot.id)
        if let existing, !isHeldByAWindow {
            let added = merge(snapshot, into: existing, context: context)
            try save(operation: "réception d'une conversation")
            return HandoffImportResult(conversationID: existing.id, disposition: .merged(added: added))
        }
        let isCopy = existing != nil
        let conversation = StoredConversation(
            id: isCopy ? UUID() : snapshot.id,
            title: snapshot.title,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt
        )
        context.insert(conversation)
        for (index, message) in snapshot.messages.enumerated() {
            insert(message, into: conversation, order: index, freshID: isCopy, context: context)
        }
        try save(operation: "réception d'une conversation")
        return HandoffImportResult(conversationID: conversation.id, disposition: isCopy ? .createdAsCopy : .created)
    }

    // MARK: Privé

    /// Ajoute à la suite les messages que la conversation locale n'a pas. - Returns: leur nombre.
    private func merge(_ snapshot: HandoffConversationSnapshot, into conversation: StoredConversation, context: ModelContext) -> Int {
        let known = Set(conversation.messageList.map(\.id))
        let missing = snapshot.messages.filter { !known.contains($0.id) }
        guard !missing.isEmpty else { return 0 }
        var nextOrder = (conversation.messageList.map(\.order).max() ?? -1) + 1
        for message in missing {
            insert(message, into: conversation, order: nextOrder, freshID: false, context: context)
            nextOrder += 1
        }
        conversation.updatedAt = max(conversation.updatedAt, snapshot.updatedAt)
        return missing.count
    }

    private func insert(
        _ message: HandoffConversationSnapshot.Message,
        into conversation: StoredConversation,
        order: Int,
        freshID: Bool,
        context: ModelContext
    ) {
        let stored = StoredMessage(
            id: freshID ? UUID() : message.id,
            role: message.role,
            text: message.text,
            createdAt: message.createdAt,
            order: order
        )
        context.insert(stored)
        stored.conversation = conversation
        stored.reportsNoReliableSources = message.reportsNoReliableSources
        stored.answerNotes = message.notes.storedNotes
        for source in message.sources {
            let storedSource = StoredSource(title: source.title, url: source.url, snippet: source.snippet, order: source.order)
            context.insert(storedSource)
            storedSource.message = stored
        }
    }
}
