//
//  ChatViewModel+Progress.swift
//  Triva
//
//  Chantier 2.1 (mission D) : `ChatViewModel` raconte l'avancement d'un échange à un observateur (l'activité en
//  direct). Il n'en sait rien d'autre : pas d'ActivityKit ici, et une séance sans fenêtre (Siri, Raccourcis) n'a PAS
//  d'observateur, puisque le système affiche déjà sa propre progression.
//
//  Les événements sont rattachés à `answerID` (l'identifiant du message de réponse), seul identifiant connu à tous
//  les points d'émission, `finishAnswer` compris. Voir `SearchProgressEvent` pour le sens de chacun.
//

import Foundation

@MainActor
protocol SearchProgressObserving: AnyObject {
    func searchProgress(_ event: SearchProgressEvent, answerID: UUID)
}

/// Garde les échanges « ouverts » (démarrés, pas encore terminés) : un événement ne part que pour un échange
/// ouvert, et un échange ne se termine qu'une fois, quel que soit le chemin qui l'achève.
@MainActor
struct SearchProgressEmitter {
    weak var observer: (any SearchProgressObserving)?
    private var openAnswers: Set<UUID> = []

    mutating func emit(_ event: SearchProgressEvent, answerID: UUID) {
        switch event {
        case .started:
            openAnswers.insert(answerID)
        case .completed, .interrupted, .failed:
            guard openAnswers.remove(answerID) != nil else { return }
        case .searching, .sources, .writing:
            guard openAnswers.contains(answerID) else { return }
        }
        observer?.searchProgress(event, answerID: answerID)
    }

    /// Filet de sécurité à la fin de l'échange : si aucun chemin ne l'a terminé, il finit « interrompu ».
    mutating func closeIfOpen(answerID: UUID) {
        emit(.interrupted, answerID: answerID)
    }
}

extension ChatViewModel {
    /// L'observateur de l'avancement. `weak` : le contrôleur de l'app vit plus longtemps que n'importe quel fil.
    var progressObserver: (any SearchProgressObserving)? {
        get { progressEmitter.observer }
        set { progressEmitter.observer = newValue }
    }

    func emitProgress(_ event: SearchProgressEvent, answerID: UUID) {
        progressEmitter.emit(event, answerID: answerID)
    }

    /// Fin d'une réponse : le statut du message devient l'événement terminal.
    func emitProgress(for status: Message.Status, answerID: UUID) {
        switch status {
        case .completed: emitProgress(.completed, answerID: answerID)
        case .interrupted: emitProgress(.interrupted, answerID: answerID)
        case .failed: emitProgress(.failed, answerID: answerID)
        default: break
        }
    }
}
