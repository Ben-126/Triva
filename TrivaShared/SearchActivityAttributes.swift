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

    let conversationID: UUID?

    init(conversationID: UUID?) {
        self.conversationID = conversationID
    }

    /// Lien ouvert par un toucher : la conversation, ou rien (l'app s'ouvre simplement).
    var tapURL: URL? {
        conversationID.flatMap { TrivaURLRoute.url(for: .conversation($0)) }
    }
}

#if os(iOS)
nonisolated extension SearchActivityAttributes: ActivityAttributes {}
#endif
