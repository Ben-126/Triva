//
//  ChatViewModel+AutoResume.swift
//  Triva
//
//  F3 (26/11) : sur iPhone et iPad, le modèle local ne peut pas tourner quand l'app est en arrière-plan (mission M) : la
//  réponse affichée est coupée, « Réponse interrompue » et « Réessayer ». Au retour au premier plan, elle REPREND TOUTE
//  SEULE, par le chemin de « Réessayer » (`startRetryInterrupted`) : même question, même bulle, début remplacé.
//
//  Garde-fous : seulement une réponse que l'ARRIÈRE-PLAN a coupée (jamais un Stop volontaire, jamais une erreur) ; une seule
//  reprise par réponse ; jamais dans une session sans fenêtre ; jamais si un accord « IA cloud » manque (rien ne part
//  tout seul vers un serveur) ; seulement si cette réponse est encore la dernière du fil affiché (une nouvelle question
//  arrivée entre-temps — widget, Siri, bouton Action — l'a déjà reléguée en arrière-plan ou effacée du fil).
//  Les réponses déjà rangées dans `backgroundExchanges` s'arrêtent avec l'app et ne reprennent pas : leur début est dans
//  l'historique, comme avant.
//

import Foundation

extension ChatViewModel {
    /// L'app passe en arrière-plan : note la réponse affichée si c'est bien l'arrière-plan qui va la couper, puis arrête
    /// tout (`stopAndWait`). Une réponse déjà annulée (Stop touché juste avant, échange encore en train de se terminer) n'est
    /// pas notée : c'est un arrêt volontaire.
    func stopBecauseAppLeftForeground(timeout: Duration) async {
        noteBackgroundInterruption()
        await stopAndWait(timeout: timeout)
    }

    private func noteBackgroundInterruption() {
        backgroundInterruptedAnswerID = nil
        guard resumesAfterBackgroundInterruption,
              isGenerating,
              sendTask?.isCancelled != true,
              generationTask?.isCancelled != true,
              let answer = messages.last,
              answer.role == .assistant,
              answer.status == .streaming else { return }
        backgroundInterruptedAnswerID = answer.id
    }

    /// L'app revient au premier plan (appelé APRÈS la fin de l'arrêt) : relance la réponse que l'arrière-plan avait coupée.
    func resumeAfterBackgroundInterruption() {
        guard let answerID = backgroundInterruptedAnswerID else { return }
        backgroundInterruptedAnswerID = nil
        guard resumesAfterBackgroundInterruption,
              !autoResumedAnswerIDs.contains(answerID),
              let answer = messages.first(where: { $0.id == answerID }),
              canRetryInterrupted(answer),
              consentRequestBeforeSending() == nil else { return }
        autoResumedAnswerIDs.insert(answerID)
        startRetryInterrupted(messageID: answerID)
    }
}
