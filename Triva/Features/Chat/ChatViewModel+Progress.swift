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
        case .searching, .reasoning, .sources, .writing:
            guard openAnswers.contains(answerID) else { return }
        }
        observer?.searchProgress(event, answerID: answerID)
    }

    /// Filet de sécurité à la fin de l'échange : si aucun chemin ne l'a terminé, il finit « interrompu ».
    mutating func closeIfOpen(answerID: UUID) {
        emit(.interrupted, answerID: answerID)
    }
}

nonisolated extension SearchProgressEvent {
    /// Ce que dit un instantané du flux de texte de la réponse (mission I, 25/11) :
    /// - `.writing` dès qu'il y a un premier MOT de réponse (corps ou TL;DR, hors raisonnement) ;
    /// - `.reasoning` tant que le modèle n'a écrit que son raisonnement (bloc `<think>` ouvert ou refermé, sans réponse) ;
    /// - `nil` pour un instantané vide, ou qui n'est que le début d'une balise (`<thi`) : rien à annoncer encore.
    ///
    /// Seul le NOM de l'étape part : le contenu du raisonnement ne quitte jamais cette fonction.
    static func forStreamSnapshot(_ snapshot: String) -> SearchProgressEvent? {
        let trimmed = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !Self.isPartialThinkTag(trimmed) else { return nil }
        let segments = ReasoningSegmenter.segment(snapshot, isStreaming: true)
        if !segments.body.isEmpty || segments.tldr != nil { return .writing }
        return segments.hasReasoning ? .reasoning : nil
    }

    /// `<`, `<t`, `<thi`… : le début d'une balise `<think>` qui n'est pas finie d'arriver.
    private static func isPartialThinkTag(_ text: String) -> Bool {
        let tag = "<think>"
        return text.count < tag.count && tag.hasPrefix(text.lowercased())
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
