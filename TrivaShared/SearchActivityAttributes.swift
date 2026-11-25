//
//  SearchActivityAttributes.swift
//  TrivaShared
//
//  Chantier 2.1 (mission D) : la partie FIXE de l'activité en direct (la question et sa conversation). Le type est
//  une structure ordinaire, testable partout ; seule la conformité à `ActivityAttributes` est réservée à iOS
//  (ActivityKit n'existe pas sur Mac).
//

import Foundation
#if os(iOS)
import ActivityKit
#endif

nonisolated struct SearchActivityAttributes: Codable, Hashable, Sendable {
    typealias ContentState = SearchActivityState

    static let maxQuestionLength = 140

    let question: String
    let conversationID: UUID?

    /// La question est ramenée à UNE ligne et à 140 caractères au plus (l'activité refuse plus de 4 Ko, et deux
    /// lignes suffisent à l'écran).
    init(question: String, conversationID: UUID?) {
        self.question = Self.oneLine(question)
        self.conversationID = conversationID
    }

    /// Lien ouvert par un toucher : la conversation, ou rien (l'app s'ouvre simplement).
    var tapURL: URL? {
        conversationID.flatMap { TrivaURLRoute.url(for: .conversation($0)) }
    }

    private static func oneLine(_ text: String) -> String {
        let flattened = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flattened.count > maxQuestionLength else { return flattened }
        return String(flattened.prefix(maxQuestionLength - 1)) + "…"
    }
}

#if os(iOS)
nonisolated extension SearchActivityAttributes: ActivityAttributes {}
#endif
