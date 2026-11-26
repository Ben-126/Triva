//
//  ChatViewModel+Launch.swift
//  Triva
//
//  Created by ben podrojsky on 07/09/2026.
//

import Foundation

/// Lancement et arrêt d'un envoi depuis l'écran (`startSend`, suggestion, relances, Stop). Rangé à part de
/// `ChatViewModel.swift` (rangement W4-R, code déplacé à l'identique).
extension ChatViewModel {
    /// Envoi lancé par l'écran : l'échange tourne dans une `Task` gardée par le modèle, donc il survit
    /// au démontage de la vue. `Task.immediate` : `send` ajoute la question et la réponse en cours
    /// (donc `isGenerating`) AVANT son premier `await`, dans la même transaction que le brouillon vidé
    /// par l'appelant. Avec un `Task {}` ordinaire, le corps ne partait qu'au tour suivant : une image
    /// où le brouillon est vide et la génération pas encore lancée, le bouton d'envoi (verre
    /// proéminent) clignotait et SwiftUI signalait « glassEffect() tried to update multiple times per
    /// frame » à chaque envoi par toucher (mesuré : 4 sur 4 avec `Task {}`, 0 sur 4 sans).
    func startSend(query: String) {
        sendTask = Task.immediate { await self.send(query: query) }
    }

    /// Suggestion touchée : envoyée comme une nouvelle question, arrêtée par `stop()` comme un envoi tapé.
    func startSuggestion(_ suggestion: String) {
        guard !isGenerating else { return }
        sendTask = Task { await self.send(query: suggestion) }
    }

    /// Voir `retryInQuickMode(messageID:)`.
    func startRetryInQuickMode(messageID: UUID) {
        guard !isGenerating else { return }
        sendTask = Task { await self.retryInQuickMode(messageID: messageID) }
    }

    /// Voir `retryAfterOffline(quickMode:)`.
    func startRetryAfterOffline(quickMode: Bool) {
        guard !isGenerating else { return }
        sendTask = Task { await self.retryAfterOffline(quickMode: quickMode) }
    }

    /// Bouton Stop : arrête l'échange AFFICHÉ. La réponse partielle est conservée, marquée interrompue. Les réponses
    /// laissées en arrière-plan ne sont pas touchées : on ne les voit pas, c'est en revenant sur leur conversation
    /// qu'on peut les arrêter (`stopEverything()` les arrête toutes, quand plus rien ne les attend).
    func stop() {
        sendTask?.cancel()
        generationTask?.cancel()
    }

    /// Le bouton « Relancer en mode Rapide » n'a de sens que sur la DERNIÈRE
    /// réponse du fil, restée `.noReliableSources`, hors génération : une
    /// réponse plus ancienne serait écrite en FIN de conversation
    /// (`ChatHistoryStore` ajoute toujours après le dernier message), donc
    /// après des échanges qui l'ont suivie — un ordre faux à la relecture.
    func canRetryInQuickMode(_ message: Message) -> Bool {
        !isGenerating && message.status == .noReliableSources && messages.last?.id == message.id
    }

    /// Décision (c) : relance la MÊME question en mode Rapide, à la place de
    /// la réponse `.noReliableSources` (voir `canRetryInQuickMode(_:)`).
    /// Question non réécrite dans l'historique, mode mémorisé inchangé.
    /// `async` comme `send`, annulable de même (même `Task` côté vue).
    func retryInQuickMode(messageID: UUID) async {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              canRetryInQuickMode(messages[index]),
              let questionIndex = messages[..<index].lastIndex(where: { $0.role == .user }) else { return }
        await rerunAnswer(at: index, questionIndex: questionIndex, mode: .quick)
    }
}
