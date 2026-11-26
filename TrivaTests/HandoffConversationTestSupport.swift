//
//  HandoffConversationTestSupport.swift
//  TrivaTests
//
//  Chantier 2.3 (mission H2) : fabriques communes des tests du transfert de la discussion entière par Handoff.
//

import Foundation
@testable import Triva

enum HandoffFixtures {
    static let conversationID = UUID(uuidString: "7B0C6B2A-2F5D-4C58-9E0B-0F1D4D6A9A11")!

    static func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + offset)
    }

    static func source(_ index: Int, url: String? = nil) -> HandoffConversationSnapshot.Source {
        HandoffConversationSnapshot.Source(
            title: "Source \(index)", url: url ?? "https://example.org/page/\(index)", snippet: "Extrait \(index)", order: index
        )
    }

    static func message(
        _ index: Int,
        role: StoredMessageRole? = nil,
        text: String? = nil,
        sources: [HandoffConversationSnapshot.Source] = []
    ) -> HandoffConversationSnapshot.Message {
        let resolvedRole = role ?? (index % 2 == 0 ? .user : .assistant)
        return HandoffConversationSnapshot.Message(
            id: UUID(),
            role: resolvedRole,
            text: text ?? (resolvedRole == .user ? "Question \(index)" : "Réponse \(index) [1]"),
            createdAt: date(TimeInterval(index)),
            order: index,
            reportsNoReliableSources: false,
            notes: HandoffConversationSnapshot.Notes(),
            sources: sources
        )
    }

    /// Une conversation de `pairs` questions-réponses ; chaque réponse cite une source.
    static func snapshot(
        id: UUID = conversationID,
        pairs: Int = 2,
        title: String = "Une conversation"
    ) -> HandoffConversationSnapshot {
        var messages: [HandoffConversationSnapshot.Message] = []
        for pair in 0..<pairs {
            messages.append(message(pair * 2))
            messages.append(message(pair * 2 + 1, sources: [source(0)]))
        }
        return HandoffConversationSnapshot(
            id: id, title: title, createdAt: date(0), updatedAt: date(TimeInterval(pairs * 2)), messages: messages
        )
    }
}
