//
//  HandoffConversationSnapshot.swift
//  Triva
//
//  Chantier 2.3 (mission H2) : la discussion telle qu'elle voyage entre deux appareils par Handoff. Une valeur pure,
//  sans lien avec SwiftData : le receveur la relit, la vérifie (`HandoffSnapshotCodec`) et seulement alors
//  l'enregistre (`ChatHistoryStore.importHandoff`).
//
//  Décision de Ben (2026-11-26) : Handoff transfère la DISCUSSION ENTIÈRE (questions, réponses, sources), plus
//  seulement le brouillon. Ce qui n'est pas fini (une réponse en cours) n'existe pas dans la base : ce n'est pas envoyé.
//

import Foundation

nonisolated struct HandoffConversationSnapshot: Codable, Sendable, Equatable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [Message]

    nonisolated struct Message: Codable, Sendable, Equatable {
        var id: UUID
        var role: StoredMessageRole
        var text: String
        var createdAt: Date
        var order: Int
        var reportsNoReliableSources: Bool
        var notes: Notes
        var sources: [Source]
    }

    /// Les mentions de la réponse sur ses sources (`StoredAnswerNotes`), sans la mention interne `searXNGUnreachable`
    /// (un état de cet appareil, qui n'a pas de sens ailleurs).
    nonisolated struct Notes: Codable, Sendable, Equatable {
        var uncitableSourceNumbers: [Int] = []
        var answeredWithoutSearch = false
        var answeredOffline = false
        var answeredWithoutReadableSource = false
        var sourcesMayBeOffTopic = false
    }

    nonisolated struct Source: Codable, Sendable, Equatable {
        var title: String
        var url: String
        var snippet: String?
        var order: Int
    }
}

extension HandoffConversationSnapshot.Notes {
    init(_ notes: StoredAnswerNotes) {
        self.init(
            uncitableSourceNumbers: notes.uncitableSourceNumbers.sorted(),
            answeredWithoutSearch: notes.answeredWithoutSearch,
            answeredOffline: notes.answeredOffline,
            answeredWithoutReadableSource: notes.answeredWithoutReadableSource,
            sourcesMayBeOffTopic: notes.sourcesMayBeOffTopic
        )
    }

    var storedNotes: StoredAnswerNotes {
        StoredAnswerNotes(
            uncitableSourceNumbers: Set(uncitableSourceNumbers.filter { $0 > 0 }),
            answeredWithoutSearch: answeredWithoutSearch,
            answeredOffline: answeredOffline,
            answeredWithoutReadableSource: answeredWithoutReadableSource,
            sourcesMayBeOffTopic: sourcesMayBeOffTopic,
            searXNGUnreachable: false
        )
    }
}

// MARK: - Depuis la base

extension HandoffConversationSnapshot {
    /// L'état ENREGISTRÉ de la conversation : questions et réponses finies. Messages triés par `(order, createdAt, id)`
    /// (déterministe, même si deux messages partagent un `order`).
    @MainActor
    init(conversation: StoredConversation) {
        let ordered = conversation.messageList.sorted {
            ($0.order, $0.createdAt, $0.id.uuidString) < ($1.order, $1.createdAt, $1.id.uuidString)
        }
        self.init(
            id: conversation.id,
            title: conversation.title,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt,
            messages: ordered.map { message in
                Message(
                    id: message.id,
                    role: message.role,
                    text: message.text,
                    createdAt: message.createdAt,
                    order: message.order,
                    reportsNoReliableSources: message.reportsNoReliableSources,
                    notes: Notes(message.answerNotes),
                    sources: message.orderedSources.enumerated().map { index, source in
                        Source(title: source.title, url: source.url, snippet: source.snippet, order: index)
                    }
                )
            }
        )
    }
}
