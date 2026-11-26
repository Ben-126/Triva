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
///
/// Mission F2 : chaque fenêtre (Mac, iPad à plusieurs fenêtres) a son `ChatViewModel`, mais l'historique est commun. Les
/// fenêtres s'inscrivent ici (`addListener`, références FAIBLES) et sont prévenues au début et à la fin de toute réponse,
/// pour montrer ce qu'une autre fenêtre vient d'écrire dans la conversation qu'elles affichent
/// (`ChatViewModel.refreshAfterExchange(in:)`).
@MainActor
@Observable
final class ActiveExchangeRegistry {
    static let shared = ActiveExchangeRegistry()

    private var counts: [UUID: Int] = [:]

    /// Fenêtres à prévenir. Pas observé : un ajout ou un retrait ne doit réveiller aucune vue.
    @ObservationIgnored private var listeners: [WeakListener] = []

    private struct WeakListener {
        weak var viewModel: ChatViewModel?
    }

    /// `source` : la fenêtre qui répond. Elle n'est pas prévenue de SA réponse : son fil est déjà à jour, et le relire
    /// lui ferait perdre ce que l'historique ne garde pas (suggestions, médias en cours).
    func begin(_ conversationID: UUID?, by source: ChatViewModel? = nil) {
        guard let conversationID else { return }
        counts[conversationID, default: 0] += 1
        notifyListeners(about: conversationID, except: source)
    }

    func end(_ conversationID: UUID?, by source: ChatViewModel? = nil) {
        guard let conversationID, let count = counts[conversationID] else { return }
        counts[conversationID] = count > 1 ? count - 1 : nil
        notifyListeners(about: conversationID, except: source)
    }

    /// Inscrit une fenêtre (une seule fois) ; les fenêtres disparues sont retirées au passage.
    func addListener(_ viewModel: ChatViewModel) {
        listeners.removeAll { $0.viewModel == nil }
        guard !listeners.contains(where: { $0.viewModel === viewModel }) else { return }
        listeners.append(WeakListener(viewModel: viewModel))
    }

    private func notifyListeners(about conversationID: UUID, except source: ChatViewModel?) {
        listeners.removeAll { $0.viewModel == nil }
        for listener in listeners where listener.viewModel !== source {
            listener.viewModel?.refreshAfterExchange(in: conversationID)
        }
    }

    func isAnswering(_ conversationID: UUID?) -> Bool {
        guard let conversationID else { return false }
        return counts[conversationID] != nil
    }
}
