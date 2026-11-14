//
//  ChatViewModel+Background.swift
//  Triva
//
//  Mission C5 (décision R3-2 de Ben) : la réponse continue quand on ouvre une autre conversation.
//

import Foundation

/// Une génération détachée de l'affichage : son fil (copie vivante, mise à jour par `updateMessage`),
/// sa conversation d'historique et ses tâches. Aucun delta n'est publié dans le fil affiché.
struct BackgroundExchange {
    let conversationID: UUID
    let exchangeID: UUID
    private(set) var messages: [ChatViewModel.Message]
    let sendTask: Task<Void, Never>?
    let generationTask: Task<Void, Never>?

    init(conversationID: UUID, exchangeID: UUID, messages: [ChatViewModel.Message], sendTask: Task<Void, Never>?, generationTask: Task<Void, Never>?) {
        self.conversationID = conversationID
        self.exchangeID = exchangeID
        self.messages = messages
        self.sendTask = sendTask
        self.generationTask = generationTask
    }

    mutating func update(id: UUID, _ update: (inout ChatViewModel.Message) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        update(&messages[index])
    }
}

extension ChatViewModel {
    /// Avant d'ouvrir une autre conversation : si le fil affiché génère, la génération (déjà liée à
    /// sa conversation par `Exchange.conversationID`) est mise de côté au lieu d'être annulée. Sans
    /// conversation d'historique, rien ne pourrait la recevoir : `startNewConversation()` l'annule.
    /// Fil affiché au repos : rien à faire, et SURTOUT ne pas toucher à une génération déjà en
    /// arrière-plan (A génère, on ouvre B puis C : A doit continuer, revue VE2c). Une seule génération
    /// à la fois (`runExchange`) : si le fil affiché génère, aucune autre n'est en arrière-plan.
    func moveGenerationToBackground() {
        guard isGenerating, let exchangeID = activeExchangeID, let conversationID = currentConversationID else { return }
        cancelBackgroundGeneration()
        backgroundExchange = BackgroundExchange(
            conversationID: conversationID, exchangeID: exchangeID, messages: messages,
            sendTask: sendTask, generationTask: generationTask
        )
        // Plus aucune référence côté fil : `startNewConversation()` n'annule donc pas ces tâches.
        sendTask = nil
        generationTask = nil
    }

    /// Stop, session terminée, nouvelle question ailleurs ou conversation supprimée. La réponse
    /// partielle part quand même dans l'historique (`persistAnswer`), sauf conversation disparue.
    func cancelBackgroundGeneration() {
        backgroundExchange?.sendTask?.cancel()
        backgroundExchange?.generationTask?.cancel()
        backgroundExchange = nil
    }

    /// Réouverture de la conversation dont la génération tourne encore : on reprend son fil vivant.
    /// Le fil affiché est forcément au repos (une seule génération à la fois).
    func reattachBackgroundGeneration(conversationID: UUID) -> Bool {
        guard let background = backgroundExchange, background.conversationID == conversationID else { return false }
        backgroundExchange = nil
        startNewConversation()
        displayThread(background.messages.map(Self.withoutPendingMedia), conversationID: conversationID, isGenerating: true)
        activeExchangeID = background.exchangeID
        sendTask = background.sendTask
        generationTask = background.generationTask
        return true
    }

    /// Fin d'un échange qui n'était plus affiché : sa réponse est dans l'historique.
    func backgroundExchangeDidEnd(exchangeID: UUID) {
        if backgroundExchange?.exchangeID == exchangeID { backgroundExchange = nil }
    }

    /// Les recherches de médias sont annulées au changement de fil : un spinner resterait bloqué.
    private static func withoutPendingMedia(_ message: ChatViewModel.Message) -> ChatViewModel.Message {
        var copy = message
        if case .loading = copy.images { copy.images = .idle }
        if case .loading = copy.videos { copy.videos = .idle }
        return copy
    }
}

extension ChatViewModel {
    /// Arrête toute génération (affichée ou en arrière-plan) ET attend qu'elle
    /// ait fini d'écrire, pour « Tout effacer » : une génération annulée
    /// persiste sa réponse partielle (`persistAnswer`), qui ne doit pas arriver
    /// pendant ou après l'effacement. Attente bornée (`timeout`) : une tâche
    /// qui ne réagit pas à l'annulation ne doit pas bloquer l'effacement.
    func stopAndWait(timeout: Duration = .seconds(5)) async {
        let tasks = [sendTask, generationTask, backgroundExchange?.sendTask, backgroundExchange?.generationTask]
            .compactMap { $0 }
        stop()
        guard !tasks.isEmpty else { return }
        let finished = CompletionFlag()
        let waiter = Task { @MainActor in
            for task in tasks { await task.value }
            finished.isSet = true
        }
        let deadline = ContinuousClock.now + timeout
        while !finished.isSet && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if !finished.isSet { waiter.cancel() }
    }
}

/// Drapeau partagé entre `stopAndWait` et sa tâche d'attente (main actor).
@MainActor
private final class CompletionFlag {
    var isSet = false
}
