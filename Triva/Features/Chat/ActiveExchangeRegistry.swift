//
//  ActiveExchangeRegistry.swift
//  Triva
//
//  Mission M (25/11).
//

import Foundation
import Observation

/// Conversations dont une réponse est EN COURS, toutes fenêtres et Siri confondus. Une conversation relue dont la
/// dernière question n'a pas de réponse est normalement une réponse interrompue ; sauf si quelqu'un est justement en
/// train d'y répondre, ce que l'historique ne dit pas (rien n'y est écrit avant la fin du flux).
///
/// Observable : « Réessayer » (`ChatViewModel.canRetryInterrupted`) réapparaît quand l'autre réponse se termine.
@MainActor
@Observable
final class ActiveExchangeRegistry {
    static let shared = ActiveExchangeRegistry()

    private var counts: [UUID: Int] = [:]

    func begin(_ conversationID: UUID?) {
        guard let conversationID else { return }
        counts[conversationID, default: 0] += 1
    }

    func end(_ conversationID: UUID?) {
        guard let conversationID, let count = counts[conversationID] else { return }
        counts[conversationID] = count > 1 ? count - 1 : nil
    }

    func isAnswering(_ conversationID: UUID?) -> Bool {
        guard let conversationID else { return false }
        return counts[conversationID] != nil
    }
}
