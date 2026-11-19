//
//  LocalModelTurnQueue.swift
//  Triva
//
//  Created by ben podrojsky on 19/11/2026.
//

import Foundation
import Observation

/// Tour d'utilisation du modèle local, rendu par `LocalModelTurnQueue.acquire(for:)`.
/// `requester` : la fenêtre (session de recherche) qui le détient, pour l'affichage d'attente.
nonisolated struct LocalModelTurn: Hashable, Sendable {
    let id: UUID
    let requester: UUID
}

/// File d'attente du modèle local MLX (chantier 2.2, mission M3) : UN SEUL travail à la fois sur le
/// GPU pour toute l'app — une génération, un chargement ou un déchargement — dans l'ordre d'arrivée.
///
/// Pourquoi une file en plus du verrou interne de `mlx-swift-lm` : ce verrou sérialise déjà deux
/// générations sur un même modèle, mais personne ne le voit (la deuxième fenêtre semblait figée), et
/// il ne protège pas un CHARGEMENT : charger le modèle B pendant que A répond mettait A + B en
/// mémoire. Ici, la fenêtre qui attend le sait (`isWaitingBehindAnother`) et un chargement attend
/// la fin de la génération en cours.
///
/// Main actor : l'état est minuscule et observé par l'interface ; le travail lui-même (génération,
/// chargement) se fait ailleurs, dans l'acteur `MLXProvider`. Une attente annulée (Stop pendant
/// qu'une autre fenêtre répond) libère sa place sans bloquer la suivante.
@MainActor
@Observable
final class LocalModelTurnQueue {
    private struct Waiter {
        let turn: LocalModelTurn
        let continuation: CheckedContinuation<Void, any Error>
    }

    /// Tour en cours, `nil` si le modèle est libre.
    private(set) var holder: LocalModelTurn?
    /// Fenêtres en attente, dans l'ordre (observé : c'est ce qui fait apparaître la ligne d'attente).
    private(set) var waitingRequesters: [UUID] = []
    @ObservationIgnored private var waiters: [Waiter] = []

    /// Attend son tour, dans l'ordre d'arrivée. Lève `CancellationError` si la tâche est annulée
    /// avant d'avoir obtenu le tour (sa place est alors rendue). À libérer par `release(_:)` sur
    /// TOUS les chemins de sortie ; `release` est idempotent.
    func acquire(for requester: UUID) async throws -> LocalModelTurn {
        try Task.checkCancellation()
        let turn = LocalModelTurn(id: UUID(), requester: requester)
        if holder == nil, waiters.isEmpty {
            holder = turn
            return turn
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Synchrone sur le main actor, sans suspension depuis `checkCancellation()` : le
                // gestionnaire d'annulation (qui repasse par le main actor) s'exécute forcément APRÈS
                // cet enregistrement, et retrouve donc toujours l'attente à retirer.
                waiters.append(Waiter(turn: turn, continuation: continuation))
                waitingRequesters.append(requester)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiting(turn) }
        }
        // Tour obtenu, mais la tâche a pu être annulée entre l'attribution et la reprise : on rend
        // le tour aussitôt plutôt que de lancer un travail que personne n'attend.
        if Task.isCancelled {
            release(turn)
            throw CancellationError()
        }
        return turn
    }

    /// Rend le tour et le passe au premier en attente. Sans effet pour un tour qui n'est pas (ou plus)
    /// le tour en cours : un double appel ne peut jamais libérer le tour de quelqu'un d'autre.
    func release(_ turn: LocalModelTurn) {
        guard holder == turn else { return }
        holder = nil
        guard !waiters.isEmpty else { return }
        let next = waiters.removeFirst()
        waitingRequesters.removeFirst()
        holder = next.turn
        next.continuation.resume()
    }

    /// `requester` attend-il pendant que le modèle sert QUELQU'UN D'AUTRE ? Faux quand c'est son
    /// propre travail précédent qui occupe le modèle (suggestions de la réponse d'avant) : le
    /// message « une autre fenêtre… » serait faux.
    func isWaitingBehindAnother(_ requester: UUID) -> Bool {
        guard waitingRequesters.contains(requester), let holder else { return false }
        return holder.requester != requester
    }

    private func cancelWaiting(_ turn: LocalModelTurn) {
        guard let index = waiters.firstIndex(where: { $0.turn == turn }) else { return }
        let waiter = waiters.remove(at: index)
        waitingRequesters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
