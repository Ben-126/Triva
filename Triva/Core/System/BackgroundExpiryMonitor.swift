//
//  BackgroundExpiryMonitor.swift
//  Triva
//
//  Mission X1 (R2-10) : prévient quelques secondes AVANT la fin du temps d'arrière-plan accordé. Le gestionnaire
//  d'expiration d'UIKit est synchrone et le système suspend l'app dès qu'il rend la main : l'état « interrompue »
//  de l'activité en direct doit partir avant, pas dedans.
//
//  Doc Apple (`UIApplication.backgroundTimeRemaining`) : le temps restant, très grand tant que l'app est au premier
//  plan. Séparé d'UIKit (le temps restant est injecté) pour être testé sur Mac.
//

import Foundation

@MainActor
final class BackgroundExpiryMonitor {
    /// Marge avant la fin du temps accordé : assez pour envoyer une mise à jour d'activité en direct.
    static let defaultMargin: TimeInterval = 6

    private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - remainingTime: le temps d'arrière-plan restant, en secondes.
    ///   - margin: prévenir quand il reste `margin` secondes ou moins.
    ///   - pollInterval: intervalle de lecture.
    ///   - warn: appelé UNE fois, sur le main actor.
    init(
        remainingTime: @escaping @MainActor () -> TimeInterval,
        margin: TimeInterval = defaultMargin,
        pollInterval: Duration = .seconds(1),
        warn: @escaping @MainActor () -> Void
    ) {
        task = Task { [weak self] in
            while !Task.isCancelled {
                if Self.shouldWarn(remaining: remainingTime(), margin: margin) {
                    self?.task = nil
                    warn()
                    return
                }
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    /// Vrai quand il reste `margin` secondes ou moins (l'app au premier plan rend une valeur énorme : jamais vrai).
    nonisolated static func shouldWarn(remaining: TimeInterval, margin: TimeInterval) -> Bool {
        remaining <= margin
    }

    /// Arrête la surveillance (tâche terminée).
    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}
